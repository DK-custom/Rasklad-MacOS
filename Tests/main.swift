// Самопроверка конвертера на реальных раскладках этой машины: ./build.sh test
import AppKit
guard let l = Layouts() else { fatalError("нет раскладок RU и EN") }

func check(_ got: String, _ want: String) {
    print(got == want ? "ok  " : "FAIL", got, "==", want)
    if got != want { exit(1) }
}

check(convert("ghbdtn", l.enToRu), "привет")
check(convert("Ghbdtn^ rfr ltkf", l.enToRu), "Привет, как дела")
check(convert("руддщ цщкдв", l.ruToEn), "hello world")
check(convert("[jhjij", l.enToRu), "хорошо")
check(convert(convert("Съешь же ещё этих мягких булок", l.ruToEn), l.enToRu), "Съешь же ещё этих мягких булок")
check(detectDirection("руддщ") == .ruToEn ? "ru" : "en", "ru")
check(detectDirection("ghbdtn") == .ruToEn ? "ru" : "en", "en")
// Правило автопереключения: (набрано в раскладке, текст) -> во что заменить или nil
// caps: набрано с Caps Lock без ⇧ — ищем клавишу по строчному символу
func decide(_ typed: String, in lang: Lang, caps: Bool = false, context: Lang? = nil) -> String {
    let inv = Dictionary(l.chars(lang).map { ($1, $0) }, uniquingKeysWith: min)
    let keys = typed.map { ch -> Int in
        let idx = inv[caps ? Character(ch.lowercased()) : ch]!
        return encodeKey(code: idx / 2, shift: idx % 2 == 1, caps: caps)
    }
    return correction(keys: keys, current: lang, l, context: context)?.text ?? "nil"
}
check(decide("ghbdtn", in: .en), "привет")
check(decide("Ghbdtn^", in: .en), "Привет,")
check(decide("yt", in: .en), "не")
check(decide("руддщ", in: .ru), "hello")
check(decide("hello", in: .en), "nil")      // верное слово не трогаем
check(decide("привет", in: .ru), "nil")
check(decide("qwzx", in: .en), "nil")       // мусор в обеих раскладках
check(decide("e", in: .en), "у")            // частое однобуквенное слово
check(decide("qz", in: .en), "nil")         // «йя» — не частое короткое слово
check(decide("i", in: .en), "nil")          // «i» само частое в EN
check(decide("123", in: .en), "nil")

// Исключения: файл по строке на слово, # — комментарий; совпадение по набранному или исправленному виду
let ex = parseExceptions("  Ghb\n# комментарий\n\nok\n")
check(ex.sorted().joined(separator: ","), "ghb,ok")
check(isException(typed: "Ghb,", other: "При,", ex) ? "да" : "нет", "да")
check(isException(typed: "ghbdtn", other: "привет", ["привет"]) ? "да" : "нет", "да")
check(isException(typed: "ghbdtn", other: "привет", ex) ? "да" : "нет", "нет")

// Одиночное нажатие правого ⌥ (флаги: 0x40 — правый ⌥, 0x20 — левый ⌥, 0x80000 — любой ⌥)
func tapSeq(_ steps: [(Int, UInt64)?], _ start: ModifierTap = .rightOption) -> String {
    var t = start, fired: ModifierTap.Kind? = nil
    for s in steps {
        if let (code, flags) = s { fired = t.flagsChanged(code: code, flags: flags) } else { t.other() }
    }
    return fired.map { "\($0)" } ?? "нет"
}
check(tapSeq([(61, 0x80040), (61, 0x100)]), "plain")
check(tapSeq([(61, 0x80040), nil, (61, 0x100)]), "нет")                    // ⌥+клавиша
check(tapSeq([(56, 0x20102), (61, 0xA0142), (61, 0x20102)]), "shifted")    // ⇧ зажат, затем правый ⌥
check(tapSeq([(61, 0x80040), (56, 0xA0142), (56, 0x80040), (61, 0x100)]), "shifted") // ⇧ внутри
check(tapSeq([(61, 0x140040), (61, 0x100100)]), "нет")                     // с ⌘
check(tapSeq([(58, 0x80020), (58, 0x100)]), "нет")                         // левый ⌥
check(tapSeq([(61, 0x80040), (58, 0x80060), (58, 0x80040), (61, 0x100)]), "нет") // оба ⌥

// Короткие слова и сокращения с апострофом из списка
check(decide("ину", in: .ru), "bye")
check(decide("игп", in: .ru), "bug")
check(decide("шэь", in: .ru), "i'm")
// Неоднозначное слово (есть в обоих языках) — по языку фразы: «руку» после английского слова → here
check(decide("руку", in: .ru), "nil")
check(decide("руку", in: .ru, context: .en), "here")
check(decide("руку", in: .ru, context: .ru), "nil")
check(decide("hello", in: .en, context: .ru), "nil")          // верное и непохожее на русское — не трогаем
check(decide("ghbdtn", in: .en, context: .en), "привет")       // явная ошибка раскладки — независимо от фразы

