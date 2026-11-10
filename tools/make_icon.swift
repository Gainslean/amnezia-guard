// Рисует иконку приложения 1024×1024: щит с замком на зелёно-бирюзовом фоне.
// swift tools/make_icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// подложка в стиле macOS: скруглённый квадрат 824 с отступом 100
let card = NSRect(x: 100, y: 100, width: 824, height: 824)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
let path = NSBezierPath(roundedRect: card, xRadius: 185, yRadius: 185)
NSColor(red: 0.04, green: 0.20, blue: 0.22, alpha: 1).setFill()
path.fill()
NSShadow().set()
NSGradient(colors: [
    NSColor(red: 0.05, green: 0.55, blue: 0.45, alpha: 1),
    NSColor(red: 0.02, green: 0.22, blue: 0.30, alpha: 1),
])!.draw(in: path, angle: -90)

// мягкое свечение за щитом
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSBezierPath(ovalIn: card.insetBy(dx: 120, dy: 120)), relativeCenterPosition: .zero)

// щит
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.03, green: 0.36, blue: 0.36, alpha: 1), .white]))
if let sym = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let sz = sym.size
    let scale = min(560 / sz.width, 560 / sz.height)
    let w = sz.width * scale, h = sz.height * scale
    sym.draw(in: NSRect(x: (S - w) / 2, y: (S - h) / 2 - 6, width: w, height: h))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("icon -> \(out)")
