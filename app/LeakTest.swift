import AppKit
import Darwin

/// Проверка «на деле»: пробуем соединиться с 1.1.1.1:443 напрямую через Wi-Fi/Ethernet,
/// принудительно мимо VPN (как это делают утекающие приложения). Должно НЕ получиться.
/// И контрольная попытка обычным путём (через туннель) — должна получиться.
enum LeakTest {
    private static let ipBoundIf: Int32 = 25 // IP_BOUND_IF из <netinet/in.h>

    /// true — соединение установлено.
    static func tcpConnect(_ host: String, _ port: UInt16, boundTo iface: String?, timeoutMs: Int32 = 3000) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if let iface, !iface.isEmpty {
            var idx = if_nametoindex(iface)
            guard idx != 0 else { return false }
            setsockopt(fd, IPPROTO_IP, ipBoundIf, &idx, socklen_t(MemoryLayout<UInt32>.size))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l)
        return err == 0
    }

    static func run(physIface: String, vpnUp: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let direct = tcpConnect("1.1.1.1", 443, boundTo: physIface)
            let viaVPN = tcpConnect("1.1.1.1", 443, boundTo: nil)
            DispatchQueue.main.async { show(direct: direct, viaVPN: viaVPN, phys: physIface, vpnUp: vpnUp) }
        }
    }

    private static func show(direct: Bool, viaVPN: Bool, phys: String, vpnUp: Bool) {
        let a = NSAlert()
        let l1 = direct
            ? "✗ Напрямую через \(phys) соединение ПРОШЛО — трафик может уйти мимо VPN!"
            : "✓ Напрямую через \(phys) (мимо VPN) — заблокировано."
        let l2: String
        if viaVPN {
            l2 = "✓ Через туннель Amnezia — интернет работает."
        } else if vpnUp {
            l2 = "✗ Через туннель тоже нет ответа — проблема с самим VPN-сервером."
        } else {
            l2 = "• VPN не подключён, поэтому интернета нет — так и должно быть."
        }
        a.messageText = direct ? "Обнаружена утечка" : "Утечек нет"
        a.informativeText = l1 + "\n" + l2
        a.alertStyle = direct ? .critical : .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Команды службе с правами администратора (macOS спросит пароль / Touch ID).
enum Privileged {
    @discardableResult
    static func agctl(_ args: String) -> Bool {
        let cmd = "'\(agDir)/agctl' \(args)"
        let src = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            let a = NSAlert()
            a.messageText = "Не удалось выполнить команду"
            a.informativeText = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
            a.runModal()
        }
        return err == nil
    }
}