// Все частые короткие слова: в неверной раскладке исправляются, в верной не трогаются
do {
    var bad: [String] = []
    for lang in [Lang.ru, .en] {
        let inv = Dictionary(l.chars(lang).map { ($1, $0) }, uniquingKeysWith: min)
        for w in commonShort[lang]!.sorted() {
            let k = w.compactMap { inv[$0] }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
            let fixed = correction(keys: k, current: lang.other, l)?.text
            if fixed != w { bad.append("\(text(k, l.chars(lang.other)))→\(fixed ?? "nil")≠\(w)") }
            if let kept = correction(keys: k, current: lang, l) { bad.append("\(w) заменено на \(kept.text)") }
        }
    }
    check(bad.isEmpty ? "короткие ok" : bad.joined(separator: " "), "короткие ok")
}
check(decide("рщц", in: .ru), "how")

// Одиночное нажатие Fn (код 63, флаг 0x800000)
check(tapSeq([(63, 0x800100), (63, 0x100)], .fn), "plain")
check(tapSeq([(63, 0x800100), nil, (63, 0x100)], .fn), "нет")             // Fn+стрелка/F-клавиша
check(tapSeq([(55, 0x100108), (63, 0x900108), (63, 0x100108)], .fn), "нет") // ⌘ зажат
check(tapSeq([(61, 0x80040), (61, 0x100)], .fn), "нет")                     // правый ⌥ — не Fn
check(tapSeq([(63, 0x800100), (63, 0x100)]), "нет")                         // Fn — не правый ⌥

// Клавиша исправления на выбор: правый/левый ⌥ (по умолчанию правый), правый/левый ⌘, ⌃
check(tapSeq([(54, 0x100110), (54, 0x100)], CorrectionKey.rightCommand.tap), "plain")
check(tapSeq([(54, 0x100110), nil, (54, 0x100)], CorrectionKey.rightCommand.tap), "нет")      // ⌘C
check(tapSeq([(55, 0x100108), (55, 0x100)], CorrectionKey.rightCommand.tap), "нет")           // левый ⌘
check(tapSeq([(56, 0x20102), (54, 0x120112), (54, 0x20102)], CorrectionKey.rightCommand.tap), "shifted")
check(tapSeq([(59, 0x40101), (59, 0x100)], CorrectionKey.control.tap), "plain")              // ⌃ (на MacBook он один)
check(tapSeq([(59, 0x40101), nil, (59, 0x100)], CorrectionKey.control.tap), "нет")           // ⌃C
check(tapSeq([(58, 0x80120), (58, 0x100)], CorrectionKey.leftOption.tap), "plain")
check(tapSeq([(61, 0x80140), (61, 0x100)], CorrectionKey.leftOption.tap), "нет")             // правый ⌥ при выбранном левом
check(tapSeq([(55, 0x100108), (55, 0x100)], CorrectionKey.leftCommand.tap), "plain")
check(tapSeq([(54, 0x100110), (54, 0x100)], CorrectionKey.leftCommand.tap), "нет")           // правый ⌘ при выбранном левом
check(CorrectionKey.allCases.map(\.symbol).joined(), "⌥⌥⌘⌘⌃")
check(tapSeq([(61, 0x80040), (61, 0x100)], CorrectionKey.rightCommand.tap), "нет")            // ⌥ при выбранном ⌘
check(tapSeq([(61, 0x80040), (61, 0x100)], CorrectionKey.rightOption.tap), "plain")
check(CorrectionKey(rawValue: "мусор") == nil ? "nil" : "?", "nil")

// Caps Lock: на буквах раскладки работает как ⇧, на цифрах и знаках — нет; заглавные слова тоже проверяются
check(decide("RFR", in: .en, caps: true), "КАК")
check(decide("'NJ", in: .en, caps: true), "ЭТО")        // ' в EN — знак, но в RU — буква «Э»
check(decide("HF,JNFTN", in: .en, caps: true), "РАБОТАЕТ")
check(decide("ЙЦЯЧ", in: .ru, caps: true), "nil")      // QWZX — мусор в обеих раскладках
check(decide("РУДДЩ", in: .ru, caps: true), "HELLO")
check(decide("HELLO", in: .en, caps: true), "nil")      // верное заглавное не трогаем
check(String(char(encodeKey(code: 18, shift: false, caps: true), l.enChars)!), "1")

