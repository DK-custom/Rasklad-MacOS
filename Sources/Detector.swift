import AppKit

/// Слово есть в системном словаре языка (знаки препинания проверка пропускает).
/// Слова целиком из заглавных проверка считает аббревиатурами и пропускает — их проверяем строчными.
func isWord(_ text: String, _ lang: Lang) -> Bool {
    let letters = text.filter(\.isLetter)
    let word = letters.count >= 2 && letters.allSatisfy(\.isUppercase) ? text.lowercased() : text
    return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: lang.rawValue,
                                        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

/// Набранные клавиши (`encodeKey`) в раскладке `current`: если в ней слова нет,
/// а в другой раскладке есть — вернуть исправленный текст и целевую раскладку.
/// `context` — язык предыдущих слов фразы: слово, которое есть в обоих языках («руку»/here),
/// переключаем, только если фраза уже идёт на другом языке.
func correction(keys: [Int], current: Lang, _ l: Layouts, context: Lang? = nil) -> (text: String, target: Lang)? {
    let target = current.other
    let typed = text(keys, l.chars(current))
    let other = text(keys, l.chars(target))
    guard typed.count == keys.count, other.count == keys.count else { return nil }
    let letters = max(other.filter(\.isLetter).count, typed.filter(\.isLetter).count)
    if (1...3).contains(letters) {
        // короткие: только по спискам частых слов; сравниваем позиции, где буква хотя бы в одной
        // раскладке (на месте буквы может стоять знак: «ё» на клавише \, «ю» на точке)
        let pairs = zip(typed, other).filter { $0.0.isLetter || $0.1.isLetter }
        let o = String(pairs.map(\.1)).lowercased(), t = String(pairs.map(\.0)).lowercased()
        guard commonShort[target]!.contains(o), !commonShort[current]!.contains(t) else { return nil }
        return (other, target)
    }
    guard letters >= 2, isWord(other, target) else { return nil }
    if !isWord(typed, current) { return (other, target) }
    return context == target && letters >= 3 ? (other, target) : nil
}

/// Слово есть в обоих языках («руку» / here) — само по себе не решить, решает следующее слово фразы.
func isAmbiguous(keys: [Int], current: Lang, _ l: Layouts) -> Bool {
    let typed = text(keys, l.chars(current)), other = text(keys, l.chars(current.other))
    guard typed.count == keys.count, other.count == keys.count, other.filter(\.isLetter).count >= 3 else { return false }
    return isWord(typed, current) && isWord(other, current.other)
}

/// Исправление слова; если предыдущее слово было неоднозначным, а это явно на другом языке —
/// исправить оба («руку цу» → «here we»). erase — сколько символов стереть, включая набранные пробелы.
func phraseFix(prev: [Int]?, keys: [Int], current: Lang, _ l: Layouts, context: Lang?)
    -> (erase: Int, text: String, typed: String, target: Lang)? {
    guard let fix = correction(keys: keys, current: current, l, context: context) else { return nil }
    let typed = text(keys, l.chars(current))
    if let prev, fix.target == current.other, isAmbiguous(keys: prev, current: current, l) {
        return (prev.count + 1 + keys.count + 1, text(prev, l.chars(fix.target)) + " " + fix.text,
                text(prev, l.chars(current)) + " " + typed, fix.target)
    }
    return (keys.count + 1, fix.text, typed, fix.target)
}

/// Слово набрано частью в одной раскладке, частью в другой («ска;b» — «скажи», где «жи» уже в EN):
/// читаем все клавиши целиком в каждой раскладке и берём ту, где получилось слово.
/// `langs` — раскладка каждого нажатия; если оба прочтения — слова, решает язык фразы, иначе раскладка последней клавиши.
func mixedFix(keys: [Int], langs: [Lang?], _ l: Layouts, context: Lang? = nil)
    -> (text: String, typed: String, target: Lang)? {
    let used = Set(langs.compactMap { $0 })
    guard used.count > 1, langs.count == keys.count else { return nil }
    let typed = String(zip(keys, langs).compactMap { k, lang in lang.flatMap { char(k, l.chars($0)) } })
    func reading(_ lang: Lang) -> String? {
        let t = text(keys, l.chars(lang))
        guard t.count == keys.count else { return nil }
        let letters = t.filter(\.isLetter).count
        if (1...3).contains(letters) { return commonShort[lang]!.contains(t.lowercased()) ? t : nil }
        return letters >= 2 && isWord(t, lang) ? t : nil
    }
    let found = [Lang.ru, .en].compactMap { lang in reading(lang).map { (lang, $0) } }
    let last = langs.last.flatMap { $0 }
    guard let pick = found.count == 1 ? found[0]
            : found.first(where: { $0.0 == context }) ?? found.first(where: { $0.0 == last }) ?? found.first
    else { return nil }
    return (pick.1, typed, pick.0)
}

/// Случайный Caps Lock посреди слова: строчные в начале, дальше только заглавные (≥2).
/// «правописанИЕ» → «правописание»; строчная только первая — Caps Lock плюс ⇧ на ней: «пРИВЕТ» → «Привет».
/// Только если исправленное — слово. Проверка орфографии к регистру частых слов безразлична («приВЕТ» для неё
/// слово), поэтому настоящие слова такого вида (macOS, iOS, mRNA) узнаём по списку и окончанию «OS».
let mixedCaseWords: Set<String> = ["mRNA", "tRNA", "eID", "eSIM", "iMAC", "kWT"]

func caseFix(_ typed: String, _ lang: Lang) -> String? {
    let chars = Array(typed)
    guard let first = chars.firstIndex(where: \.isLetter), let last = chars.lastIndex(where: \.isLetter) else { return nil }
    let core = Array(chars[first...last])
    guard core.count >= 3, core.allSatisfy(\.isLetter),
          let up = core.firstIndex(where: \.isUppercase), up > 0, core.count - up >= 2,
          core[..<up].allSatisfy(\.isLowercase), core[up...].allSatisfy(\.isUppercase) else { return nil }
    let word = String(core)
    guard !word.hasSuffix("OS"), !mixedCaseWords.contains(word) else { return nil }
    let fixed = up == 1 ? String(core[0]).uppercased() + String(core[1...]).lowercased() : word.lowercased()
    guard isWord(fixed, lang) else { return nil }
    return String(chars[..<first]) + fixed + String(chars[(last + 1)...])
}

/// Одиночное нажатие модификатора (с ⇧ или без): нажали и отпустили без других клавиш и модификаторов.
struct ModifierTap {
    enum Kind { case plain, shifted }
    let code: Int        // keycode модификатора
    let downBit: UInt64  // бит флагов, означающий «эта клавиша зажата»
    let others: UInt64   // модификаторы, при которых нажатие не считается одиночным
    private var armed = false, shifted = false
    private static let shift: UInt64 = 0x20000

    static let rightOption = ModifierTap(code: 61, downBit: 0x40, others: 0x40000 | 0x100000 | 0x20) // ⌃ ⌘ левый ⌥
    static let fn = ModifierTap(code: 63, downBit: 0x800000, others: 0x40000 | 0x100000 | 0x80000)   // ⌃ ⌘ ⌥

    init(code: Int, downBit: UInt64, others: UInt64) {
        self.code = code
        self.downBit = downBit
        self.others = others
    }

    /// flagsChanged; не nil — пора выполнить действие.
    mutating func flagsChanged(code: Int, flags: UInt64) -> Kind? {
        switch code {
        case 56, 60: // ⇧ левый/правый не мешает, а запоминается
            if flags & Self.shift != 0 { shifted = true }
            return nil
        case self.code:
            if flags & downBit != 0 {
                armed = flags & others == 0
                shifted = flags & Self.shift != 0
                return nil
            }
            defer { armed = false }
            return armed ? (shifted ? .shifted : .plain) : nil
        default:
            armed = false
            return nil
        }
    }

    /// Любая клавиша или клик между нажатием и отпусканием.
    mutating func other() { armed = false }
}

/// Клавиша исправления (отмена замены, конвертация, с ⇧ — определение). По умолчанию правый ⌥.
/// У ⌥ и ⌘ — правая или левая; Control на клавиатуре MacBook один, поэтому без «правый/левый».
enum CorrectionKey: String, CaseIterable {
    case rightOption, leftOption, rightCommand, leftCommand, control

    var title: String {
        switch self {
        case .rightOption: "Правый ⌥ Option"
        case .leftOption: "Левый ⌥ Option"
        case .rightCommand: "Правый ⌘ Command"
        case .leftCommand: "Левый ⌘ Command"
        case .control: "⌃ Control"
        }
    }

    /// Для подсказок и меню: «правый ⌥».
    var short: String {
        switch self {
        case .rightOption: "правый ⌥"
        case .leftOption: "левый ⌥"
        case .rightCommand: "правый ⌘"
        case .leftCommand: "левый ⌘"
        case .control: "⌃ Control"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption: "⌥"
        case .rightCommand, .leftCommand: "⌘"
        case .control: "⌃"
        }
    }

    var tap: ModifierTap {
        switch self {
        case .rightOption: .rightOption
        case .leftOption: ModifierTap(code: 58, downBit: 0x20, others: 0x40000 | 0x100000 | 0x40)     // ⌃ ⌘ правый ⌥
        case .rightCommand: ModifierTap(code: 54, downBit: 0x10, others: 0x40000 | 0x80000 | 0x08)    // ⌃ ⌥ левый ⌘
        case .leftCommand: ModifierTap(code: 55, downBit: 0x08, others: 0x40000 | 0x80000 | 0x10)     // ⌃ ⌥ правый ⌘
        case .control: ModifierTap(code: 59, downBit: 0x01, others: 0x80000 | 0x100000 | 0x2000)      // ⌥ ⌘ правый ⌃
        }
    }
}

/// Нажатие: keycode*4 + ⇧(1) + Caps Lock(2). Caps Lock хранится отдельно, потому что
/// одна клавиша бывает буквой в одной раскладке и знаком в другой (' и «э»).
func encodeKey(code: Int, shift: Bool, caps: Bool) -> Int { code * 4 + (shift ? 1 : 0) + (caps ? 2 : 0) }

/// Символ нажатия в раскладке (`chars`: keycode*2+shift); Caps Lock — как ⇧, но только на её буквах.
func char(_ key: Int, _ chars: [Int: Character]) -> Character? {
    let code = key / 4, shift = key & 1 != 0, caps = key & 2 != 0
    let letter = chars[code * 2]?.isLetter ?? false
    return chars[code * 2 + ((caps && letter) != shift ? 1 : 0)]
}

func text(_ keys: [Int], _ chars: [Int: Character]) -> String { String(keys.compactMap { char($0, chars) }) }

/// Частые слова до 3 букв. Для коротких слов проверка орфографии бесполезна: она принимает
/// одиночные буквы, сокращения и редкие формы (z, шт, иге, tot), поэтому решаем по этим спискам.
let commonShort: [Lang: Set<String>] = [
    .ru: Set("""
        я в и с к у о а не на по за из от до об во со ко то он мы вы ты она оно они как так что где кто
        чем там тут вот уже еще ещё был это его её ее мне вам нам все всё вся всю для при про над под без
        или да нет ну ли же бы два три раз сам мой моя мою мои наш ваш их ему ей им нас вас эта эти эту
        тот той чей чья чьё дом год час день кот лес мир сон дал дай иди
        """.split(whereSeparator: \.isWhitespace).map(String.init)),
    .en: Set("""
        a i an as at be by do go he if in is it me my no of on or so to up us we am ok oh hi i'm i'd
        the and are but can did for get got has had her him his how its let may new not now old one our
        out own say see she too two use was way who why yes yet you all any big few man men off put run
        set try day end far ask add ago lot top bad buy car cat dog eat fix god job key law low sit
        bye bug log app web
        """.split(whereSeparator: \.isWhitespace).map(String.init)),
]

/// Расстояние Левенштейна с перестановкой соседних символов (optimal string alignment).
func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var d = (0...a.count).map { i in (0...b.count).map { j in i == 0 ? j : (j == 0 ? i : 0) } }
    for i in 1...a.count {
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
        }
    }
    return d[a.count][b.count]
}

