import AppKit
import WebKit

/// Подсказка у курсора ввода: неактивирующее окно без рамки, фокус остаётся в поле.
final class Hint: NSObject, WKNavigationDelegate {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    /// Висит до следующей клавиши или клика (определение), а не по таймеру.
    private(set) var sticky = false

    /// Для проверки вёрстки: вызывается, когда словарная страница показана.
    var onPageShown: ((WKWebView) -> Void)?
    private var web: WKWebView?
    private var pending: (anchor: CGRect?, width: CGFloat, maxHeight: CGFloat)?

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        panel.contentView = bg
        super.init()
    }

    /// anchor — прямоугольник слова (Cocoa); nil — у указателя мыши. hideAfter nil — sticky.
    func show(_ text: String, at anchor: CGRect?, width: CGFloat, maxHeight: CGFloat, hideAfter: TimeInterval?,
              fontSize: CGFloat = 11) {
        let inset = NSSize(width: 8, height: 4)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        tv.string = text
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize, weight: .light)
        tv.textContainerInset = inset
        tv.textContainer?.lineFragmentPadding = 0
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
        let textH = ceil(used.height) + inset.height * 2
        let size = CGSize(width: min(width, ceil(used.width) + inset.width * 2 + 1), height: min(maxHeight, textH))
        tv.frame.size = NSSize(width: size.width, height: textH)

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = textH > maxHeight
        scroll.documentView = tv
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(scroll)

        place(size, anchor)
        hideWork?.cancel()
        sticky = hideAfter == nil
        if let t = hideAfter {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    private func place(_ size: CGSize, _ anchor: CGRect?) {
        let a = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 16))
        let screen = NSScreen.screens.first { $0.frame.intersects(a) } ?? NSScreen.main
        panel.setFrame(NSRect(origin: hintOrigin(size: size, anchor: a, screen: screen?.visibleFrame ?? .zero), size: size),
                       display: true)
        panel.orderFrontRegardless()
    }

    /// Словарная статья (HTML) — как во всплывашке «Найти»; висит до клавиши или клика мимо.
    /// Показываем после загрузки, когда известна высота, чтобы окно не прыгало.
    func showPage(_ html: String, at anchor: CGRect?, width: CGFloat, maxHeight: CGFloat) {
        hideWork?.cancel()
        // высота 1: иначе scrollHeight не меньше высоты окна и короткая статья растягивается до maxHeight
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        w.setValue(false, forKey: "drawsBackground") // фон — материал панели, как у системной всплывашки
        w.appearance = NSApp.appearance ?? NSApp.effectiveAppearance     // светлая/тёмная тема статьи (prefers-color-scheme)
        w.navigationDelegate = self
        web = w
        pending = (anchor, width, maxHeight)
        w.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        guard w === web, let p = pending else { return }
        pending = nil
        w.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] h, _ in
            guard let self, w === self.web else { return }
            let size = CGSize(width: p.width, height: min(p.maxHeight, max(40, (h as? CGFloat) ?? p.maxHeight)))
            w.frame = NSRect(origin: .zero, size: size)
            self.panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
            self.panel.contentView?.addSubview(w)
            self.place(size, p.anchor)
            self.sticky = true
            self.onPageShown?(w)
        }
    }

    /// Ссылки внутри статьи не открываем: подсказка — не браузер.
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
    }

    func hide() {
        web = nil
        pending = nil
        hideWork?.cancel()
        panel.orderOut(nil)
        sticky = false
    }

    func contains(_ p: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(p) }
}

/// Над словом; у верхнего края — под ним; по горизонтали прижать внутрь экрана.
func hintOrigin(size: CGSize, anchor: CGRect, screen: CGRect) -> CGPoint {
    let gap: CGFloat = 6, margin: CGFloat = 4
    let x = min(max(anchor.minX, screen.minX + margin), screen.maxX - size.width - margin)
    var y = anchor.maxY + gap
    if y + size.height > screen.maxY - margin { y = anchor.minY - gap - size.height }
    return CGPoint(x: x, y: max(y, screen.minY + margin))
}