// Caps Lock переживает переключение раскладки (macOS сам его сбрасывает); исходное состояние восстанавливается
do {
    let startCaps = capsLock(), startLang = l.current() ?? .en
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
    setCapsLock(true); settle()
    selectLayout(l.source(startLang.other)); settle()
    let kept = capsLock()
    selectLayout(l.source(startLang)); settle()
    setCapsLock(startCaps); settle()
    check(kept ? "caps сохранён" : "caps сброшен", "caps сохранён")
}
// Опечатки: расстояние с перестановкой соседних букв
check("\(editDistance("нормлаьно", "нормально"))", "1")   // перестановка
check("\(editDistance("работет", "работает"))", "1")       // пропуск
check("\(editDistance("helo", "help"))", "1")
check("\(editDistance("kitten", "sitting"))", "3")
// Правило: ≥4 букв, правка ≤1 (≤2 для слов от 7 букв), знаки по краям сохраняются, CAPS не трогаем
check(typoFix("helo,", { _ in "help" }) ?? "nil", "help,")
check(typoFix("teh", { _ in "the" }) ?? "nil", "nil")              // короче 4
check(typoFix("wrdo", { _ in "world" }) ?? "nil", "nil")           // правка 2 для короткого
check(typoFix("becuase", { _ in "because" }) ?? "nil", "because")
check(typoFix("HELO", { _ in "HELP" }) ?? "nil", "nil")            // аббревиатура
check(typoFix("abcd", { _ in nil }) ?? "nil", "nil")
// Порядок словарей — как в настройках «Словаря» (служба отдаёт их в произвольном порядке)
do {
    let prefs = ["/x/Wikipedia.wikipediadictionary", "com.apple.dictionary.ru.oup", "/u/ITTerms.dictionary", "com.apple.dictionary.ODE"]
    let dicts = [("ODE", "com.apple.dictionary.ODE", "/s/ODE.dictionary"), ("Новый", "x.new", "/s/New.dictionary"),
                 ("IT", "local.it", "/u/ITTerms.dictionary"), ("Толковый", "com.apple.dictionary.ru.oup", "/s/Russian.dictionary")]
    let sorted = sortByPreference(dicts, prefs: prefs) { [$0.1, $0.2] }
    check(sorted.map(\.0).joined(separator: ","), "Толковый,IT,ODE,Новый") // по id или пути; неизвестные — в конце
}
// Живой словарь
check(typoFix("првиет", lang: .ru) ?? "nil", "привет")
check(typoFix("Првиет!", lang: .ru) ?? "nil", "Привет!")
check(typoFix("нормлаьно", lang: .ru) ?? "nil", "нормально")
check(typoFix("becuase", lang: .en) ?? "nil", "because")
check(typoFix("спасибо", lang: .ru) ?? "nil", "nil")              // верное слово
check(typoFix("asdfgh", lang: .en) ?? "nil", "nil")               // нет предложения

// Словарная статья: страница из нескольких статей в стиле системной всплывашки
func entry(_ title: String, _ text: String) -> String {
    "<html class=\"apple_client-application x\"><head><style>body{}</style></head><body><d:entry d:title=\"\(title)\">\(text)</d:entry></body></html>"
}
check(entryTitle(entry("ключ", "1")) ?? "nil", "ключ")
check(bodyInner(entry("ключ", "1")) ?? "nil", "<d:entry d:title=\"ключ\">1</d:entry>")
do {
    let page = panelPage([entry("разложить", "A"), entry("раскладка", "B")], word: "Раскладка", source: "Словарь <ru>", fontPx: 12) ?? ""
    let a = page.range(of: ">A<")!.lowerBound, b = page.range(of: ">B<")!.lowerBound
    check(b < a ? "точное первым" : "порядок не тот", "точное первым")
    check(page.contains("apple_client-panel") && !page.contains("apple_client-application") ? "panel" : "app", "panel")
    check(page.contains("font-size:12px") ? "шрифт" : "нет", "шрифт")
    check(page.contains("Словарь &lt;ru&gt;") ? "подпись" : "нет", "подпись")
    check(page.components(separatedBy: "<body").count - 1 == 1 ? "одно тело" : "несколько", "одно тело")
}
check(panelPage([], word: "x", source: "", fontPx: 12) ?? "nil", "nil")
// Порядок словарей — как в настройках «Словаря» (служба отдаёт их в произвольном порядке)
do {
    let prefs = ["/x/Wikipedia.wikipediadictionary", "com.apple.dictionary.ru.oup", "/u/ITTerms.dictionary", "com.apple.dictionary.ODE"]
    let dicts = [("ODE", "com.apple.dictionary.ODE", "/s/ODE.dictionary"), ("Новый", "x.new", "/s/New.dictionary"),
                 ("IT", "local.it", "/u/ITTerms.dictionary"), ("Толковый", "com.apple.dictionary.ru.oup", "/s/Russian.dictionary")]
    let sorted = sortByPreference(dicts, prefs: prefs) { [$0.1, $0.2] }
    check(sorted.map(\.0).joined(separator: ","), "Толковый,IT,ODE,Новый") // по id или пути; неизвестные — в конце
}
// Живой словарь
check(SystemDictionary.entries("ключ").map { "\($0.html.count >= 2)" } ?? "nil", "true")
check(SystemDictionary.entries("qwzxqwzx") == nil ? "nil" : "есть", "nil")

// Код: внутри ``` … ``` и `…` правку не делаем
func code(_ t: String) -> String { insideCode(t) ? "код" : "текст" }
check(code("смотри ```\nlet x"), "код")
check(code("```\nlet x = 1\n``` и дальше"), "текст")
check(code("это `code"), "код")
check(code("это `code` и"), "текст")
check(code("```a``` и `b"), "код")
check(code("строка `x\nновая строка"), "текст")      // `…` не переходит на новую строку
check(code("```\nкод с `кавычкой` внутри"), "код")   // внутри блока одиночные не важны
check(code(""), "текст")

