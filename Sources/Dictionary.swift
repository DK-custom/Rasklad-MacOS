import Foundation

/// Статьи из системных словарей — те же HTML, что показывают «Словарь» и всплывашка «Найти».
/// Публичный API (DCSCopyTextDefinition) отдаёт только плоский текст, поэтому берём частные функции
/// DictionaryServices через dlsym; если их нет (сменились в новой macOS) — nil, и показываем плоский текст.
enum SystemDictionary {
    private typealias Records = @convention(c) (UnsafeRawPointer, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private typealias RecordData = @convention(c) (UnsafeRawPointer, Int) -> Unmanaged<CFString>?
    private typealias DictName = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias Active = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DictURL = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFURL>?

    private static let api: (records: Records, data: RecordData, name: DictName, active: Active,
                             ident: DictName, url: DictURL)? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let h = dlopen(path, RTLD_NOW),
              let r = dlsym(h, "DCSCopyRecordsForSearchString"), let d = dlsym(h, "DCSRecordCopyData"),
              let n = dlsym(h, "DCSDictionaryGetName"), let a = dlsym(h, "DCSGetActiveDictionaries"),
              let i = dlsym(h, "DCSDictionaryGetIdentifier"), let u = dlsym(h, "DCSDictionaryGetURL") else { return nil }
        return (unsafeBitCast(r, to: Records.self), unsafeBitCast(d, to: RecordData.self),
                unsafeBitCast(n, to: DictName.self), unsafeBitCast(a, to: Active.self),
                unsafeBitCast(i, to: DictName.self), unsafeBitCast(u, to: DictURL.self))
    }()

    /// Первый активный словарь (порядок — как в настройках «Словаря»), где нашлось слово: имя и до 3 HTML-статей.
    static func entries(_ word: String) -> (dictionary: String, html: [String])? {
        guard let api, let active = api.active()?.takeUnretainedValue() as [AnyObject]? else { return nil }
        // служба отдаёт активные словари в произвольном порядке — сортируем по списку из настроек «Словаря»
        CFPreferencesAppSynchronize("com.apple.DictionaryServices" as CFString)
        let prefs = CFPreferencesCopyAppValue("DCSActiveDictionaries" as CFString,
                                              "com.apple.DictionaryServices" as CFString) as? [String] ?? []
        let dicts = sortByPreference(active.map { Unmanaged.passUnretained($0).toOpaque() }, prefs: prefs) { p in
            [api.ident(p)?.takeUnretainedValue() as String?, (api.url(p)?.takeUnretainedValue() as URL?)?.path].compactMap { $0 }
        }
        for dp in dicts {
            guard let recs = api.records(dp, word as CFString, nil, nil)?.takeRetainedValue() as [AnyObject]?,
                  !recs.isEmpty else { continue }
            let html = recs.prefix(3).compactMap { r in
                api.data(Unmanaged.passUnretained(r).toOpaque(), 1)?.takeRetainedValue() as String? // 1 — HTML
            }
            if !html.isEmpty { return (api.name(dp)?.takeUnretainedValue() as String? ?? "", html) }
        }
        return nil
    }
}

/// Порядок по списку настроек «Словаря»: в нём словарь записан идентификатором или путём; неизвестные — в конце.
func sortByPreference<T>(_ items: [T], prefs: [String], keys: (T) -> [String]) -> [T] {
    func rank(_ t: T) -> Int { keys(t).compactMap { prefs.firstIndex(of: $0) }.min() ?? Int.max }
    return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

/// Заголовок статьи (d:title) — по нему ставим первой статью именно этого слова, а не ссылочную.
func entryTitle(_ html: String) -> String? {
    guard let a = html.range(of: "d:title=\""), let b = html[a.upperBound...].firstIndex(of: "\"") else { return nil }
    return String(html[a.upperBound..<b])
}

func bodyInner(_ html: String) -> String? {
    guard let open = html.range(of: "<body"), let gt = html[open.upperBound...].firstIndex(of: ">"),
          let close = html.range(of: "</body>", options: .backwards) else { return nil }
    return String(html[html.index(after: gt)..<close.lowerBound])
}

/// Одна страница из статей: стили и разметка первой, тела всех; вид панели «Найти» вместо приложения;
/// мелкий шрифт; внизу — название словаря.
func panelPage(_ entries: [String], word: String, source: String, fontPx: Int) -> String? {
    let w = word.lowercased()
    let sorted = entries.enumerated().sorted { a, b in
        let ea = entryTitle(a.element)?.lowercased() == w, eb = entryTitle(b.element)?.lowercased() == w
        return ea != eb ? ea : a.offset < b.offset
    }.map(\.element)
    guard let base = sorted.first, let baseBody = bodyInner(base) else { return nil }
    let bodies = sorted.compactMap(bodyInner).joined(separator: "<hr class=\"rasklad-sep\"/>")
    let esc = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let style = """
        <style>:root{color-scheme:light dark}html,body{background:transparent !important}\
        body{font-size:\(fontPx)px !important;margin:0 !important;padding:8px 12px 6px !important}\
        .rasklad-sep{border:0;border-top:0.5px solid rgba(128,128,128,.35);margin:8px 0}\
        .rasklad-src{margin-top:8px;padding-top:5px;border-top:0.5px solid rgba(128,128,128,.35);\
        font:10px -apple-system;color:gray}</style>
        """
    var page = base.replacingOccurrences(of: "apple_client-application", with: "apple_client-panel")
    guard let bodyRange = page.range(of: baseBody) else { return nil }
    page.replaceSubrange(bodyRange, with: bodies + "<div class=\"rasklad-src\">\(esc)</div>")
    if let head = page.range(of: "</head>") { page.insert(contentsOf: style, at: head.lowerBound) }
    return page
}

/// Словарь «IT-термины», вложенный в Rasklad.app: установка в ~/Library/Dictionaries
/// (папка словарей в контейнере «Словаря» — ссылка на неё). Включает его пользователь в «Словаре».
enum ITDictionary {
    static let file = "ITTerms.dictionary"
    static var bundled: URL? { Bundle.main.url(forResource: "ITTerms", withExtension: "dictionary") }
    static let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries")
    static var installed: Bool { FileManager.default.fileExists(atPath: userDir.appendingPathComponent(file).path) }

    private static func version(_ dict: URL?) -> String? {
        dict.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }?
            .object(forKey: "CFBundleShortVersionString") as? String
    }

    static var bundledVersion: String? { version(bundled) }
    static var installedVersion: String? { version(installed ? userDir.appendingPathComponent(file) : nil) }

    /// При запуске: установленный словарь старше вложенного — обновить (не установлен — решает пользователь).
    static func updateIfNeeded() {
        guard dictionaryNeedsUpdate(bundled: bundledVersion, installed: installedVersion) else { return }
        do {
            try install()
            dlog("словарь IT-термины обновлён до \(bundledVersion ?? "?")")
        } catch { dlog("словарь IT-термины: обновить не удалось — \(error.localizedDescription)") }
    }

    /// Включён в настройках «Словаря» (там он записан путём к копии).
    static var active: Bool {
        CFPreferencesAppSynchronize("com.apple.DictionaryServices" as CFString)
        let prefs = CFPreferencesCopyAppValue("DCSActiveDictionaries" as CFString,
                                              "com.apple.DictionaryServices" as CFString) as? [String] ?? []
        return prefs.contains { $0.hasSuffix("/" + file) || $0 == "local.rasklad.dictionary.itterms" }
    }

    static func install() throws {
        guard let src = bundled else { throw CocoaError(.fileNoSuchFile) }
        let dest = userDir.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: src, to: dest)
    }
}