/// Исправление мелкой опечатки в набранном слове (знаки по краям сохраняются).
/// `correct` — вариант исправления для ядра слова или nil, если слово верное или вариантов нет.
func typoFix(_ typed: String, _ correct: (String) -> String?) -> String? {
    let chars = Array(typed)
    guard let first = chars.firstIndex(where: \.isLetter), let last = chars.lastIndex(where: \.isLetter) else { return nil }
    let core = String(chars[first...last])
    guard core.count >= 4, core.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }),
          !core.allSatisfy({ !$0.isLetter || $0.isUppercase }), // аббревиатуры не трогаем
          let fixed = correct(core), fixed != core, !fixed.contains(" "),
          editDistance(core.lowercased(), fixed.lowercased()) <= (core.count >= 7 ? 2 : 1) else { return nil }
    return String(chars[..<first]) + fixed + String(chars[(last + 1)...])
}

/// Неверная раскладка и опечатка сразу («ghbtdn» → «привет»): в текущей раскладке это не слово и не опечатка,
/// а в другой — опечатка. Только от 5 букв: короткое сочетание легко «исправить» во что угодно.
/// Исправленное слово должно найтись в словарях macOS: проверка орфографии принимает и бессмыслицу
/// вроде «пкфапфтф», а словарь находит только настоящие слова (в любой форме).
func layoutTypoFix(keys: [Int], current: Lang, _ l: Layouts) -> (text: String, target: Lang)? {
    let target = current.other
    let typed = text(keys, l.chars(current)), other = text(keys, l.chars(target))
    guard typed.count == keys.count, other.count == keys.count, other.filter(\.isLetter).count >= 5,
          !isWord(typed, current), typoFix(typed, lang: current) == nil,
          let fixed = typoFix(other, lang: target), inDictionaries(fixed) else { return nil }
    return (fixed, target)
}