// Поле с оформлением (Claude, Slack): ``` + пробел открыли блок кода, кавычки из текста поля пропали
func code(field: String?, typed: String) -> String { insideCode(field: field, typed: typed) ? "код" : "текст" }
check(code(field: "how", typed: "``` how"), "код")
check(code(field: "how это\nработает", typed: "``` how это\nработает"), "код")
check(code(field: "Привет! how", typed: "Привет! ``` how"), "код")
check(code(field: "hello", typed: "``` how это\nhello"), "текст")     // сообщение отправлено — поле новое
check(code(field: "", typed: "``` how"), "текст")                     // поле очистили
check(code(field: nil, typed: "``` how"), "код")                      // поле не отдаёт текст — по набранному
check(code(field: "```\nlet x", typed: ""), "код")                    // обычное поле — по тексту поля
check(code(field: "```\nlet x\n``` и", typed: "```\nlet x\n``` и"), "текст")
check(code(field: "привет как", typed: "привет как"), "текст")

// Слово с ` — граница кода: `ghbdtn rfr ltkf` + пробел — последнее слово закрывает код, не трогаем
do {
    let inv = Dictionary(l.chars(.en).map { ($1, $0) }, uniquingKeysWith: min)
    let keys = "ltkf`".map { inv[$0]! }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
    check(wordTouchesCode(text(keys, l.chars(.en))) ? "код" : "текст", "код")
    check(wordTouchesCode("`ghbdtn") ? "код" : "текст", "код")
    check(wordTouchesCode("ghbdtn") ? "код" : "текст", "текст")
    check(wordTouchesCode("ltkf]") ? "код" : "текст", "текст")
}

// Элемент под курсором в веб-поле (снизу вверх до самого поля): блок кода — <code> или класс с «code»
func caret(_ nodes: [(String, String, [String])]) -> String { caretInCode(nodes) ? "код" : "текст" }
check(caret([("AXStaticText", "", []), ("AXGroup", "AXCodeStyleGroup", []), ("AXGroup", "", ["code-block"]),
             ("AXTextArea", "", ["ProseMirror"])]), "код")                      // Chrome: <pre class=code-block><code>
check(caret([("AXStaticText", "", []), ("AXGroup", "", ["ql-code-block"]), ("AXTextArea", "", ["ql-editor"])]), "код")
check(caret([("AXStaticText", "", []), ("AXGroup", "", ["paragraph"]), ("AXTextArea", "", ["ProseMirror"])]), "текст")
check(caret([("AXStaticText", "", []), ("AXTextArea", "", ["codemirror-like", "code-input"])]), "текст") // классы самого поля — не блок внутри
check(caret([]), "текст")

// Редакторы кода в браузере — по классам элементов страницы
check(isCodeEditor(["inputarea", "monaco-mouse-cursor-text"]) ? "да" : "нет", "да")
check(isCodeEditor(["cm-content"]) ? "да" : "нет", "да")
check(isCodeEditor(["ace_text-input"]) ? "да" : "нет", "да")
check(isCodeEditor(["CodeMirror-code"]) ? "да" : "нет", "да")
check(isCodeEditor(["form-control", "comment-body"]) ? "да" : "нет", "нет")

// Приложения для кода по умолчанию выключены, но пользователь может включить
check(isCodeApp("com.jetbrains.pycharm") && isCodeApp("com.apple.Terminal") && isCodeApp("com.microsoft.VSCode") ? "да" : "нет", "да")
check(isCodeApp("com.apple.Safari") ? "да" : "нет", "нет")
check(appExcluded("com.apple.Terminal", excluded: [], allowed: []) ? "выкл" : "вкл", "выкл")
check(appExcluded("com.apple.Terminal", excluded: [], allowed: ["com.apple.Terminal"]) ? "выкл" : "вкл", "вкл")
check(appExcluded("com.apple.Notes", excluded: ["com.apple.Notes"], allowed: []) ? "выкл" : "вкл", "выкл")
check(appExcluded("com.apple.Notes", excluded: [], allowed: []) ? "выкл" : "вкл", "вкл")
// Экран входа и системные окна паролей — всегда без правки, даже если «разрешить»
check(appExcluded("com.apple.loginwindow", excluded: [], allowed: ["com.apple.loginwindow"]) ? "выкл" : "вкл", "выкл")
check(appExcluded("com.apple.SecurityAgent", excluded: [], allowed: []) ? "выкл" : "вкл", "выкл")

// Неверная раскладка + опечатка: «ghbtdn» (привте) → «привет»
func both(_ typed: String, in lang: Lang) -> String {
    let inv = Dictionary(l.chars(lang).map { ($1, $0) }, uniquingKeysWith: min)
    let k = typed.map { inv[$0]! }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
    return layoutTypoFix(keys: k, current: lang, l)?.text ?? "nil"
}
check(both("ghbtdn", in: .en), "привет")
check(both("cgfcb,j", in: .en), "nil")          // «спасибо» без опечатки — это обычная ошибка раскладки, не этот шаг
check(both("руддщщ", in: .ru), "hello")          // hellоо → hello
check(both("hello", in: .en), "nil")             // верное слово
// английский жаргон и команды, которых нет в словаре, — не превращать в русские слова
for w in ["kubectl", "nginx", "chmod", "mkdir", "grafana", "jupyter", "webpack", "regex", "struct", "async", "sudo", "grep"] {
    check(w + " " + both(w, in: .en), w + " nil")
}
for w in ["кринж", "краш", "вайб", "душнила"] {   // русский сленг вне словаря — не в английский
    check(w + " " + both(w, in: .ru), w + " nil")
}

