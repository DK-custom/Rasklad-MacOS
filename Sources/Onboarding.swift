import AppKit

/// Окно первого запуска: права по очереди с живыми галочками, быстрая смена языка по Fn/🌐
/// вместо штатной, Caps Lock и выбор клавиши исправления.
/// Выдать права и поменять системные настройки за пользователя macOS не даёт (запись в настройки
/// подхватывается ненадёжно) — окно открывает нужный раздел Настроек и само видит результат.
final class Onboarding: NSObject {
    struct Status {
        var ax, listen, fnOn, fnSystemOff: Bool, capsOff: Bool
        var itInstalled = false, itActive = false
    }
    lazy var probe: () -> Status = { [settings] in
        Status(ax: AXIsProcessTrusted(), listen: CGPreflightListenEventAccess(),
               fnOn: settings.fnSwitch, fnSystemOff: systemFnUsage() == 0, capsOff: systemCapsSwitch() == false,
               itInstalled: ITDictionary.installed, itActive: ITDictionary.active)
    }
    var onDone: () -> Void = {}
    var onKeyChange: (CorrectionKey) -> Void = { _ in }

    let window: NSWindow
    private let settings: Settings
    private var rows: [Row] = []
    private let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyMark = NSTextField(labelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let doneButton = NSButton(title: tr("Готово", "Done"), target: nil, action: nil)
    private var timer: Timer?

    private final class Row {
        let mark = NSTextField(labelWithString: "")
        let control: NSControl
        let view: NSStackView
        let key: String // флаг «системный запрос уже показан»: дальше кнопка открывает Настройки

        init(_ title: String, _ note: String, key: String = "", control: NSControl, mark preset: NSTextField? = nil) {
            self.key = key
            self.control = control
            let m = preset ?? mark
            m.font = .systemFont(ofSize: 20, weight: .semibold)
            m.alignment = .center
            m.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            let n = NSTextField(wrappingLabelWithString: note)
            n.font = .systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            n.preferredMaxLayoutWidth = 290
            let text = NSStackView(views: [t, n])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: 290).isActive = true // колонки одной ширины — кнопки в ряд
            control.widthAnchor.constraint(equalToConstant: 150).isActive = true
            view = NSStackView(views: [m, text, control])
            view.alignment = .centerY
            view.spacing = 10
        }
    }