func inDictionaries(_ word: String) -> Bool {
    let w = word.trimmingCharacters(in: .punctuationCharacters)
    return DCSCopyTextDefinition(nil, w as CFString, CFRange(location: 0, length: (w as NSString).length)) != nil
}

func typoFix(_ typed: String, lang: Lang) -> String? {
    typoFix(typed) { core in
        guard !isWord(core, lang), let fixed = NSSpellChecker.shared.correction(
            forWordRange: NSRange(location: 0, length: (core as NSString).length), in: core,
            language: lang.rawValue, inSpellDocumentWithTag: 0) else { return nil }
        // проверка иногда предлагает вариант, которого сама не считает словом («пкфапфтф») — такой не берём
        return isWord(fixed, lang) ? fixed : nil
    }
}

/// Курсор внутри кода Markdown: незакрытый блок ``` или незакрытая `…` в текущей строке.
/// `before` — текст перед курсором.
func insideCode(_ before: String) -> Bool {
    let blocks = before.components(separatedBy: "```")
    if blocks.count % 2 == 0 { return true } // нечётное число ``` — блок открыт
    let line = blocks.last!.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
    return line.filter { $0 == "`" }.count % 2 == 1
}

/// Поле — редактор кода на веб-странице (Monaco, CodeMirror, Ace): по классам элемента и его предков.
func isCodeEditor(_ classes: [String]) -> Bool {
    let markers = ["monaco-editor", "inputarea", "cm-content", "cm-editor", "CodeMirror", "ace_text-input", "ace_editor"]
    return classes.contains { c in markers.contains { c.hasPrefix($0) } }
}

