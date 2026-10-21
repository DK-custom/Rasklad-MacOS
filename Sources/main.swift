import AppKit
import Carbon
import ServiceManagement

final class App: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var keyTap: KeyTap?
    let settings = Settings()
    let appItem = NSMenuItem(title: "", action: #selector(toggleApp(_:)), keyEquivalent: "")
    var frontApp: NSRunningApplication? // последнее активное приложение, кроме нас

    func applicationDidFinishLaunching(_ n: Notification) {
        // ./Rasklad --onboarding-snapshot out.png [--fresh] — снимок окна настройки и выход
        let args = CommandLine.arguments
        // ./Rasklad --define-snapshot слово out.png [--dark|--light] — снимок словарной подсказки и выход
        if let i = args.firstIndex(of: "--define-snapshot"), i + 2 < args.count {
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            hint.onPageShown = { w in
              // прозрачная страница снимается на белом — подставляем фон панели
              let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
              let js = "document.documentElement.style.setProperty('background','\(dark ? "#2b2b2d" : "#f2f2f4")','important')"
              w.evaluateJavaScript(js) { _, _ in
                w.takeSnapshot(with: nil) { img, _ in
                    if let t = img?.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                        try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
                    }
                    exit(0)
                }
              }
            }
            showDefinition(args[i + 1], at: CGRect(x: 200, y: 600, width: 60, height: 18))
            return
        }
        if let i = args.firstIndex(of: "--onboarding-snapshot"), i + 1 < args.count {
            let ob = Onboarding(settings: settings)
            if args.contains("--fresh") { ob.probe = { .init(ax: false, listen: false, fnOn: false, fnSystemOff: false, capsOff: false) } }
            if args.contains("--half") { ob.probe = { .init(ax: true, listen: false, fnOn: false, fnSystemOff: false, capsOff: false) } }
            if args.contains("--ready") { ob.probe = { .init(ax: true, listen: true, fnOn: true, fnSystemOff: false, capsOff: true) } }
            ob.snapshot(to: args[i + 1], dark: args.contains("--dark"))
            exit(0)
        }

        let properPath = isProperInstallPath(Bundle.main.bundlePath, home: NSHomeDirectory())
        if !properPath, !args.contains("--menu-dump") { warnNotInstalled() }
        ITDictionary.updateIfNeeded()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Аа"
        status.menu = buildMenu()

        if let l = Layouts() {
            let t = KeyTap(layouts: l, settings: settings)
            // Клавиша исправления (по умолчанию правый ⌥): отменить автозамену, иначе перенабрать текущее
            // слово, иначе — выделенное. С ⇧ — определение выделенного слова из словарей macOS.
            t.onRightOption = { [weak self, weak t] kind in
                if kind == .shifted { self?.defineSelection(); return }
                guard let t, !t.undoLastFix(), !t.convertCurrentWord() else { return }
                self?.convertSelection()
            }
            // Подсказка у слова: после retype поле ещё не обновилось — даём ему мгновение.
            t.onFix = { [weak self] typed, fixed in
                guard let self else { return }
                self.hintSoon("\(typed) → \(fixed)   \(self.settings.correctionKey.short) — отменить", hideAfter: 2)
            }
            t.onUndo = { [weak self] typed, remembered in
                self?.hintSoon(remembered ? "↩ \(typed)   больше не меняю — в исключениях"
                                          : "↩ \(typed)   отмените ещё раз — перестану менять это слово",
                               hideAfter: remembered ? 1.5 : 2.5)
            }
            t.onActivity = { [weak self] click in
                guard let h = self?.hint, h.sticky, !(click && h.contains(NSEvent.mouseLocation)) else { return }
                h.hide()
            }
            // Fn/🌐: мгновенная смена RU↔EN без системного окна и задержки.
            // Пока у 🌐 есть системное действие (смена источника, эмодзи, диктовка), молчим: иначе сработают оба.
            // Переключаем в момент нажатия Fn; если это было сочетание (Fn+стрелка) — возвращаем прежнюю.
            var fnBefore: Lang?
            t.onFn = { [weak self, weak t] in
                guard let self, let l = t?.layouts, self.settings.fnSwitch, systemFnUsage() == 0 else { return }
                fnBefore = l.current()
                self.switchLayoutNatively(to: fnBefore?.other ?? .en, l)
            }
            t.onFnCancel = { [weak self, weak t] in
                guard let l = t?.layouts, let back = fnBefore else { return }
                fnBefore = nil
                self?.switchLayoutNatively(to: back, l)
                dlog("Fn: сочетание — раскладка возвращается \(back)")
            }
            keyTap = t
            watchApps()
            // раскладки добавили или убрали в Настройках — перечитать, без перезапуска
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                object: nil, queue: .main) { [weak t] _ in
                if let fresh = Layouts() { t?.layouts = fresh; dlog("раскладки перечитаны") }
                else { dlog("раскладки RU/EN не найдены") }
            }
        } else { dlog("не найдены раскладки RU/EN") }
        dlog("старт: AX=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) ввод в \(frontAppID() ?? "?") (NSWorkspace: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")

        // Права выдаются в Настройках, пока приложение работает: подхватываем без перезапуска.
        // Автозагрузка: включаем при первом запуске, дальше — как выбрал пользователь в меню.
        if properPath, !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            setLogin(true)
        }
        updateLoginItem()

        // ./Rasklad --menu-dump — структура меню текстом (проверка без экрана) и выход
        if args.contains("--menu-dump") {
            applyKey(settings.correctionKey)
            refreshPerms()
            func dump(_ m: NSMenu, _ pad: String) {
                for i in m.items where !i.isHidden {
                    let mark = i.state == .on ? "✓ " : "  "
                    print(pad + (i.isSeparatorItem ? "———" : mark + i.title + (i.isEnabled || i.submenu != nil ? "" : "  [неактивно]")
                                 + (i.keyEquivalent.isEmpty ? "" : "  ⌘" + i.keyEquivalent.uppercased())))
                    if let sub = i.submenu { dump(sub, pad + "      ") }
                }
            }
            if let m = status.menu { dump(m, "") }
            exit(0)
        }

        // Права запрашивает окно настройки — по одному, а не два системных диалога разом.
        onboarding.onDone = { UserDefaults.standard.set(true, forKey: "onboarded") }
        onboarding.onKeyChange = { [weak self] k in self?.applyKey(k) }
        applyKey(settings.correctionKey)
        if !UserDefaults.standard.bool(forKey: "onboarded") || !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            onboarding.show()
        }

        refreshPerms()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPerms() }
    }

    /// Запуск из образа диска, «Загрузок» или перемещённой системой копии: автозагрузка запомнила бы
    /// временный путь. Предлагаем перенести в «Программы»; продолжить можно, но без автозагрузки.
    func warnNotInstalled() {
        let path = Bundle.main.bundlePath
        dlog("запуск не из «Программ»: \(path)")
        let a = NSAlert()
        a.messageText = "Переместите Rasklad в «Программы»"
        a.informativeText = "Rasklad запущен \(path.hasPrefix("/Volumes/") ? "прямо из образа диска" : "не из папки «Программы»"). "
            + "Отсюда не будет работать запуск при входе. Перетащите Rasklad.app в «Программы» и запустите оттуда."
        a.addButton(withTitle: "Открыть «Программы» и выйти")
        a.addButton(withTitle: "Продолжить без автозапуска")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            NSApp.terminate(nil)
        }
    }

    /// Раскладка по приложениям: запоминаем при смене раскладки, восстанавливаем при активации.
    func watchApps() {
        frontApp = inputApp().flatMap { secureAppIDs.contains($0.bundleIdentifier ?? "") ? nil : $0 }
        updateAppItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !secureAppIDs.contains(id) else { return } // экран блокировки и окна паролей — не «приложения» для меню
            self.frontApp = app
            self.updateAppItem()
            if let l = self.keyTap?.layouts, let lang = self.settings.appLayouts[id].flatMap(Lang.init), lang != l.current() {
                dlog("раскладка приложения \(id): \(lang)")
                selectLayout(l.source(lang))
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
            guard let self, let id = self.frontApp?.bundleIdentifier, let cur = self.keyTap?.layouts.current() else { return }
            self.settings.appLayouts[id] = cur.rawValue
        }
    }

    func updateAppItem() {
        let name = frontApp?.localizedName ?? "?"
        appItem.title = "Не править в «\(name)»"
        appItem.state = settings.isExcluded(frontApp?.bundleIdentifier ?? "") ? .on : .off
        appItem.isHidden = frontApp?.bundleIdentifier == nil
    }

    @objc func toggleApp(_ item: NSMenuItem) {
        guard let id = frontApp?.bundleIdentifier else { return }
        settings.setExcluded(id, !settings.isExcluded(id)) // IDE и терминалы выключены по умолчанию — можно включить
        updateAppItem()
    }

    /// Убрать слово, случайно добавленное через «Запомнить правописание». macOS не показывает список
    /// выученных слов, поэтому слово вводят; словарные слова не трогаем.
    @objc func forgetWord() {
        let a = NSAlert()
        a.messageText = "Забыть выученное слово"
        a.informativeText = "Слово, которое добавили через «Запомнить правописание». Слова из словарей это не затронет."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "например, paly"
        a.accessoryView = field
        a.addButton(withTitle: "Забыть")
        a.addButton(withTitle: "Отмена")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = NSAlert()
        switch forgetLearnedWord(word) {
        case .forgotten:
            done.messageText = "«\(word)» забыто"
            done.informativeText = "Проверка орфографии снова считает его ошибкой и сможет исправить."
        case .notLearned:
            done.messageText = "«\(word)» не было выучено"
            done.informativeText = "Это слово из словаря или его нет в выученных — ничего не меняю."
        case .empty: return
        case .failed:
            done.messageText = "Не получилось забыть «\(word)»"
            done.informativeText = "Служба проверки орфографии не приняла изменение."
        }
        done.runModal()
    }

    @objc func openWords() {
        settings.ensureWordsFile()
        NSWorkspace.shared.open(settings.wordsURL)
    }

    let permsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    lazy var onboarding = Onboarding(settings: settings)
    let keyMenu = NSMenu()
    let convertItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let defineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Меню по разделам: правка, клавиши, слова; справка о клавише исправления; внизу — служебное.
    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func header(_ title: String) {
            if #available(macOS 14, *) { m.addItem(.sectionHeader(title: title)) }
            else { m.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false }
        }
        @discardableResult
        func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            return i
        }
        func add(_ i: NSMenuItem) { i.target = self; m.addItem(i) }

        permsItem.action = #selector(showOnboarding)
        add(permsItem)

        header("Правка")
        item("Автопереключение раскладки", #selector(toggleAuto(_:)), on: settings.autoSwitch)
        item("Исправлять опечатки", #selector(toggleTypos(_:)), on: settings.typos)
        item("Не править код (``` и редакторы кода)", #selector(toggleCode(_:)), on: settings.protectCode)
        add(appItem)

        header("Клавиши")
        for k in CorrectionKey.allCases {
            let i = keyMenu.addItem(withTitle: k.title + (k == .rightOption ? " (по умолчанию)" : ""),
                                    action: #selector(pickKey(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = k.rawValue
        }
        m.addItem(withTitle: "Клавиша исправления", action: nil, keyEquivalent: "").submenu = keyMenu
        add(fnItem)

        header("Слова")
        item("Исключения слов…", #selector(openWords))
        item("Забыть выученное слово…", #selector(forgetWord))

        // справка о клавише исправления — неактивные строки
        m.addItem(.separator())
        convertItem.isEnabled = false
        defineItem.isEnabled = false
        m.addItem(convertItem)
        m.addItem(defineItem)
        m.addItem(.separator())
        add(loginItem)
        item("Настройка…", #selector(showOnboarding), key: ",")
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        m.addItem(withTitle: "Rasklad \(v)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    @objc func pickKey(_ item: NSMenuItem) {
        guard let k = (item.representedObject as? String).flatMap(CorrectionKey.init) else { return }
        settings.correctionKey = k
        applyKey(k)
        onboarding.refresh()
    }

    /// Выбранная клавиша исправления — в перехват, меню и подсказки.
    func applyKey(_ k: CorrectionKey) {
        keyTap?.correctionKey = k
        let key = k.short.prefix(1).uppercased() + k.short.dropFirst()
        convertItem.title = "\(key) — отмена замены, конвертация слова или выделенного"
        defineItem.title = "⇧ + \(k.short) — определение выделенного слова"
        keyMenu.items.forEach { $0.state = ($0.representedObject as? String) == k.rawValue ? .on : .off }
    }

    @objc func showOnboarding() { onboarding.show() }

    let fnItem = NSMenuItem(title: "", action: #selector(toggleFn), keyEquivalent: "")

    @objc func toggleFn() {
        settings.fnSwitch.toggle()
        updateFnItem()
    }

    func updateFnItem() {
        fnItem.state = settings.fnSwitch ? .on : .off
        fnItem.title = settings.fnSwitch && systemFnUsage() != 0
            ? "Fn/🌐 — смена раскладки (в Настройках: 🌐 → «Ничего не делать»)"
            : "Fn/🌐 — мгновенная смена раскладки"
    }

    func refreshPerms() {
        updateFnItem()
        // tapCreate удаётся и без права, но события не приходят — ориентируемся на preflight.
        let listen = CGPreflightListenEventAccess()
        if listen, let t = keyTap, !t.running, t.start() { dlog("перехват запущен") }
        let ax = AXIsProcessTrusted(), tap = listen && (keyTap?.running ?? false)
        let missing = [ax ? nil : "Универсальный доступ", tap ? nil : "Мониторинг ввода"].compactMap { $0 }
        permsItem.title = missing.isEmpty ? "Права: всё есть" : "Нет прав: " + missing.joined(separator: ", ")
        permsItem.isHidden = missing.isEmpty
        status.button?.title = missing.isEmpty ? "Аа" : "Аа⚠︎"
    }

    let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { dlog("автозагрузка: \(error.localizedDescription)") }
        dlog("автозагрузка: статус \(SMAppService.mainApp.status.rawValue)")
    }

    @objc func toggleLogin() {
        setLogin(SMAppService.mainApp.status != .enabled)
        updateLoginItem()
    }

    func updateLoginItem() {
        let st = SMAppService.mainApp.status
        loginItem.state = st == .enabled ? .on : .off
        loginItem.title = st == .requiresApproval ? "Запускать при входе (разрешите в Настройках)" : "Запускать при входе"
    }

    @objc func toggleCode(_ item: NSMenuItem) {
        settings.protectCode.toggle()
        item.state = settings.protectCode ? .on : .off
    }

    @objc func toggleTypos(_ item: NSMenuItem) {
        settings.typos.toggle()
        item.state = settings.typos ? .on : .off
    }

    @objc func toggleAuto(_ item: NSMenuItem) {
        settings.autoSwitch.toggle()
        item.state = settings.autoSwitch ? .on : .off
    }

    /// Конвертация выделенного. Сначала через Accessibility: что выделено и можно ли заменить напрямую —
    /// тогда буфер обмена не нужен. Иначе ⌘C → конвертация → ⌘V с возвратом буфера.
    @objc func convertSelection() {
        guard let layouts = keyTap?.layouts ?? Layouts() else { dlog("нужны раскладки RU и EN"); return }
        func converted(_ text: String) -> (String, TISInputSource) {
            let dir = detectDirection(text)
            return (convert(text, dir == .enToRu ? layouts.enToRu : layouts.ruToEn), dir == .enToRu ? layouts.ru : layouts.en)
        }
        let el = axFocusedElement()
        if let sel = axSelectedText(el), !sel.isEmpty {
            let (out, src) = converted(sel)
            if axReplaceSelection(el, with: out) { selectLayout(src); return }
        }
        guard selectionMayExist(el) else { return }
        copySelection { [self] text, pb, saved in
            let (out, src) = converted(text)
            pb.clearContents()
            pb.setString(out, forType: .string)
            let ours = pb.changeCount
            postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            selectLayout(src)
            // вставка в медленных приложениях занимает время; если пользователь сам что-то скопировал — не трогаем
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if shouldRestoreClipboard(current: pb.changeCount, ours: ours) { self.restore(pb, saved) }
            }
        }
    }

    @objc func defineSelection() {
        let el = axFocusedElement()
        if let sel = axSelectedText(el), !sel.isEmpty {
            showDefinition(sel.trimmingCharacters(in: .whitespacesAndNewlines), at: caretRect())
            return
        }
        guard selectionMayExist(el) else { return }
        copySelection { [self] text, pb, saved in
            restore(pb, saved) // текст уже прочитан — буфер возвращаем сразу
            showDefinition(text.trimmingCharacters(in: .whitespacesAndNewlines), at: caretRect())
        }
    }

    /// Нажимать ли ⌘C: если поле говорит «ничего не выделено» — нет. В IDE и терминалах ⌘C без выделения
    /// копирует всю строку, поэтому там — только когда поле подтвердило выделение.
    func selectionMayExist(_ el: AXUIElement?) -> Bool {
        if let sel = axSelectedText(el) { return !sel.isEmpty }
        return !isCodeApp(frontAppID() ?? "")
    }

    let hint = Hint()

    /// Статья в стиле системной всплывашки «Найти»; если частный API словарей недоступен — плоский текст.
    func showDefinition(_ word: String, at anchor: CGRect?) {
        if let e = SystemDictionary.entries(word),
           let page = panelPage(e.html, word: word, source: e.dictionary, fontPx: 12) {
            hint.showPage(page, at: anchor, width: 420, maxHeight: 360)
            return
        }
        let def = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: (word as NSString).length))?
            .takeRetainedValue() as String?
        hint.show(def ?? "«\(word)» нет в словарях macOS.", at: anchor, width: 420, maxHeight: 320, hideAfter: nil, fontSize: 12)
    }

    /// Смена раскладки так, как её делает сама macOS: системным сочетанием «Выбрать предыдущий источник
    /// ввода» (⌃Пробел). При переключении через TISSelectInputSource из фоновой программы синий индикатор
    /// «РУ/A» у поля ввода показывает прежнюю раскладку. Сочетание выключено или не сработало за 0,25 с —
    /// переключаем напрямую.
    func switchLayoutNatively(to target: Lang, _ l: Layouts) {
        let caps = capsLock()
        guard let hk = previousSourceHotkey() else {
            selectLayout(l.source(target))
            dlog("Fn: → \(target) напрямую (сочетание «предыдущий источник ввода» выключено)")
            return
        }
        postKey(CGKeyCode(hk.code), flags: CGEventFlags(rawValue: hk.flags))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let native = l.current() == target
            if !native { selectLayout(l.source(target)) }
            if caps, !capsLock() { setCapsLock(true) }
            dlog("Fn: → \(target) \(native ? "сочетанием macOS" : "напрямую (сочетание не сработало)"), стало \(l.current().map { "\($0)" } ?? "?") в \(frontAppID() ?? "?")")
        }
    }

    func hintSoon(_ text: String, hideAfter: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            let caret = caretRect()
            dlog("подсказка: \(caret == nil ? "у мыши" : "у курсора") в \(frontAppID() ?? "?")")
            hint.show(text, at: caret, width: 360, maxHeight: 60, hideAfter: hideAfter)
        }
    }

    /// ⌘C с ожиданием буфера; `done` — выделенный текст, буфер и его прежнее содержимое.
    func copySelection(_ done: @escaping (String, NSPasteboard, [[NSPasteboard.PasteboardType: Data]]) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        waitForChange(pb, since: before, tries: 15) { copied in
            guard copied, let text = pb.string(forType: .string), !text.isEmpty else { return } // ничего не выделено
            done(text, pb, saved)
        }
    }

    func waitForChange(_ pb: NSPasteboard, since: Int, tries: Int, _ done: @escaping (Bool) -> Void) {
        if pb.changeCount != since { return done(true) }
        if tries == 0 { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.waitForChange(pb, since: since, tries: tries - 1, done)
        }
    }

    func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        pb.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            dict.forEach { item.setData($1, forType: $0) }
            return item
        })
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