// Слово, набранное частью в одной раскладке, частью в другой: клавиши слова читаем целиком в каждой
do {
    // клавиши слова «want» в раскладке wantLang; первые `split` нажатий — в одной раскладке, остальные — в другой
    func mixed(_ want: String, _ wantLang: Lang, firstIn: Lang, split: Int, context: Lang? = nil) -> String {
        let inv = Dictionary(l.chars(wantLang).map { ($1, $0) }, uniquingKeysWith: min)
        let k = want.map { inv[$0]! }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
        let langs = k.indices.map { $0 < split ? firstIn : firstIn.other }
        return mixedFix(keys: k, langs: langs, l, context: context).map { "\($0.text)|\($0.typed)|\($0.target)" } ?? "nil"
    }
    check(mixed("скажи", .ru, firstIn: .ru, split: 3), "скажи|ска;b|ru")     // «ска» в RU, «жи» уже в EN
    check(mixed("hello", .en, firstIn: .en, split: 3), "hello|helдщ|en")
    check(mixed("привет", .ru, firstIn: .en, split: 2), "привет|ghивет|ru")
    check(mixed("скажи", .ru, firstIn: .ru, split: 5), "nil")               // целиком в одной раскладке — не этот шаг
    check(mixed("qwzx", .en, firstIn: .en, split: 2), "nil")                // мусор в обеих
}
do {
    var t = TypingState()
    _ = t.keyDown(code: 1, key: 4, char: "ы", modified: false, lang: .ru)
    _ = t.keyDown(code: 2, key: 8, char: "d", modified: false, lang: .en)
    check(t.langs.map { $0.map { "\($0)" } ?? "?" }.joined(separator: ","), "ru,en")
    _ = t.keyDown(code: 51, key: 0, char: nil, modified: false, lang: .en)  // Backspace
    check("\(t.keys.count) \(t.langs.count)", "1 1")
}

// Регистр после случайного Caps Lock посреди слова
check(caseFix("правописанИЕ", .ru) ?? "nil", "правописание")
check(caseFix("приВЕТ,", .ru) ?? "nil", "привет,")      // знаки по краям сохраняются
check(caseFix("пРИВЕТ", .ru) ?? "nil", "Привет")        // Caps Lock + ⇧ на первой букве
check(caseFix("hELLO", .en) ?? "nil", "Hello")
check(caseFix("macOS", .en) ?? "nil", "nil")            // настоящее слово со смешанным регистром
check(caseFix("iPhone", .en) ?? "nil", "nil")
check(caseFix("iOS", .en) ?? "nil", "nil")
check(caseFix("mRNA", .en) ?? "nil", "nil")
check(caseFix("ПРИВЕТ", .ru) ?? "nil", "nil")           // всё заглавными — так и задумано
check(caseFix("Привет", .ru) ?? "nil", "nil")
check(caseFix("привет", .ru) ?? "nil", "nil")
check(caseFix("абвгДЕ", .ru) ?? "nil", "nil")           // строчными тоже не слово — не трогаем

// Подсказка: по центру над курсором, у краёв экрана — прижимается внутрь, у верхнего края — под курсор
let screen = CGRect(x: 0, y: 0, width: 1000, height: 800), hs = CGSize(width: 200, height: 30)
func origin(_ x: CGFloat, _ y: CGFloat) -> String {
    let p = hintOrigin(size: hs, anchor: CGRect(x: x, y: y, width: 10, height: 18), screen: screen)
    return "\(Int(p.x)),\(Int(p.y))"
}
check(origin(100, 500), "5,524")     // по центру: середина курсора 105 − половина ширины 100; над словом: 500+18+6
check(origin(100, 780), "5,744")     // у верхнего края — под словом: 780-6-30
check(origin(950, 500), "796,524")   // у правого края: 1000-200-4
check(origin(-50, 2), "4,26")        // за левым краем
// Буфер набора: клавиши слова и недавний текст
do {
    var t = TypingState()
    func k(_ code: Int, _ ch: Character?, mod: Bool = false) -> TypingState.Result {
        t.keyDown(code: code, key: code * 4, char: ch, modified: mod)
    }
    _ = k(0, "a"); _ = k(11, "b")
    check("\(t.keys.count) \(t.recent)", "2 ab")
    _ = k(51, nil)                                   // Backspace
    check("\(t.keys.count) \(t.recent)", "1 a")
    check(k(49, " ") == .wordEnd ? "конец слова" : "нет", "конец слова")
    t.endWord()
    check("\(t.keys.count) [\(t.recent)]", "0 [a ]")
    _ = k(50, "`"); _ = k(36, nil)                   // ` и Enter
    check(t.recent, "a `\n")
    _ = k(8, "c", mod: true)                         // ⌘C — где курсор, неизвестно
    check("\(t.keys.count) [\(t.recent)]", "0 []")
    _ = k(0, "a"); _ = k(123, nil)                   // стрелка
    check("\(t.keys.count) [\(t.recent)]", "0 []")
    _ = k(0, "a"); t.reset()                         // клик
    check("\(t.keys.count) [\(t.recent)]", "0 []")
    for _ in 0..<5000 { _ = k(0, "a") }
    check("\(t.recent.count)", "4000")
}