/// Буфер набора: клавиши текущего слова и недавний текст (по нему узнаём ``` и `, если поле не отдаёт текст).
/// Где курсор после клика, стрелок или сочетаний с ⌘/⌃/⌥, неизвестно — тогда всё сбрасываем.
struct TypingState {
    enum Result { case none, wordEnd }
    private(set) var keys: [Int] = []   // encodeKey
    /// Раскладка, в которой было каждое нажатие: слово могут начать в одной, а закончить в другой.
    private(set) var langs: [Lang?] = []
    private(set) var recent = ""
    /// Язык слов текущей фразы — для слов, которые есть в обоих языках. Enter, клик, стрелки сбрасывают.
    var phraseLang: Lang?
    /// Клавиши предыдущего слова, если оно было неоднозначным и сразу за ним идёт текущее.
    private(set) var ambiguousPrev: [Int]?
    /// Только что законченное слово — пока после пробела ничего не нажимали (для ручной правки клавишей
    /// исправления). Любая клавиша, клик, Enter, Backspace — забыть: курсор мог уйти.
    private(set) var lastWord: (keys: [Int], langs: [Lang?])?

    /// keyDown; `char` — символ в текущей раскладке; `modified` — с ⌘, ⌃ или ⌥.
    /// `.wordEnd` — пробел: проверить слово, затем `endWord()`.
    mutating func keyDown(code: Int, key: Int, char: Character?, modified: Bool, lang: Lang? = nil) -> Result {
        if code != 49 { lastWord = nil }
        if modified { reset(); return .none }
        switch code {
        case 49: return .wordEnd                                       // пробел
        case 51:                                                       // Backspace
            if keys.isEmpty { ambiguousPrev = nil }                    // стирают уже предыдущее слово
            if !keys.isEmpty { keys.removeLast(); langs.removeLast() }
            if !recent.isEmpty { recent.removeLast() }
        case 36, 48:                                                   // Enter, Tab: не переключаем
            keys.removeAll()
            langs.removeAll()
            phraseLang = nil
            ambiguousPrev = nil
            remember(code == 36 ? "\n" : "\t")
        case 0...50:
            keys.append(key)
            langs.append(lang)
            if let char { remember(String(char)) }
        default: reset()                                               // стрелки, Esc, F-клавиши…
        }
        return .none
    }

