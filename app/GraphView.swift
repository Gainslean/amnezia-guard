import AppKit

/// График скорости через туннель за последние 90 секунд (внутри меню).
final class GraphView: NSView {
    var down: [Double] = [] { didSet { needsDisplay = true } }
    var up: [Double] = [] { didSet { needsDisplay = true } }
    var accent: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var caption = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 14, dy: 6)
        let bg = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        bg.fill()

        let plot = box.insetBy(dx: 8, dy: 8).offsetBy(dx: 0, dy: -4)
        let peak = max((down + up).max() ?? 0, 16 * 1024)

        // сетка
        NSColor.separatorColor.setStroke()
        for f in [0.5, 1.0] {
            let y = plot.minY + plot.height * f
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.lineWidth = 0.5
            p.setLineDash([2, 3], count: 2, phase: 0)
            p.stroke()
        }

        drawSeries(down, in: plot, peak: peak, color: accent, fill: true)
        drawSeries(up, in: plot, peak: peak, color: .systemBlue, fill: false)

        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSAttributedString(string: formatSpeed(peak), attributes: small)
            .draw(at: NSPoint(x: plot.minX + 2, y: plot.maxY - 10))
        NSAttributedString(string: "90 с", attributes: small)
            .draw(at: NSPoint(x: plot.maxX - 22, y: box.minY + 2))

        if !caption.isEmpty {
            let big: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: caption, attributes: big)
            let sz = s.size()
            s.draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2))
        }
    }

    private func drawSeries(_ data: [Double], in r: NSRect, peak: Double, color: NSColor, fill: Bool) {
        guard data.count > 1 else { return }
        let n = SpeedTracker.historyLength
        let step = r.width / CGFloat(n - 1)
        let x0 = r.maxX - step * CGFloat(data.count - 1)
        let path = NSBezierPath()
        for (i, v) in data.enumerated() {
            let pt = NSPoint(x: x0 + step * CGFloat(i), y: r.minY + r.height * CGFloat(min(v / peak, 1)))
            i == 0 ? path.move(to: pt) : path.line(to: pt)
        }
        if fill {
            let area = path.copy() as! NSBezierPath
            area.line(to: NSPoint(x: r.maxX, y: r.minY))
            area.line(to: NSPoint(x: x0, y: r.minY))
            area.close()
            color.withAlphaComponent(0.22).setFill()
            area.fill()
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}

/// Значок щита для строки меню и уведомлений.
func shieldImage(for h: Health, size: CGFloat = 15) -> NSImage? {
    let (name, color): (String, NSColor) = {
        switch h {
        case .ok: return ("lock.shield.fill", .systemGreen)
        case .vpnDown: return ("shield.lefthalf.filled.slash", .systemOrange)
        case .unprotected: return ("exclamationmark.shield.fill", .systemRed)
        case .noService: return ("xmark.shield.fill", .systemRed)
        }
    }()
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "AmneziaGuard")
        ?? NSImage(systemSymbolName: "shield.fill", accessibilityDescription: nil)
    let out = img?.withSymbolConfiguration(cfg)
    out?.isTemplate = false
    return out
}