// Настоящая клавиша символа: «п» — клавиша G (5), «П» — с ⇧, «g» в EN — тоже 5
check(l.key(for: "п", in: .ru).map { "\($0.code) \($0.shift)" } ?? "nil", "5 false")
check(l.key(for: "П", in: .ru).map { "\($0.code) \($0.shift)" } ?? "nil", "5 true")
check(l.key(for: "g", in: .en).map { "\($0.code) \($0.shift)" } ?? "nil", "5 false")
check(l.key(for: "—", in: .en).map { "\($0.code)" } ?? "nil", "nil")

// Язык фразы: запоминается по словам, сбрасывается Enter, кликом, стрелками
do {
    var t = TypingState()
    check(t.phraseLang == nil ? "нет" : "есть", "нет")
    t.endWord(lang: .en)
    check(t.phraseLang.map { "\($0)" } ?? "nil", "en")
    _ = t.keyDown(code: 36, key: 0, char: nil, modified: false)  // Enter
    check(t.phraseLang.map { "\($0)" } ?? "nil", "nil")
    t.endWord(lang: .ru); t.reset()
    check(t.phraseLang.map { "\($0)" } ?? "nil", "nil")
}

// Отмена: первая — только вернуть слово, вторая для того же слова — в исключения
do {
    var u = UndoMemory()
    check(u.undo("рщц") ? "в исключения" : "только вернуть", "только вернуть")
    check(u.undo("рщц") ? "в исключения" : "только вернуть", "в исключения")
    check(u.undo("ghbdtn") ? "в исключения" : "только вернуть", "только вернуть")
}

// Неоднозначное слово в начале фразы исправляется вместе со следующим: «руку цу» → «here we»
do {
    func ks(_ w: String, _ lang: Lang) -> [Int] {
        let inv = Dictionary(l.chars(lang).map { ($1, $0) }, uniquingKeysWith: min)
        return w.map { inv[$0]! }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
    }
    check(isAmbiguous(keys: ks("руку", .ru), current: .ru, l) ? "да" : "нет", "да")
    check(isAmbiguous(keys: ks("привет", .ru), current: .ru, l) ? "да" : "нет", "нет")
    let f = phraseFix(prev: ks("руку", .ru), keys: ks("цу", .ru), current: .ru, l, context: nil)
    check(f.map { "\($0.erase)|\($0.text)|\($0.typed)|\($0.target)" } ?? "nil", "8|here we|руку цу|en")
    let g = phraseFix(prev: nil, keys: ks("цу", .ru), current: .ru, l, context: nil)
    check(g.map { "\($0.erase)|\($0.text)" } ?? "nil", "3|we")                  // без предыдущего — только слово
    let h = phraseFix(prev: ks("руку", .ru), keys: ks("дай", .ru), current: .ru, l, context: nil)
    check(h.map { $0.text } ?? "nil", "nil")                                       // «руку дай» — русская фраза, не трогаем
}
do {
    var t = TypingState()
    t.endWord(lang: .ru, ambiguous: true)
    check(t.ambiguousPrev == nil ? "нет" : "есть", "нет")                          // клавиш не было — нечего помнить
    _ = t.keyDown(code: 0, key: 0, char: "a", modified: false)
    t.endWord(lang: .ru, ambiguous: true)
    check(t.ambiguousPrev?.count.description ?? "nil", "1")
    _ = t.keyDown(code: 51, key: 0, char: nil, modified: false)                   // Backspace в предыдущее слово
    check(t.ambiguousPrev == nil ? "нет" : "есть", "нет")
}

// Fn: переключаем при нажатии (индикатор «РУ/A» у курсора показывает раскладку сразу),
// а если, пока Fn зажата, нажали другую клавишу или модификатор (Fn+стрелка) — откат
do {
    func seq(_ steps: [(Int, UInt64)?]) -> String {
        var f = FnPress(), out: [String] = []
        for s in steps {
            let e = s.map { f.flagsChanged(code: $0.0, flags: $0.1) } ?? f.other()
            if let e { out.append("\(e)") }
        }
        return out.joined(separator: ",")
    }
    check(seq([(63, 0x800100), (63, 0x100)]), "down")                       // просто Fn
    check(seq([(63, 0x800100), nil, (63, 0x100)]), "down,cancel")           // Fn+стрелка
    check(seq([(63, 0x800100), (55, 0x900108), (63, 0x100108)]), "down,cancel") // Fn+⌘
    check(seq([(55, 0x100108), (63, 0x900108), (63, 0x100108)]), "")        // ⌘ уже зажат — не Fn
    check(seq([(63, 0x800100), nil, nil, (63, 0x100)]), "down,cancel")      // откат один раз
}

