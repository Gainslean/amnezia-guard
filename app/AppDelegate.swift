import AppKit
import UserNotifications

/// Иконка в строке меню: щит (зелёный / оранжевый / красный) + скорость ↓↑ через туннель.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let speed = SpeedTracker()
    private let graph = GraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 110))
    private var timer: Timer?
    private var dirWatch: DispatchSourceFileSystemObject?
    private var status: GuardStatus?
    private var lastHealth: Health?

    private let headItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let speedItem = NSMenuItem()
    private let totalItem = NSMenuItem()
    private let tunnelItem = NSMenuItem()
    private let serverItem = NSMenuItem()
    private let blockedItem = NSMenuItem()
    private let control = ControlView(frame: NSRect(x: 0, y: 0, width: 380, height: ControlView.height(enabled: true)))

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // обновляется и при открытом меню
        timer = t
        watchStatusDir()
    }

    /// Служба переписывает status.json — значок узнаёт об этом сразу, а не через секунду.
    private func watchStatusDir() {
        let fd = open(agDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.refreshStatus() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirWatch = src
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        for i in [headItem, detailItem, speedItem, totalItem, tunnelItem, serverItem, blockedItem] {
            i.isEnabled = false
        }
        let graphItem = NSMenuItem()
        graph.autoresizingMask = [.width]
        graphItem.view = graph
        menu.addItem(headItem)
        menu.addItem(detailItem)
        let controlItem = NSMenuItem()
        controlItem.view = control
        control.onDisable = { [weak self] in DispatchQueue.main.async { self?.disable(minutes: nil) } }
        control.onDisableTemp = { [weak self] in DispatchQueue.main.async { self?.disable(minutes: 15) } }
        control.onEnable = { [weak self] in DispatchQueue.main.async { self?.enable() } }
        menu.addItem(controlItem)
        menu.addItem(.separator())
        menu.addItem(graphItem)
        menu.addItem(speedItem)
        menu.addItem(totalItem)
        menu.addItem(.separator())
        menu.addItem(tunnelItem)
        menu.addItem(serverItem)
        menu.addItem(blockedItem)
        menu.addItem(.separator())
        menu.addItem(action("Проверить, что утечек нет", #selector(leakTest), "t"))
        menu.addItem(action("Журнал службы", #selector(openLog), "l"))
        menu.addItem(action("Папка настроек", #selector(openConfig), ""))
        menu.addItem(.separator())
        menu.addItem(action("Скрыть значок (защита продолжит работать)", #selector(quit), "q"))
    }

    private func action(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: - обновление: скорость раз в секунду, состояние — сразу по событию

    private func tick() {
        speed.sample(iface: readStatus()?.vpn_if ?? "")
        refreshStatus()
    }

    private func refreshStatus() {
        status = readStatus()
        let h = health(of: status)
        updateButton(h)
        updateMenu(h)
        if let last = lastHealth, last != h { notify(h) }
        lastHealth = h
    }

    private func updateButton(_ h: Health) {
        guard let b = item.button else { return }
        b.image = shieldImage(for: h)
        let text: String
        switch h {
        case .ok: text = " ↓\(formatSpeed(speed.currentDown, short: true)) ↑\(formatSpeed(speed.currentUp, short: true))"
        case .vpnDown: text = " нет VPN"
        case .unprotected: text = " ВЫКЛ"
        case .noService: text = " ?"
        }
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ])
        b.toolTip = headline(h).0
    }

    private func headline(_ h: Health) -> (String, String, NSColor) {
        let ifn = status?.vpn_if ?? ""
        switch h {
        case .ok:
            return ("Всё в порядке — трафик идёт только через Amnezia",
                    "Туннель \(ifn) активен, всё остальное заблокировано", .systemGreen)
        case .vpnDown:
            return ("VPN отключён — интернет заблокирован",
                    "Утечек нет. Подключите Amnezia, и интернет вернётся", .systemOrange)
        case .unprotected:
            let why = status?.enabled == false ? "Защита выключена вручную" : "Правила pf не активны"
            return ("Защита НЕ работает", "\(why) — трафик может идти мимо VPN", .systemRed)
        case .noService:
            return ("Служба AmneziaGuard не отвечает",
                    "Переустановите: sudo ./install.sh", .systemRed)
        }
    }

    private func updateMenu(_ h: Health) {
        let (title, detail, color) = headline(h)
        headItem.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color,
        ])
        headItem.image = shieldImage(for: h, size: 14)
        detailItem.title = detail

        graph.down = speed.down
        graph.up = speed.up
        graph.accent = h == .ok ? .systemGreen : .systemOrange
        graph.caption = h == .ok ? "" : (h == .vpnDown ? "трафик остановлен" : "")

        speedItem.title = "Сейчас:  ↓ \(formatSpeed(speed.currentDown))   ↑ \(formatSpeed(speed.currentUp))"
        totalItem.title = "С запуска:  ↓ \(formatBytes(speed.totalRx))   ↑ \(formatBytes(speed.totalTx))"

        let s = status
        tunnelItem.title = "Туннель: \(s?.vpn_if.isEmpty == false ? s!.vpn_if : "—")   Сеть: \(s?.phys_if ?? "—")"
            + ((s?.ports.isEmpty ?? true) ? "" : "   порт \(s!.ports.joined(separator: ","))")
        let srv = s?.servers ?? []
        serverItem.title = srv.isEmpty ? "Сервер: ещё не выучен (выучится при подключении)"
            : "Сервер: " + srv.prefix(3).joined(separator: ", ") + (srv.count > 3 ? " +\(srv.count - 3)" : "")
        blockedItem.title = "Заблокировано пакетов мимо VPN: \(s?.blocked ?? 0)"
            + (s?.allow_split == 1 ? "   (исключения Amnezia разрешены)" : "")

        control.update(enabled: s?.enabled ?? true, reenableAt: s?.reenable_at, available: h != .noService)
    }

    private func notify(_ h: Health) {
        let (title, detail, _) = headline(h)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = detail
        if h != .ok { c.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - действия

    @objc private func leakTest() {
        guard let s = status, !s.phys_if.isEmpty else {
            let a = NSAlert(); a.messageText = "Нет данных от службы"; a.runModal(); return
        }
        LeakTest.run(physIface: s.phys_if, vpnUp: s.vpn_up)
    }

    /// Выключить правило «только через Amnezia». minutes == nil — до ручного включения.
    private func disable(minutes: Int?) {
        let a = NSAlert()
        a.messageText = minutes == nil ? "Выключить правило «только через Amnezia»?"
                                       : "Выключить правило на \(minutes!) минут?"
        a.informativeText = "Пока правило выключено, при падении VPN трафик пойдёт напрямую через провайдера."
            + (minutes == nil ? "\nВключить обратно — той же кнопкой." : "\nПотом защита включится сама.")
        a.addButton(withTitle: "Выключить")
        a.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Privileged.agctl(minutes.map { "off \($0)" } ?? "off")
        tick()
    }

    private func enable() {
        Privileged.agctl("on")
        tick()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/amnezia-guard.log"))
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: agDir))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
