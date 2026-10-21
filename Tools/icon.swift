// Иконка приложения: «Aa» на цветном скруглённом квадрате.
// swift Tools/icon.swift <папка.iconset>  →  iconutil -c icns <папка.iconset>
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024 // сетка иконок macOS: холст 1024, плашка 824, радиус ~185

    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.62, green: 0.25, blue: 0.93, alpha: 1))!
        .draw(in: path, angle: -60)

    var font = NSFont.systemFont(ofSize: 460 * s, weight: .bold)
    if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: 460 * s) ?? font }
    let text = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = text.size()
    text.draw(at: NSPoint(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2 + 8 * s))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