// Исключение приложения: если хоть один источник говорит «исключено» — не правим; не знаем приложение — не правим
check(anyExcluded([nil, "com.apple.Terminal"], excluded: [], allowed: []) ? "не править" : "править", "не править")
check(anyExcluded(["com.apple.Notes", "com.apple.Terminal"], excluded: [], allowed: []) ? "не править" : "править", "не править")
check(anyExcluded(["com.apple.Notes", nil], excluded: [], allowed: []) ? "не править" : "править", "править")
check(anyExcluded([nil, nil], excluded: [], allowed: []) ? "не править" : "править", "не править")

// Системное сочетание «Выбрать предыдущий источник ввода»: из настроек symbolichotkeys
do {
    let on: [String: Any] = ["enabled": 1, "value": ["parameters": [32, 49, 262144], "type": "standard"]]
    let off: [String: Any] = ["enabled": 0, "value": ["parameters": [32, 49, 262144], "type": "standard"]]
    check(parseHotkey(on).map { "\($0.code) \(String($0.flags, radix: 16))" } ?? "nil", "49 40000")  // ⌃Пробел
    check(parseHotkey(off).map { "\($0.code)" } ?? "nil", "nil")
    check(parseHotkey([:]).map { "\($0.code)" } ?? "nil", "nil")
    check(parseHotkey(["enabled": 1, "value": ["parameters": [65535, 65535, 0]]]).map { "\($0.code)" } ?? "nil", "nil") // не задано
}

// Нажимать ли ⌘C для конвертации/определения выделенного
check(shouldCopySelection(axSelected: "", codeApp: false) ? "да" : "нет", "да")      // Electron/браузер часто врут «ничего»
check(shouldCopySelection(axSelected: nil, codeApp: false) ? "да" : "нет", "да")
check(shouldCopySelection(axSelected: "", codeApp: true) ? "да" : "нет", "нет")      // IDE: ⌘C без выделения копирует строку
check(shouldCopySelection(axSelected: nil, codeApp: true) ? "да" : "нет", "нет")
check(shouldCopySelection(axSelected: "x", codeApp: true) ? "да" : "нет", "да")

// Предыдущее слово: помнится сразу после пробела и забывается при любом следующем действии
do {
    var t = TypingState()
    func k(_ code: Int, _ ch: Character?, lang: Lang = .en) { _ = t.keyDown(code: code, key: code * 4, char: ch, modified: false, lang: lang) }
    k(0, "a"); k(11, "b"); t.endWord()
    check(t.lastWord.map { "\($0.keys.count)" } ?? "nil", "2")
    k(8, "c")                                                  // новая буква — уже не «сразу после пробела»
    check(t.lastWord == nil ? "забыто" : "помнится", "забыто")
    t.endWord(); _ = t.keyDown(code: 36, key: 0, char: nil, modified: false)   // Enter
    check(t.lastWord == nil ? "забыто" : "помнится", "забыто")
    k(0, "a"); t.endWord(); k(51, nil)                         // Backspace — курсор ушёл в слово
    check(t.lastWord == nil ? "забыто" : "помнится", "забыто")
    k(0, "a"); t.endWord(); t.reset()                          // клик, стрелка
    check(t.lastWord == nil ? "забыто" : "помнится", "забыто")
    t.endWord()                                                // пробел без слова (два пробела подряд)
    check(t.lastWord == nil ? "нет слова" : "есть", "нет слова")
}
// Перенабор предыдущего слова: «ghbdtn » → «привет », стереть слово и пробел
do {
    let inv = Dictionary(l.chars(.en).map { ($1, $0) }, uniquingKeysWith: min)
    let keys = "ghbdtn".map { inv[$0]! }.map { encodeKey(code: $0 / 2, shift: $0 % 2 == 1, caps: false) }
    let r = lastWordConversion(keys: keys, langs: Array(repeating: .en, count: keys.count), l)
    check(r.map { "\($0.erase)|\($0.text)|\($0.target)" } ?? "nil", "7|привет|ru")
    check(lastWordConversion(keys: [], langs: [], l).map { $0.text } ?? "nil", "nil")
}

// Пробел перед знаком препинания: «слово ,» → «слово,»
func sp(_ recent: String, _ ch: Character) -> String { spaceBeforePunct(recent: recent, char: ch) ? "придвинуть" : "нет" }
check(sp("слово ", ","), "придвинуть")
check(sp("hello ", "!"), "придвинуть")
check(sp("5 ", "."), "придвинуть")
check(sp("слово ", ")"), "придвинуть")
check(sp("слово ", "»"), "придвинуть")
check(sp("слово ", "—"), "нет")          // перед тире пробел нужен
check(sp("слово ", "("), "нет")          // открывающая скобка
check(sp("слово  ", ","), "нет")         // два пробела — выравнивание
check(sp("слово, ", ":"), "нет")         // перед пробелом знак (смайлик « :)»)
check(sp("слово\n", ","), "нет")
check(sp(" ", ","), "нет")
check(sp("", ","), "нет")
check(sp("слово", ","), "нет")           // пробела нет
do {
    var t = TypingState()
    for (code, ch) in [(0, "a"), (11, "b")] as [(Int, Character)] { _ = t.keyDown(code: code, key: code * 4, char: ch, modified: false) }
    t.endWord()
    _ = t.keyDown(code: 43, key: 43 * 4, char: ",", modified: false)
    check(t.recent, "ab ,")
    t.spaceBeforePunctFixed()
    check(t.recent, "ab,")
    // знак — не слово: клавиша исправления после отмены не должна перенабирать запятую в «^»/«б»
    check("\(t.keys.count)", "0")
}