/// Где показать подсказку. По порядку: у курсора; над полем ввода; у нижнего края окна приложения
/// (там обычно поле ввода чата); nil — у мыши. Electron (этот чат, Slack) не сообщает системе фокус и курсор,
/// пока у приложения не включён доступ (AXManualAccessibility), — включаем и спрашиваем у самого приложения.
/// kind — для журнала: где оказалась подсказка или почему у мыши.
func inputAnchor() -> (rect: CGRect?, kind: String) {
    guard let pid = inputApp()?.processIdentifier else { return (nil, "у мыши (приложение не определено)") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    _ = enableAppAccessibility(app, pid)   // дерево строится не сразу: с первой подсказки — у окна, дальше у курсора
    let el = focusedElement(of: app)
    if let el {
        if let r = caretBounds(el) { return (r, "у курсора") }
        if let r = caretBoundsByMarker(el) { return (r, "у курсора (маркер)") }
        if let f = elementFrame(el) { return (CGRect(x: f.minX + 8, y: f.maxY - 20, width: 2, height: 20), "у поля") }
    }
    if let w = focusedWindowFrame(of: app) {   // нижний край окна, отступ как у поля ввода
        return (CGRect(x: w.minX + 24, y: w.minY + 24, width: 2, height: 20), el == nil ? "у окна (нет фокуса)" : "у окна")
    }
    return (nil, el == nil ? "у мыши (нет фокуса)" : "у мыши (нет рамки поля)")
}

private func focusedElement(of app: AXUIElement) -> AXUIElement? {
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success,
          let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    let el = v as! AXUIElement
    AXUIElementSetMessagingTimeout(el, 0.2)
    return el
}

private func focusedWindowFrame(of app: AXUIElement) -> CGRect? {
    var w: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success,
          let v = w, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return elementFrame(v as! AXUIElement)
}

func caretRect() -> CGRect? { inputAnchor().rect }

private let axTop = { NSScreen.screens.first?.frame.maxY ?? 0 } // AX: начало координат слева сверху основного экрана

/// Прямоугольник символа перед курсором (или выделения).
private func caretBounds(_ el: AXUIElement) -> CGRect? {
    var rangeRef: CFTypeRef?
    var range = CFRange()
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID(),
          AXValueGetValue(rr as! AXValue, .cfRange, &range) else { return nil }
    if range.length == 0 && range.location > 0 { range = CFRange(location: range.location - 1, length: 1) }
    var boundsRef: CFTypeRef?
    var r = CGRect.zero
    guard let rv = AXValueCreate(.cfRange, &range),
          AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &boundsRef) == .success,
          let br = boundsRef, CFGetTypeID(br) == AXValueGetTypeID(),
          AXValueGetValue(br as! AXValue, .cgRect, &r),
          r.height > 0, r.origin != .zero else { return nil }
    return CGRect(x: r.minX, y: axTop() - r.maxY, width: r.width, height: r.height)
}

/// Курсор через текстовые маркеры: так его отдают Chromium/Electron и Safari, когда номер символа
/// (kAXSelectedTextRange) не работает — например, в редактируемых полях веб-страниц.
private func caretBoundsByMarker(_ el: AXUIElement) -> CGRect? {
    var marker: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
          let m = marker else { return nil }
    var boundsRef: CFTypeRef?
    var r = CGRect.zero
    guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, m, &boundsRef) == .success,
          let br = boundsRef, CFGetTypeID(br) == AXValueGetTypeID(),
          AXValueGetValue(br as! AXValue, .cgRect, &r),
          r.height > 0, r.origin != .zero else { return nil }
    return CGRect(x: r.minX, y: axTop() - r.maxY, width: max(r.width, 1), height: r.height)
}

/// Рамка поля ввода.
private func elementFrame(_ el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, sz: CFTypeRef?
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sz) == .success,
          let pv = p, let sv = sz, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID(),
          AXValueGetValue(pv as! AXValue, .cgPoint, &origin), AXValueGetValue(sv as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0, origin != .zero else { return nil }
    return CGRect(x: origin.x, y: axTop() - origin.y - size.height, width: size.width, height: size.height)
}

