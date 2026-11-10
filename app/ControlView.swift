import AppKit

/// Большая кнопка в меню: выключить / включить правило «трафик только через Amnezia».
/// Под ней — «на 15 минут»: защита выключится и через 15 минут включится сама (это делает служба,
/// так что сработает, даже если значок закрыт).
final class ControlView: NSView {
    var onDisable: (() -> Void)?
    var onDisableTemp: (() -> Void)?
    var onEnable: (() -> Void)?

    private let main = NSButton(title: "", target: nil, action: nil)
    private let temp = NSButton(title: "Выключить на 15 минут (потом включится само)", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private var enabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        for b in [main, temp] {
            b.bezelStyle = .rounded
            b.target = self
            addSubview(b)
        }
        main.controlSize = .large
        temp.controlSize = .regular
        main.action = #selector(mainClicked)
        main.imagePosition = .imageLeading
        main.font = .systemFont(ofSize: 13, weight: .semibold)
        temp.action = #selector(tempClicked)
        temp.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        temp.imagePosition = .imageLeading
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        addSubview(note)
        update(enabled: true, reenableAt: nil, available: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Высота: две строки кнопок, когда правило включено; одна — когда выключено.
    static func height(enabled: Bool) -> CGFloat { enabled ? 94 : 62 }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14, w = bounds.width - pad * 2
        main.frame = NSRect(x: pad, y: bounds.height - 38, width: w, height: 32)
        temp.frame = NSRect(x: pad, y: bounds.height - 68, width: w, height: 26)
        note.frame = NSRect(x: pad + 2, y: 4, width: w, height: 16)
    }

    func update(enabled: Bool, reenableAt: Double?, available: Bool) {
        self.enabled = enabled
        main.isEnabled = available
        temp.isEnabled = available
        temp.isHidden = !enabled
        let h = Self.height(enabled: enabled)
        if frame.height != h { setFrameSize(NSSize(width: frame.width, height: h)) }
        let symbol = enabled ? "power" : "lock.shield.fill"
        main.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        main.title = enabled ? "Выключить «только через Amnezia»" : "Включить «только через Amnezia»"
        main.contentTintColor = enabled ? .systemRed : .systemGreen

        if !available {
            note.stringValue = "Служба не отвечает — кнопки недоступны"
        } else if enabled {
            note.stringValue = "Сейчас весь трафик идёт только через VPN"
        } else if let t = reenableAt, t > 0 {
            let left = max(0, Int((t - Date().timeIntervalSince1970) / 60.0 + 0.99))
            note.stringValue = "Правило выключено — включится само через \(left) мин"
        } else {
            note.stringValue = "Правило выключено — трафик может идти мимо VPN"
        }
        needsLayout = true
    }

    @objc private func mainClicked() {
        closeMenu()
        enabled ? onDisable?() : onEnable?()
    }

    @objc private func tempClicked() {
        closeMenu()
        onDisableTemp?()
    }

    private func closeMenu() { enclosingMenuItem?.menu?.cancelTracking() }
}
