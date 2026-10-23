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
        // open -n Rasklad.app --args --caret-dump 5 out.txt — через 5 с записать элемент под курсором с предками и выйти
        if let i = args.firstIndex(of: "--caret-dump"), i + 2 < args.count, let delay = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = inputAnchor() // Chrome/Electron: включить дерево Accessibility, строится не сразу
                if let pid = inputApp()?.processIdentifier { // только для отладки: Chrome сразу строит дерево для страниц
                    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    var lines = caretAncestry().map { "\($0.role) \($0.subrole) \($0.classes.joined(separator: " "))" }
                    if let f = inputField() {
                        var role: CFTypeRef?
                        AXUIElementCopyAttributeValue(f, kAXRoleAttribute as CFString, &role)
                        lines += ["поле: \(role as? String ?? "?"), блок кода: \(caretInCode(caretAncestry()) ? "да" : "нет")"]
                    } else { lines.append("нет фокуса, AX=\(AXIsProcessTrusted())") }
                    try? ((frontAppID() ?? "?") + "\n" + lines.joined(separator: "\n") + "\n").write(toFile: args[i + 2], atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
            return
        }
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
            // слово, иначе сразу после пробела — предыдущее, иначе — выделенное.
            // С ⇧ — определение выделенного слова из словарей macOS.
            t.onRightOption = { [weak self, weak t] kind in
                if kind == .shifted { self?.defineSelection(); return }
                guard let t, !t.undoLastFix(), !t.convertCurrentWord(), !t.convertLastWord() else { return }
                self?.convertSelection()
            }
            // Подсказка у слова: после retype поле ещё не обновилось — даём ему мгновение.
            t.onFix = { [weak self] typed, fixed in
                guard let self else { return }
                self.hintSoon("\(typed) → \(fixed)", hideAfter: 2)
            }
            t.onUndo = { [weak self] typed, remembered in
                self?.hintSoon(remembered ? "↩ \(typed)   " + tr("больше не меняю — в исключениях", "won’t change it again — added to exceptions")
                                          : "↩ \(typed)   " + tr("отмените ещё раз — перестану менять это слово",
                                                                "undo once more to stop changing this word"),
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
        let dmg = path.hasPrefix("/Volumes/")
        a.messageText = tr("Переместите Rasklad в «Программы»", "Move Rasklad to Applications")
        a.informativeText = tr("Rasklad запущен \(dmg ? "прямо из образа диска" : "не из папки «Программы»"). "
            + "Отсюда не будет работать запуск при входе. Перетащите Rasklad.app в «Программы» и запустите оттуда.",
            "Rasklad is running \(dmg ? "from the disk image" : "outside the Applications folder"). "
            + "Open at Login won’t work from here. Drag Rasklad.app to Applications and open it from there.")
        a.addButton(withTitle: tr("Открыть «Программы» и выйти", "Open Applications and Quit"))
        a.addButton(withTitle: tr("Продолжить без автозапуска", "Continue Without Open at Login"))
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
        appItem.title = tr("Не править в «\(name)»", "Don’t fix in “\(name)”")
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
        a.messageText = tr("Забыть выученное слово", "Forget a Learned Word")
        a.informativeText = tr("Слово, которое добавили через «Запомнить правописание». Слова из словарей это не затронет.",
                               "A word added with “Learn Spelling”. Dictionary words are not affected.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = tr("например, paly", "for example, paly")
        a.accessoryView = field
        a.addButton(withTitle: tr("Забыть", "Forget"))
        a.addButton(withTitle: tr("Отмена", "Cancel"))
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = NSAlert()
        switch forgetLearnedWord(word) {
        case .forgotten:
            done.messageText = tr("«\(word)» забыто", "“\(word)” forgotten")
            done.informativeText = tr("Проверка орфографии снова считает его ошибкой и сможет исправить.",
                                      "Spell checking treats it as a mistake again and can correct it.")
        case .notLearned:
            done.messageText = tr("«\(word)» не было выучено", "“\(word)” wasn’t learned")
            done.informativeText = tr("Это слово из словаря или его нет в выученных — ничего не меняю.",
                                      "It’s a dictionary word or not among learned words — nothing changed.")
        case .empty: return
        case .failed:
            done.messageText = tr("Не получилось забыть «\(word)»", "Couldn’t forget “\(word)”")
            done.informativeText = tr("Служба проверки орфографии не приняла изменение.",
                                      "The spell checking service didn’t accept the change.")
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

        header(tr("Правка", "Fixing"))
        item(tr("Автопереключение раскладки", "Auto-switch Layout"), #selector(toggleAuto(_:)), on: settings.autoSwitch)
        item(tr("Исправлять опечатки", "Fix Typos"), #selector(toggleTypos(_:)), on: settings.typos)
        item(tr("Не править код (``` и редакторы кода)", "Don’t Fix Code (``` and code editors)"), #selector(toggleCode(_:)), on: settings.protectCode)
        add(appItem)

        header(tr("Клавиши", "Keys"))
        for k in CorrectionKey.allCases {
            let i = keyMenu.addItem(withTitle: k.title + (k == .rightOption ? tr(" (по умолчанию)", " (default)") : ""),
                                    action: #selector(pickKey(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = k.rawValue
        }
        m.addItem(withTitle: tr("Клавиша исправления", "Correction Key"), action: nil, keyEquivalent: "").submenu = keyMenu
        add(fnItem)

        header(tr("Слова", "Words"))
        item(tr("Исключения слов…", "Word Exceptions…"), #selector(openWords))
        item(tr("Забыть выученное слово…", "Forget Learned Word…"), #selector(forgetWord))

        // справка о клавише исправления — неактивные строки
        m.addItem(.separator())
        convertItem.isEnabled = false
        defineItem.isEnabled = false
        m.addItem(convertItem)
        m.addItem(defineItem)
        m.addItem(.separator())
        add(loginItem)
        item(tr("Настройка…", "Setup…"), #selector(showOnboarding), key: ",")
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        m.addItem(withTitle: "Rasklad \(v)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: tr("Выход", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        convertItem.title = "\(key) — " + tr("отмена замены, конвертация слова или выделенного",
                                             "undo a fix, convert the word or selection")
        defineItem.title = "⇧ + \(k.short) — " + tr("определение выделенного слова", "define the selected word")
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
            ? tr("Fn/🌐 — смена раскладки (в Настройках: 🌐 → «Действие не требуется»)",
                 "Fn/🌐 — switch layout (in System Settings: 🌐 → “Do Nothing”)")
            : tr("Fn/🌐 — мгновенная смена раскладки", "Fn/🌐 — instant layout switch")
    }

    func refreshPerms() {
        updateFnItem()
        // tapCreate удаётся и без права, но события не приходят — ориентируемся на preflight.
        let listen = CGPreflightListenEventAccess()
        if listen, let t = keyTap, !t.running, t.start() { dlog("перехват запущен") }
        let ax = AXIsProcessTrusted(), tap = listen && (keyTap?.running ?? false)
        let missing = [ax ? nil : tr("Универсальный доступ", "Accessibility"), tap ? nil : tr("Мониторинг ввода", "Input Monitoring")].compactMap { $0 }
        permsItem.title = missing.isEmpty ? tr("Права: всё есть", "Permissions: all set") : tr("Нет прав: ", "Missing permissions: ") + missing.joined(separator: ", ")
        permsItem.isHidden = missing.isEmpty
        status.button?.title = missing.isEmpty ? "Аа" : "Аа⚠︎"
    }

    let loginItem = NSMenuItem(title: tr("Запускать при входе", "Open at Login"), action: #selector(toggleLogin), keyEquivalent: "")

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
        loginItem.title = st == .requiresApproval ? tr("Запускать при входе (разрешите в Настройках)", "Open at Login (allow in System Settings)")
            : tr("Запускать при входе", "Open at Login")
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
            if axReplaceSelection(el, with: out) {
                selectLayout(src)
                dlog("конвертация: заменено напрямую в \(frontAppID() ?? "?")")
                return
            }
        }
        guard selectionMayExist(el) else { dlog("конвертация: ничего не выделено в \(frontAppID() ?? "?")"); return }
        copySelection { [self] text, pb, saved in
            dlog("конвертация: через буфер обмена в \(frontAppID() ?? "?")")
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
        shouldCopySelection(axSelected: axSelectedText(el), codeApp: isCodeApp(frontAppID() ?? ""))
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
        hint.show(def ?? tr("«\(word)» нет в словарях macOS.", "“\(word)” isn’t in the macOS dictionaries."), at: anchor, width: 420, maxHeight: 320, hideAfter: nil, fontSize: 12)
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
            let anchor = inputAnchor()
            dlog("подсказка: \(anchor.kind) в \(frontAppID() ?? "?")")
            hint.show(text, at: anchor.rect, width: 360, maxHeight: 60, hideAfter: hideAfter)
        }
    }

    /// ⌘C с ожиданием буфера; `done` — выделенный текст, буфер и его прежнее содержимое.
    func copySelection(_ done: @escaping (String, NSPasteboard, [[NSPasteboard.PasteboardType: Data]]) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        waitForChange(pb, since: before, tries: 30) { copied in   // до 0,6 с: медленные приложения копируют не сразу
            guard copied, let text = pb.string(forType: .string), !text.isEmpty else {
                dlog("выделенное: ⌘C ничего не скопировал в \(frontAppID() ?? "?")")
                return
            }
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