/// Electron-приложения строят дерево Accessibility только по просьбе (AXManualAccessibility).
/// true — включили сейчас (раз на процесс).
private var accessibilityEnabledPIDs: Set<pid_t> = []

private func enableAppAccessibility(_ app: AXUIElement, _ pid: pid_t) -> Bool {
    guard !accessibilityEnabledPIDs.contains(pid) else { return false }
    accessibilityEnabledPIDs.insert(pid)
    return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
}

/// Фокусное поле через Accessibility: текст перед курсором (до 4000 символов; nil — приложение не отдаёт)
/// и классы элемента веб-страницы с предками (Chrome/Safari отдают AXDOMClassList).
func focusedFieldContext() -> (before: String?, classes: [String]) {
    guard let el = axFocusedElement() else { return (nil, []) }
    // проверка идёт на каждом пробеле из обработчика нажатий — общий предел времени на обход предков
    let deadline = Date().addingTimeInterval(0.15)
    var classes: [String] = []
    var node: AXUIElement? = el
    for _ in 0..<6 {
        guard let n = node, Date() < deadline else { break }
        AXUIElementSetMessagingTimeout(n, 0.05)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(n, "AXDOMClassList" as CFString, &v) == .success, let list = v as? [String] {
            classes += list
        }
        var p: CFTypeRef?
        node = AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &p) == .success
            && p.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true ? (p as! AXUIElement) : nil
    }

    var rangeRef: CFTypeRef?
    var range = CFRange()
    guard Date() < deadline,
          AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID(),
          AXValueGetValue(rr as! AXValue, .cfRange, &range) else { return (nil, classes) }
    let start = max(0, range.location - 4000)
    var want = CFRange(location: start, length: range.location - start)
    var str: CFTypeRef?
    if let rv = AXValueCreate(.cfRange, &want),
       AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &str) == .success,
       let s = str as? String {
        return (s, classes)
    }
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success, let s = value as? NSString {
        let end = min(range.location, s.length), from = max(0, end - 4000)
        return (s.substring(with: NSRange(location: from, length: end - from)), classes)
    }
    return (nil, classes)
}

/// Фокусное поле ввода через Accessibility (с коротким таймаутом).
func axFocusedElement() -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.1)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
    let el = f as! AXUIElement
    AXUIElementSetMessagingTimeout(el, 0.1) // таймаут не наследуется от системного элемента
    return el
}

/// Выделенный текст: "" — точно ничего не выделено; nil — приложение не сообщает.
func axSelectedText(_ el: AXUIElement?) -> String? {
    guard let el else { return nil }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}

/// Заменить выделение напрямую, без буфера обмена; false — поле так не умеет.
func axReplaceSelection(_ el: AXUIElement?, with s: String) -> Bool {
    guard let el else { return false }
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
          settable.boolValue else { return false }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
}

/// Приложение, в которое сейчас идёт ввод. NSWorkspace.frontmostApplication после блокировки экрана
/// может так и остаться «loginwindow», поэтому берём владельца фокусного элемента через Accessibility.
/// Проверка идёт на каждом нажатии — кешируем на 0,3 с.
func inputApp(fresh: Bool = false) -> NSRunningApplication? {
    let now = Date()
    if !fresh, now.timeIntervalSince(frontCache.at) < 0.3 { return frontCache.app }
    var app = NSWorkspace.shared.frontmostApplication
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.1)
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
       let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() {
        var pid: pid_t = 0
        if AXUIElementGetPid(r as! AXUIElement, &pid) == .success, let a = NSRunningApplication(processIdentifier: pid) {
            app = a
        }
    }
    frontCache = (now, app)
    return app
}

private var frontCache: (at: Date, app: NSRunningApplication?) = (.distantPast, nil)

func frontAppID() -> String? { inputApp()?.bundleIdentifier }