// Знак через ⌃⌥ + клавишу английской раскладки (⌃⌥Б → «,», ⌃⌥Ю → «.»)
check(modifiedPunct(code: 43, flags: 0xC0000, l.enChars).map { String($0) } ?? "nil", ",")   // ⌃⌥ + клавиша Б
check(modifiedPunct(code: 47, flags: 0xC0000, l.enChars).map { String($0) } ?? "nil", ".")   // ⌃⌥ + клавиша Ю
check(modifiedPunct(code: 0, flags: 0xC0000, l.enChars).map { String($0) } ?? "nil", "nil")  // ⌃⌥A — не знак
check(modifiedPunct(code: 43, flags: 0x1C0000, l.enChars).map { String($0) } ?? "nil", "nil") // с ⌘ — сочетание
check(modifiedPunct(code: 43, flags: 0x40000, l.enChars).map { String($0) } ?? "nil", "nil")  // только ⌃
do {
    var t = TypingState()
    for (code, ch) in [(0, "a"), (11, "b")] as [(Int, Character)] { _ = t.keyDown(code: code, key: code * 4, char: ch, modified: false) }
    t.endWord()
    t.punctTyped(",")
    check("\(t.keys.count) [\(t.recent)]", "0 [ab ,]")      // в слово не попал, недавний текст сохранён
}

// Место запуска: только «Программы» — иначе автозагрузка запомнит временный путь
check(isProperInstallPath("/Applications/Rasklad.app", home: "/Users/u") ? "да" : "нет", "да")
check(isProperInstallPath("/Users/u/Applications/Rasklad.app", home: "/Users/u") ? "да" : "нет", "да")
check(isProperInstallPath("/Volumes/Rasklad/Rasklad.app", home: "/Users/u") ? "да" : "нет", "нет")
check(isProperInstallPath("/private/var/folders/x/T/AppTranslocation/1/d/Rasklad.app", home: "/Users/u") ? "да" : "нет", "нет")
check(isProperInstallPath("/Users/u/Downloads/Rasklad/Rasklad.app", home: "/Users/u") ? "да" : "нет", "нет")

// Словарь: обновлять установленный, если внутри приложения другая версия
check(dictionaryNeedsUpdate(bundled: "2", installed: "1") ? "да" : "нет", "да")
check(dictionaryNeedsUpdate(bundled: "2", installed: "2") ? "да" : "нет", "нет")
check(dictionaryNeedsUpdate(bundled: "2", installed: nil) ? "да" : "нет", "нет")   // не установлен — решает пользователь
check(dictionaryNeedsUpdate(bundled: nil, installed: "1") ? "да" : "нет", "нет")

// Буфер обмена возвращаем, только если в нём всё ещё наше
check(shouldRestoreClipboard(current: 7, ours: 7) ? "да" : "нет", "да")
check(shouldRestoreClipboard(current: 8, ours: 7) ? "да" : "нет", "нет")

// Лог: больше предела — в .old, новый начинается с нуля
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rasklad-log-test-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("t.log")
    try? Data(repeating: 65, count: 20).write(to: f)
    rotateLog(f, limit: 100)
    check(FileManager.default.fileExists(atPath: f.path) ? "на месте" : "нет", "на месте")   // мал — не трогаем
    rotateLog(f, limit: 10)
    check(FileManager.default.fileExists(atPath: f.path) ? "есть" : "в .old", "в .old")
    check(FileManager.default.fileExists(atPath: f.appendingPathExtension("old").path) ? "есть" : "нет", "есть")
    try? FileManager.default.removeItem(at: dir)
}

// «Забыть выученное слово»: только то, что выучено; словарные слова не трогаем
do {
    let temp = "раскладочкатест"                      // временное слово: выучить и забыть
    NSSpellChecker.shared.learnWord(temp)
    check("\(forgetLearnedWord(temp))", "forgotten")
    check(isWord(temp, .ru) ? "слово" : "не слово", "не слово")
    check("\(forgetLearnedWord(temp))", "notLearned")     // второй раз — уже нечего забывать
    check("\(forgetLearnedWord("play"))", "notLearned")    // словарное слово
    check(isWord("play", .en) ? "слово" : "не слово", "слово")
    check("\(forgetLearnedWord("  "))", "empty")
}

// Язык интерфейса: русский, если он раньше английского в предпочитаемых языках; иначе английский
check(prefersRussian(["ru-RU", "en-US"]) ? "ru" : "en", "ru")
check(prefersRussian(["en-US", "ru-RU"]) ? "ru" : "en", "en")
check(prefersRussian(["de-DE", "ru-RU"]) ? "ru" : "en", "ru")      // немецкого нет — следующий в списке
check(prefersRussian(["de-DE", "fr-FR"]) ? "ru" : "en", "en")      // ни одного из двух — английский
check(prefersRussian(["uk-UA", "en-US"]) ? "ru" : "en", "en")
check(prefersRussian([]) ? "ru" : "en", "en")

print("all ok, map size en→ru:", l.enToRu.count)
