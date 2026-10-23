import AppKit
import Carbon

/// Метка наших синтетических событий, чтобы перехват их не учитывал.
let ownEventTag: Int64 = 0x524B4C44

/// Слушает набор (listen-only CGEventTap), копит клавиши текущего слова,
/// по пробелу проверяет слово и при неверной раскладке перенабирает его.
/// Одиночная клавиша исправления (по умолчанию правый ⌥, с ⇧ или без) — `onRightOption`.
final class KeyTap {
    /// Перечитывается, когда пользователь добавляет или убирает раскладки в системе.
    var layouts: Layouts
    let settings: Settings
    var onRightOption: (ModifierTap.Kind) -> Void = { _ in }
    var onFn: () -> Void = {}
    /// Fn оказалась частью сочетания (Fn+стрелка) — вернуть раскладку.
    var onFnCancel: () -> Void = {}
    var onFix: (_ typed: String, _ fixed: String) -> Void = { _, _ in }
    /// remembered — слово добавлено в исключения (вторая отмена), иначе только возвращено.
    var onUndo: (_ typed: String, _ remembered: Bool) -> Void = { _, _ in }
    private var undoMemory = UndoMemory()
    /// Клавиша или клик пользователя (true — клик).
    var onActivity: (Bool) -> Void = { _ in }
    private var typing = TypingState()
    private var keys: [Int] { typing.keys }
    private var lastSkip: String?
    private var lastAppPair: String?
    private var lastFix: (typed: String, from: Lang, text: String)? // для отмены, живёт до следующей клавиши
    private var lastPunctFix: Character? // знак, придвинутый к слову (убран пробел перед ним), — для отмены
    var correctionKey: CorrectionKey = .rightOption { didSet { ropt = correctionKey.tap } }
    private var ropt = ModifierTap.rightOption, fnPress = FnPress()
    private var tap: CFMachPort?
    var running: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(layouts: Layouts, settings: Settings) {
        self.layouts = layouts
        self.settings = settings
        correctionKey = settings.correctionKey
        ropt = correctionKey.tap
    }