    private func button(_ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    init(settings: Settings) {
        self.settings = settings
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = tr("Rasklad — настройка", "Rasklad Setup")
        window.isReleasedWhenClosed = false
        window.level = .floating // остаётся видимым рядом с окном Настроек

        CorrectionKey.allCases.forEach { keyPopup.addItem(withTitle: $0.short.prefix(1).uppercased() + $0.short.dropFirst()) }
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)

        rows = [
            Row(tr("Универсальный доступ", "Accessibility"),
                tr("Чтобы перенабирать слова и конвертировать выделенный текст.",
                   "To retype words and convert selected text."),
                key: "askedAX", control: button(#selector(stepAX))),
            Row(tr("Мониторинг ввода", "Input Monitoring"),
                tr("Чтобы видеть набираемые слова. Слова никуда не отправляются и не сохраняются.",
                   "To see the words you type. Nothing is sent anywhere or stored."),
                key: "askedListen", control: button(#selector(stepListen))),
            Row(tr("Быстрая смена языка по Fn/🌐", "Instant layout switch with Fn/🌐"),
                tr("Вместо штатной, без задержки macOS. Штатное действие нужно отключить: "
                   + "Клавиатура → «Нажатие клавиши 🌐» → «Действие не требуется».",
                   "Replaces the built-in switch without the macOS delay. Turn the built-in action off: "
                   + "Keyboard → “Press 🌐 key to” → “Do Nothing”."), control: button(#selector(stepFn))),
            Row(tr("Caps Lock без смены языка", "Caps Lock without switching"),
                tr("Штатная смена по Caps Lock тормозит так же. Клавиатура → Источники ввода → «Изменить…» → "
                   + "снять «Использовать клавишу Caps Lock для переключения…».",
                   "The built-in Caps Lock switch has the same delay. Keyboard → Input Sources → “Edit…” → "
                   + "uncheck “Use the Caps Lock key to switch to and from…”."), control: button(#selector(openKeyboard))),
            Row(tr("Словарь IT-термины (необязательно)", "IT Terms dictionary (optional)"),
                tr("≈15 тыс. английских терминов и сокращений (FOLDOC) и русские IT-термины для определения слов. "
                   + "Затем «Словарь» → Настройки: включить и поставить под Толковым.",
                   "≈15,000 English computing terms and abbreviations (FOLDOC) plus Russian IT terms for definitions. "
                   + "Then Dictionary → Settings: turn it on and drag it where you want it."),
                control: button(#selector(stepIT))),
            Row(tr("Клавиша исправления", "Correction key"),
                tr("По умолчанию правый ⌥. Отмена замены, перенабор слова или выделенного; с ⇧ — определение.",
                   "Right ⌥ by default. Undoes a fix, retypes the word or selection; with ⇧ shows a definition."),
                control: keyPopup, mark: keyMark),
        ]
        let intro = NSTextField(wrappingLabelWithString: tr(
            "Rasklad нужны два разрешения macOS. Выдать их может только пользователь — нажмите кнопку, "
            + "включите Rasklad в открывшемся разделе Настроек, галочка здесь появится сама. Остальное — по желанию.",
            "Rasklad needs two macOS permissions that only you can grant: click the button, turn Rasklad on "
            + "in the System Settings pane that opens, and the check mark appears here. The rest is optional."))
        intro.font = .systemFont(ofSize: 12)
        intro.preferredMaxLayoutWidth = 480
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.preferredMaxLayoutWidth = 360
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [footer, spacer, doneButton])
        bottom.alignment = .centerY

        let stack = NSStackView(views: [intro] + rows.map(\.view) + [bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(24, after: rows[1].view) // обязательное отдельно от необязательного
        rows.forEach { $0.view.widthAnchor.constraint(equalToConstant: 480).isActive = true }
        bottom.widthAnchor.constraint(equalToConstant: 480).isActive = true
        window.contentView = stack
        refresh()
        window.setContentSize(stack.fittingSize)
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let s = probe()
        let ready = s.ax && s.listen
        update(rows[0], done: s.ax, active: true)
        update(rows[1], done: s.listen, active: s.ax)
        update(rows[2], done: s.fnOn && s.fnSystemOff, active: ready)
        (rows[2].control as? NSButton)?.title = !s.fnOn ? tr("Включить", "Turn On") : (s.fnSystemOff ? tr("Готово", "Done") : tr("Открыть настройки", "Open Settings"))
        update(rows[3], done: s.capsOff, active: ready)
        (rows[3].control as? NSButton)?.title = s.capsOff ? tr("Готово", "Done") : tr("Открыть настройки", "Open Settings")
        update(rows[4], done: s.itActive, active: true)
        let it = rows[4].control as? NSButton
        it?.title = s.itActive ? tr("Готово", "Done") : (s.itInstalled ? tr("Открыть «Словарь»", "Open Dictionary") : tr("Установить", "Install"))
        if !s.itInstalled && ITDictionary.bundled == nil { it?.title = tr("Нет в сборке", "Not included"); it?.isEnabled = false }

        let k = settings.correctionKey
        keyPopup.selectItem(at: CorrectionKey.allCases.firstIndex(of: k) ?? 0)
        keyMark.stringValue = k.symbol
        keyMark.textColor = .controlAccentColor
        doneButton.isEnabled = ready
        footer.stringValue = !s.ax ? tr("Шаг 1 из 2.", "Step 1 of 2.") : !s.listen ? tr("Шаг 2 из 2.", "Step 2 of 2.")
            : tr("Права выданы. Остальное — по желанию.", "Permissions granted. The rest is optional.")
    }

    private func update(_ r: Row, done: Bool, active: Bool) {
        r.mark.stringValue = done ? "✓" : (active ? "●" : "○")
        r.mark.textColor = done ? .systemGreen : (active ? .controlAccentColor : .tertiaryLabelColor)
        r.control.isEnabled = active && !done
        guard !r.key.isEmpty, let b = r.control as? NSButton else { return }
        b.title = done ? tr("Готово", "Done")
            : (UserDefaults.standard.bool(forKey: r.key) ? tr("Открыть настройки", "Open Settings") : tr("Разрешить", "Allow"))
    }

    /// Первый раз — системный запрос (он же добавляет Rasklad в список), дальше — раздел Настроек.
    private func ask(_ key: String, pane: String, request: () -> Void) {
        if UserDefaults.standard.bool(forKey: key) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        } else {
            UserDefaults.standard.set(true, forKey: key)
            request()
        }
        refresh()
    }

    @objc private func stepAX() {
        ask("askedAX", pane: "Privacy_Accessibility") {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    @objc private func stepListen() {
        ask("askedListen", pane: "Privacy_ListenEvent") { _ = CGRequestListenEventAccess() }
    }

    /// Включает быструю смену в Rasklad и, если штатное действие 🌐 ещё активно, ведёт его отключать.
    @objc private func stepFn() {
        settings.fnSwitch = true
        if systemFnUsage() != 0 { openKeyboard() }
        refresh()
    }

    /// Копирует вложенный словарь в ~/Library/Dictionaries и открывает «Словарь», где его включают.
    @objc private func stepIT() {
        if !ITDictionary.installed {
            do { try ITDictionary.install() } catch { dlog("словарь IT-термины: \(error.localizedDescription)"); return }
            dlog("словарь IT-термины установлен")
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Dictionary.app"))
        refresh()
    }

    @objc private func openKeyboard() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    @objc private func keyChanged() {
        let k = CorrectionKey.allCases[keyPopup.indexOfSelectedItem]
        settings.correctionKey = k
        onKeyChange(k)
        refresh()
    }

    @objc private func finish() {
        timer?.invalidate()
        window.orderOut(nil)
        onDone()
    }

    /// Снимок окна в PNG — для проверки вёрстки без экрана (фон окна в снимок не попадает — рисуем его сами).
    func snapshot(to path: String, dark: Bool) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        refresh()
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.wantsLayer = true
        window.appearance!.performAsCurrentDrawingAppearance {
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
