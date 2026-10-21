import Foundation

/// Настройки: исключения слов — текстовый файл (правится руками),
/// приложения-исключения и раскладка по приложениям — UserDefaults.
final class Settings {
    private let d = UserDefaults.standard

    var excludedApps: Set<String> {
        get { Set(d.stringArray(forKey: "excludedApps") ?? []) }
        set { d.set(newValue.sorted(), forKey: "excludedApps") }
    }

    /// Приложения для кода, где пользователь сам включил правку (по умолчанию они выключены).
    var allowedApps: Set<String> {
        get { Set(d.stringArray(forKey: "allowedApps") ?? []) }
        set { d.set(newValue.sorted(), forKey: "allowedApps") }
    }

    func isExcluded(_ id: String) -> Bool { appExcluded(id, excluded: excludedApps, allowed: allowedApps) }

    func setExcluded(_ id: String, _ off: Bool) {
        if off { excludedApps.insert(id); allowedApps.remove(id) } else { excludedApps.remove(id); allowedApps.insert(id) }
    }

    /// Не править код: блоки ``` и `…`, редакторы кода в браузере.
    var protectCode: Bool {
        get { d.object(forKey: "protectCode") as? Bool ?? true }
        set { d.set(newValue, forKey: "protectCode") }
    }

    var autoSwitch: Bool {
        get { d.object(forKey: "autoSwitch") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoSwitch") }
    }

    var typos: Bool {
        get { d.object(forKey: "typos") as? Bool ?? true }
        set { d.set(newValue, forKey: "typos") }
    }

    var fnSwitch: Bool {
        get { d.object(forKey: "fnSwitch") as? Bool ?? true }
        set { d.set(newValue, forKey: "fnSwitch") }
    }

    var correctionKey: CorrectionKey {
        get { d.string(forKey: "correctionKey").flatMap(CorrectionKey.init) ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "correctionKey") }
    }

    /// bundle id -> "en" / "ru"
    var appLayouts: [String: String] {
        get { d.dictionary(forKey: "appLayouts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appLayouts") }
    }

    let wordsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rasklad/exceptions.txt")

    /// Читается на каждом слове: файл маленький, правки подхватываются сразу.
    func exceptionWords() -> Set<String> {
        parseExceptions((try? String(contentsOf: wordsURL, encoding: .utf8)) ?? "")
    }

    func addException(_ word: String) {
        ensureWordsFile()
        let line = Data((exceptionKey(word) + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: wordsURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    }

    func ensureWordsFile() {
        guard !FileManager.default.fileExists(atPath: wordsURL.path) else { return }
        try? FileManager.default.createDirectory(at: wordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("# Слова, которые Rasklad не переключает: по одному в строке, в любой раскладке.\n".utf8).write(to: wordsURL)
    }
}

func exceptionKey(_ word: String) -> String {
    word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
}

func parseExceptions(_ text: String) -> Set<String> {
    Set(text.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .map { exceptionKey(String($0)) }.filter { !$0.isEmpty })
}

func isException(typed: String, other: String, _ words: Set<String>) -> Bool {
    words.contains(exceptionKey(typed)) || words.contains(exceptionKey(other))
}

/// Системное действие клавиши 🌐/Fn: 0 — ничего, 1 — смена источника ввода, 2 — эмодзи, 3 — диктовка.
func systemFnUsage() -> Int {
    CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
    return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int ?? 1
}

/// «Caps Lock переключает на ABC и обратно» (Клавиатура → Источники ввода). nil — не задано, неизвестно.
func systemCapsSwitch() -> Bool? {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return (CFPreferencesCopyAppValue("TISRomanSwitchState" as CFString, kCFPreferencesAnyApplication) as? Int).map { $0 != 0 }
}

/// IDE, редакторы и терминалы: правка в них по умолчанию выключена.
let codeAppIDs: Set<String> = [
    "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
    "com.exafunction.windsurf", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit",
    "com.google.android.studio", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
]

func isCodeApp(_ id: String) -> Bool { codeAppIDs.contains(id) || id.hasPrefix("com.jetbrains.") }

/// Экран входа/блокировки и системные окна запроса пароля: здесь Rasklad не трогает ничего и никогда.
let secureAppIDs: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine"]

func appExcluded(_ id: String, excluded: Set<String>, allowed: Set<String>) -> Bool {
    secureAppIDs.contains(id) || excluded.contains(id) || (isCodeApp(id) && !allowed.contains(id))
}

/// Только из «Программ»: из образа диска или перемещённой системой копии (App Translocation)
/// автозагрузка запомнит временный путь.
func isProperInstallPath(_ path: String, home: String) -> Bool {
    if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
    return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
}

func dictionaryNeedsUpdate(bundled: String?, installed: String?) -> Bool {
    guard let bundled, let installed else { return false }
    return bundled != installed
}

/// Пользователь мог сам что-то скопировать, пока шла вставка, — тогда его буфер не трогаем.
func shouldRestoreClipboard(current: Int, ours: Int) -> Bool { current == ours }

/// Лог в ~/Library/Logs/Rasklad.log. Слова пишутся только при `defaults write local.rasklad debug -bool true`.
let debugWords = UserDefaults.standard.bool(forKey: "debug")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rasklad.log")

func dlog(_ s: String) {
    rotateLog(logURL, limit: 1_000_000)
    let line = Data("\(Date()) \(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: logURL) }
}

/// Больше `limit` байт — переименовать в .old (прежний .old удаляется): лог не растёт бесконечно.
func rotateLog(_ url: URL, limit: Int) {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else { return }
    let old = url.appendingPathExtension("old")
    try? fm.removeItem(at: old)
    try? fm.moveItem(at: url, to: old)
}
