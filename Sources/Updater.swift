import AppKit
import Security

/// Обновление с GitHub: раз в сутки спросить о последнем выпуске; по команде скачать DMG, проверить,
/// что приложение внутри подписано тем же сертификатом, что и мы, заменить себя и перезапуститься.
/// Подпись та же — права «Универсальный доступ» и «Мониторинг ввода» сохраняются; скачанное
/// URLSession не получает пометку карантина, поэтому Gatekeeper не мешает.

struct Release {
    let version: String
    let dmg: URL
    let page: URL?
}

/// "1.10.0" новее "1.9.9": сравниваем числа; недостающие части — нули; не версия — не новее.
func isNewerVersion(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int]? {
        let p = s.split(separator: ".")
        let n = p.compactMap { Int($0) }
        return n.isEmpty || n.count != p.count ? nil : n
    }
    guard let x = parts(a), let y = parts(b) else { return false }
    for i in 0..<max(x.count, y.count) {
        let u = i < x.count ? x[i] : 0, v = i < y.count ? y[i] : 0
        if u != v { return u > v }
    }
    return false
}

private let releaseDownloads = "/DK-custom/Rasklad-MacOS/releases/download/"

/// Ответ api.github.com/…/releases/latest. DMG — только https://github.com/ из нашего репозитория.
func parseLatestRelease(_ data: Data) -> Release? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let tag = o["tag_name"] as? String, let assets = o["assets"] as? [[String: Any]],
          let link = assets.first(where: { $0["name"] as? String == "Rasklad.dmg" })?["browser_download_url"] as? String,
          let dmg = URL(string: link), dmg.scheme == "https", dmg.host == "github.com",
          dmg.path.hasPrefix(releaseDownloads) else { return nil }
    return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, dmg: dmg,
                   page: (o["html_url"] as? String).flatMap(URL.init(string:)))
}

final class Updater {
    enum CheckResult { case available(Release), upToDate, failed }

    private static let api = URL(string: "https://api.github.com/repos/DK-custom/Rasklad-MacOS/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/DK-custom/Rasklad-MacOS/releases/latest")!

    private(set) var available: Release?
    private(set) var busy = false
    var onChange: (() -> Void)?

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateCheck") }
    }

    private var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// При запуске и затем раз в час: проверить, если с прошлой проверки прошли сутки.
    func schedule() {
        let tick = { [weak self] in
            guard let self, self.autoCheck else { return }
            let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 24 * 3600 { self.check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: tick)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in tick() }
    }

    func check(done: ((CheckResult) -> Void)? = nil) {
        var req = URLRequest(url: Self.api, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let latest = data.flatMap(parseLatestRelease)
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                guard let latest else {
                    dlog("обновления: проверить не удалось (\(error?.localizedDescription ?? "ответ GitHub не разобран"))")
                    done?(.failed)
                    return
                }
                self.available = isNewerVersion(latest.version, than: self.current) ? latest : nil
                if let a = self.available { dlog("обновления: доступна \(a.version)") }
                self.onChange?()
                done?(self.available.map(CheckResult.available) ?? .upToDate)
            }
        }.resume()
    }

    /// Скачать и установить; при ошибке — сообщение (на главном потоке), при успехе — перезапуск.
    func install(_ r: Release, failed: @escaping (String) -> Void) {
        guard !busy else { return }
        busy = true
        onChange?()
        dlog("обновление: скачиваю \(r.version)")
        URLSession.shared.downloadTask(with: r.dmg) { file, response, error in
            var message: String?
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                message = self.installDMG(file, expected: r.version)
            } else {
                message = tr("Не удалось скачать: ", "Download failed: ") + (error?.localizedDescription ?? "HTTP")
            }
            DispatchQueue.main.async {
                self.busy = false
                self.onChange?()
                if let message { dlog("обновление не установлено: \(message)"); failed(message) } else { self.relaunch() }
            }
        }.resume()
    }

    /// Смонтировать, проверить подпись и версию, заменить себя. nil — готово, иначе текст ошибки.
    /// Вызывается и из отладочного `--install-update` с локальным DMG.
    func installDMG(_ dmg: URL, expected: String) -> String? {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: Bundle.main.bundlePath)
        guard isProperInstallPath(dest.path, home: NSHomeDirectory()) else {
            return tr("Rasklad запущен не из «Программ» — установите обновление вручную.",
                      "Rasklad isn’t running from Applications — install the update manually.")
        }
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            return tr("Нет прав на запись в «Программы».", "No write access to Applications.")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("rasklad-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? fm.removeItem(at: work)
        }
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            return tr("Не удалось открыть образ диска.", "Couldn’t open the disk image.")
        }
        let app = mount.appendingPathComponent("Rasklad.app")
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expected else {
            return tr("В образе не та версия (\(version ?? "?")).", "Wrong version in the disk image (\(version ?? "?")).")
        }
        guard signedLikeUs(app) else {
            return tr("Подпись приложения в образе не совпадает с текущей — установка отменена.",
                      "The app in the disk image isn’t signed like this one — update cancelled.")
        }
        // копия рядом с собой, затем атомарная замена: при сбое старая версия остаётся на месте
        let staged = dest.deletingLastPathComponent().appendingPathComponent(".Rasklad-update.app")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else {
            return tr("Не удалось скопировать новую версию.", "Couldn’t copy the new version.")
        }
        do {
            _ = try fm.replaceItemAt(dest, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            return tr("Не удалось заменить приложение: ", "Couldn’t replace the app: ") + error.localizedDescription
        }
        dlog("обновление: установлена \(expected)")
        return nil
    }

    /// Новая версия подписана тем же сертификатом: проверяем её по нашему же требованию к подписи
    /// (designated requirement), во всех архитектурах и вложенном коде.
    private func signedLikeUs(_ app: URL) -> Bool {
        var me: SecCode?, req: SecRequirement?, code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(me as! SecStaticCode, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// Запустить новую копию после выхода этой (иначе open лишь активирует уходящую).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