    /// `lang` — на каком языке оказалось слово (nil — не знаем, язык фразы прежний).
    /// `ambiguous` — слово есть в обоих языках: следующее слово может исправить и его.
    mutating func endWord(lang: Lang? = nil, ambiguous: Bool = false) {
        ambiguousPrev = ambiguous && !keys.isEmpty ? keys : nil
        lastWord = keys.isEmpty ? nil : (keys, langs)
        keys.removeAll()
        langs.removeAll()
        if let lang { phraseLang = lang }
        remember(" ")
    }

    /// Предыдущее слово перенабрали в другой раскладке — повторное нажатие вернёт обратно.
    mutating func lastWordConverted(to lang: Lang) {
        guard let w = lastWord else { return }
        lastWord = (w.keys, Array(repeating: lang, count: w.keys.count))
        phraseLang = lang
    }

    mutating func reset() {
        lastWord = nil
        keys.removeAll()
        langs.removeAll()
        recent = ""
        phraseLang = nil
        ambiguousPrev = nil
    }

    private mutating func remember(_ s: String) {
        recent += s
        if recent.count > 4000 { recent.removeFirst(recent.count - 4000) }
    }
}

/// Отмена автозамены: первая — только вернуть набранное (случайная отмена не должна навсегда
/// блокировать слово), вторая для того же слова за сеанс — запомнить в исключениях.
struct UndoMemory {
    private var once: Set<String> = []

    /// true — пора добавить слово в исключения.
    mutating func undo(_ word: String) -> Bool {
        let k = word.lowercased()
        if once.contains(k) { once.remove(k); return true }
        once.insert(k)
        return false
    }
}

enum ForgetResult { case forgotten, notLearned, empty, failed }

/// Забыть слово из «Запомнить правописание». Только выученное пользователем: слово из словаря
/// (или которого нет вовсе) не трогаем — его нельзя «сломать» этой командой.
func forgetLearnedWord(_ raw: String) -> ForgetResult {
    let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return .empty }
    let sc = NSSpellChecker.shared
    guard sc.hasLearnedWord(word) else { return .notLearned }
    sc.unlearnWord(word)
    return sc.hasLearnedWord(word) ? .failed : .forgotten
}

/// Fn/🌐: переключаем раскладку при нажатии — индикатор «РУ/A» у курсора показывается сразу и иначе
/// показал бы прежнюю. Если, пока Fn зажата, нажали другую клавишу или модификатор (Fn+стрелка, Fn+⌘) —
/// это сочетание, а не смена языка: `.cancel`, раскладку вернуть.
struct FnPress {
    enum Event { case down, cancel }
    private var held = false
    private static let fnBit: UInt64 = 0x800000
    private static let others: UInt64 = 0x40000 | 0x100000 | 0x80000 // ⌃ ⌘ ⌥

    mutating func flagsChanged(code: Int, flags: UInt64) -> Event? {
        if code == 63 {
            let down = flags & Self.fnBit != 0
            held = down && flags & Self.others == 0
            return held ? .down : nil
        }
        return other()
    }

    /// Клавиша, клик или другой модификатор: если Fn зажата и раскладку уже сменили — откат.
    mutating func other() -> Event? {
        guard held else { return nil }
        held = false
        return .cancel
    }
}

/// Ручная правка предыдущего слова (клавиша исправления сразу после пробела): перенабрать его
/// в другой раскладке. erase — слово и набранный после него пробел.
func lastWordConversion(keys: [Int], langs: [Lang?], _ l: Layouts) -> (erase: Int, text: String, target: Lang)? {
    guard !keys.isEmpty, let from = langs.last.flatMap({ $0 }) ?? l.current() else { return nil }
    let target = from.other
    let t = text(keys, l.chars(target))
    guard t.count == keys.count else { return nil }
    return (keys.count + 1, t, target)
}