    /// false — нет права «Мониторинг ввода».
    func start() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return running }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, ctx in
            Unmanaged<KeyTap>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            dlog("tap был отключён системой (\(type.rawValue)), включён снова")
            return
        }
        if e.getIntegerValueField(.eventSourceUserData) == ownEventTag { return }
        // Поля паролей (защищённый ввод), экран блокировки, окна запроса пароля — не запоминаем и не правим.
        // Только Fn по-прежнему меняет раскладку: она ничего не набирает, а штатное 🌐 у пользователя отключено.
        if IsSecureEventInputEnabled() || secureAppIDs.contains(frontAppID() ?? "") {
            typing.reset()
            lastFix = nil
            ropt.other()
            let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
            fnEvent(type == .flagsChanged ? fnPress.flagsChanged(code: code, flags: e.flags.rawValue) : fnPress.other())
            return
        }
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            if let kind = ropt.flagsChanged(code: code, flags: e.flags.rawValue) {
                DispatchQueue.main.async { self.onRightOption(kind) }
            }
            fnEvent(fnPress.flagsChanged(code: code, flags: e.flags.rawValue))
            return
        }
        ropt.other()
        fnEvent(fnPress.other())
        lastFix = nil
        lastPunctFix = nil
        onActivity(type != .keyDown)
        guard type == .keyDown else { typing.reset(); return } // клик мышью — курсор мог уйти

        let f = e.flags
        let k = encodeKey(code: code, shift: f.contains(.maskShift), caps: f.contains(.maskAlphaShift))
        let lang = layouts.current()
        let ch = (0...50).contains(code) ? lang.flatMap { char(k, layouts.chars($0)) } : nil
        let modified = !f.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        // знак английской раскладки через ⌃⌥ (⌃⌥Б → «,») — это набор текста, а не сочетание клавиш
        let modPunct = modified ? modifiedPunct(code: code, flags: f.rawValue, layouts.enChars) : nil
        let typedChar = modPunct ?? (modified ? nil : ch)
        let punct = typedChar.flatMap { spaceBeforePunct(recent: typing.recent, char: $0) ? $0 : nil }
        defer { if let punct, let lang { fixSpaceBeforePunct(punct, lang) } }
        if let mp = modPunct { typing.punctTyped(mp); return }
        if typing.keyDown(code: code, key: k, char: ch, modified: modified, lang: lang) == .wordEnd {
            let (lang, ambiguous) = check()
            typing.endWord(lang: lang, ambiguous: ambiguous)
        }
    }

    private func fnEvent(_ e: FnPress.Event?) {
        switch e {
        case .down: onFn()          // сразу, в момент нажатия: индикатор у курсора покажет уже новую раскладку
        case .cancel: DispatchQueue.main.async { self.onFnCancel() }
        case nil: break
        }
    }

    /// Почему слово сейчас нельзя править как текст: поле — редактор кода или курсор внутри ``` / `…`.
    private func codeReason() -> String? {
        let ctx = focusedFieldContext()
        if isCodeEditor(ctx.classes) { return "редактор кода" }
        if caretInCode(caretAncestry()) { return "блок кода в поле" } // ``` уже стал блоком: клики и стрелки не сбивают
        return insideCode(field: ctx.before, typed: typing.recent) ? "внутри кода Markdown" : nil
    }

    /// Сначала неверная раскладка (если включено автопереключение), затем мелкая опечатка в текущей,
    /// затем неверная раскладка вместе с опечаткой.
    /// В коде (IDE и терминалы, редакторы кода, ``` и `…`) не правим — только ручная клавиша исправления.
    /// Возвращает язык, на котором оказалось слово (язык фразы для следующих), и неоднозначно ли оно.
    private func check() -> (Lang?, Bool) {
        // приложение — заново, без кеша; исключено, если так говорит владелец поля ввода или macOS
        let ids = [inputApp(fresh: true)?.bundleIdentifier, NSWorkspace.shared.frontmostApplication?.bundleIdentifier]
        let pair = ids[0] == ids[1] ? nil : "поле ввода \(ids[0] ?? "?"), активное \(ids[1] ?? "?")"
        if pair != lastAppPair { if let pair { dlog("приложение: \(pair)") }; lastAppPair = pair }
        guard !keys.isEmpty, let cur = layouts.current(),
              !anyExcluded(ids, excluded: settings.excludedApps, allowed: settings.allowedApps) else { return (nil, false) }
        let why = settings.protectCode ? codeReason() : nil
        let note = why.map { "\($0) в \(frontAppID() ?? "?")" }
        if note != lastSkip { // в лог — только смена причины, без слов
            if let note { dlog("правка пропущена: \(note)") }
            lastSkip = note
        }
        if why != nil { return (nil, false) }
        var typed = text(keys, layouts.chars(cur))
        let words = settings.exceptionWords()
        var result: (erase: Int, text: String, typed: String, target: Lang)?
        if Set(typing.langs.compactMap { $0 }).count > 1 {
            // слово начали в одной раскладке, закончили в другой — читаем клавиши целиком в каждой
            if settings.autoSwitch, let m = mixedFix(keys: keys, langs: typing.langs, layouts, context: typing.phraseLang),
               m.text != m.typed, !isException(typed: m.typed, other: m.text, words) {
                result = (keys.count + 1, m.text, m.typed, m.target)
            }
            typed = String(zip(keys, typing.langs).compactMap { k, l in l.flatMap { char(k, layouts.chars($0)) } })
        } else if settings.autoSwitch,
           let fix = phraseFix(prev: typing.ambiguousPrev, keys: keys, current: cur, layouts, context: typing.phraseLang) {
            if !isException(typed: typed, other: text(keys, layouts.chars(fix.target)), words) { result = fix }
        } else if settings.typos, !words.contains(exceptionKey(typed)) {
            if let t = typoFix(typed, lang: cur) {
                result = (keys.count + 1, t, typed, cur)
            } else if settings.autoSwitch, let f = layoutTypoFix(keys: keys, current: cur, layouts) {
                result = (keys.count + 1, f.text, typed, f.target) // неверная раскладка и опечатка сразу
            }
        }
        // случайный Caps Lock посреди слова: и в исправленном слове, и в обычном
        var caseFixed = false
        if let r = result, let c = caseFix(r.text, r.target) { result?.text = c; caseFixed = true }
        else if result == nil, !words.contains(exceptionKey(typed)), let c = caseFix(typed, cur) {
            result = (keys.count + 1, c, typed, cur); caseFixed = true
        }
        if debugWords { dlog("слово cur=\(cur) typed=\(typed) fix=\(result?.text ?? "nil")") }
        guard let result else { return (cur, isAmbiguous(keys: keys, current: cur, layouts)) }
        if caseFixed, capsLock() { setCapsLock(false) } // Caps Lock включили случайно — выключаем
        lastFix = (result.typed, cur, result.text)
        retype(erase: result.erase, with: result.text + " ", switchTo: result.target) // erase включает набранный пробел
        onFix(result.typed, result.text)
        return (result.target, false)
    }

    /// «слово ,» → «слово,»: знак уже ушёл в поле, поэтому стираем его вместе с пробелом и ставим вплотную.
    /// Только с «Исправлять опечатки», вне кода и приложений-исключений.
    private func fixSpaceBeforePunct(_ ch: Character, _ lang: Lang) {
        let ids = [inputApp(fresh: true)?.bundleIdentifier, NSWorkspace.shared.frontmostApplication?.bundleIdentifier]
        guard settings.typos, !anyExcluded(ids, excluded: settings.excludedApps, allowed: settings.allowedApps),
              !(settings.protectCode && codeReason() != nil) else { return }
        retype(erase: 2, with: String(ch), switchTo: lang)
        typing.spaceBeforePunctFixed()
        lastPunctFix = ch
    }

    /// Клавиша исправления сразу после автозамены: вернуть как было. Первая отмена слова — только вернуть,
    /// повторная за сеанс — ещё и запомнить в исключениях.
    func undoLastFix() -> Bool {
        if let p = lastPunctFix, let lang = layouts.current() {   // вернуть пробел перед знаком
            lastPunctFix = nil
            retype(erase: 1, with: " " + String(p), switchTo: lang)
            dlog("отмена: пробел перед знаком возвращён")
            return true
        }
        guard let f = lastFix else { return false }
        lastFix = nil
        retype(erase: f.text.count + 1, with: f.typed + " ", switchTo: f.from)
        typing.phraseLang = f.from
        let remember = undoMemory.undo(f.typed)
        if remember { settings.addException(f.typed) }
        onUndo(f.typed, remember)
        dlog(remember ? "отмена автозамены, слово добавлено в исключения" : "отмена автозамены")
        return true
    }

    /// Клавиша исправления посреди слова: перенабрать его в другой раскладке (буфер клавиш остаётся тем же).
    func convertCurrentWord() -> Bool {
        guard !keys.isEmpty, let cur = layouts.current() else { return false }
        let other = text(keys, layouts.chars(cur.other))
        guard other.count == keys.count else { return false }
        retype(erase: keys.count, with: other, switchTo: cur.other)
        return true
    }

    /// Сразу, из обработчика нажатия: если отложить, следующая клавиша пользователя успеет раньше Backspace,
    /// и стёрта будет она, а не конец слова. Раскладку переключаем до набора — приложения, которые читают
    /// код клавиши, а не символ, переведут его уже в нужной раскладке.
    /// Клавиша исправления сразу после пробела: перенабрать только что законченное слово в другой
    /// раскладке (повторное нажатие вернёт обратно). После любой клавиши или клика слово уже забыто.
    func convertLastWord() -> Bool {
        guard typing.keys.isEmpty, let w = typing.lastWord,
              let r = lastWordConversion(keys: w.keys, langs: w.langs, layouts) else { return false }
        retype(erase: r.erase, with: r.text + " ", switchTo: r.target)
        typing.lastWordConverted(to: r.target)
        dlog("предыдущее слово перенабрано в \(r.target)")
        return true
    }

    private func retype(erase: Int, with text: String, switchTo lang: Lang) {
        if layouts.current() != lang { selectLayout(layouts.source(lang)) } // та же раскладка — не дёргаем индикатор
        for _ in 0..<erase { postKey(CGKeyCode(kVK_Delete)) }
        for ch in text { postChar(ch, key: layouts.key(for: ch, in: lang)) }
    }
}


private func tagged(_ e: CGEvent?, _ flags: CGEventFlags) -> CGEvent? {
    e?.flags = flags // явно: удерживаемые пользователем модификаторы не примешиваются
    e?.setIntegerValueField(.eventSourceUserData, value: ownEventTag)
    return e
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        tagged(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down), flags)?.post(tap: .cghidEventTap)
    }
}

/// Символ как нажатие: код и ⇧ настоящей клавиши раскладки (если есть) плюс сам символ —
/// большинство приложений берут символ, а игры и удалённые рабочие столы — код клавиши.
func postChar(_ ch: Character, key: (code: Int, shift: Bool)?) {
    var units = Array(String(ch).utf16)
    let code = CGKeyCode(key?.code ?? (ch == " " ? kVK_Space : 0))
    for down in [true, false] {
        let e = tagged(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down), key?.shift == true ? .maskShift : [])
        e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        e?.post(tap: .cghidEventTap)
    }
}
