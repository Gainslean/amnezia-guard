import Foundation
import Darwin

let agDir = ProcessInfo.processInfo.environment["AG_DIR"] ?? "/Library/Application Support/AmneziaGuard"

/// То, что пишет служба guard.sh в status.json раз в 2 секунды.
struct GuardStatus: Decodable {
    var ts: Double
    var enabled: Bool
    var pf: Bool
    var rules: Bool
    var vpn_proc: Bool
    var vpn_up: Bool
    var vpn_if: String
    var phys_if: String
    var ports: [String]
    var servers: [String]
    var blocked: Int
    var allow_lan: Int
    var allow_split: Int
    var reenable_at: Double?   // если выключено временно — когда включится само
}

enum Health: Equatable {
    case ok          // защита включена, VPN работает
    case vpnDown     // защита включена, VPN нет — интернет закрыт (утечек нет)
    case unprotected // защита выключена или pf снят — возможна утечка
    case noService   // служба не отвечает
}

func readStatus() -> GuardStatus? {
    let url = URL(fileURLWithPath: agDir + "/status.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(GuardStatus.self, from: data)
}

func health(of s: GuardStatus?) -> Health {
    guard let s, Date().timeIntervalSince1970 - s.ts < 20 else { return .noService }
    if !s.enabled || !s.pf || !s.rules { return .unprotected }
    return s.vpn_up ? .ok : .vpnDown
}

/// 64-битные счётчики байт по всем интерфейсам (sysctl NET_RT_IFLIST2).
func interfaceBytes() -> [String: (rx: UInt64, tx: UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
    var out: [String: (rx: UInt64, tx: UInt64)] = [:]
    buf.withUnsafeBytes { raw in
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
            if hdr.ifm_msglen == 0 { break }
            if Int32(hdr.ifm_type) == RTM_IFINFO2,
               off + MemoryLayout<if_msghdr2>.size <= len {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                    out[String(cString: name)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
                }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    return out
}

/// Скорость через туннель и история для графика.
final class SpeedTracker {
    static let historyLength = 90
    private var last: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var lastIface = ""
    private(set) var down: [Double] = []
    private(set) var up: [Double] = []
    private(set) var totalRx: UInt64 = 0
    private(set) var totalTx: UInt64 = 0

    var currentDown: Double { down.last ?? 0 }
    var currentUp: Double { up.last ?? 0 }

    func sample(iface: String) {
        let now = Date().timeIntervalSince1970
        guard !iface.isEmpty, let c = interfaceBytes()[iface] else {
            push(0, 0); last = nil; return
        }
        if iface != lastIface { last = nil; lastIface = iface }
        if let l = last, now > l.t, c.rx >= l.rx, c.tx >= l.tx {
            let dt = now - l.t
            totalRx += c.rx - l.rx
            totalTx += c.tx - l.tx
            push(Double(c.rx - l.rx) / dt, Double(c.tx - l.tx) / dt)
        } else {
            push(0, 0)
        }
        last = (c.rx, c.tx, now)
    }

    private func push(_ d: Double, _ u: Double) {
        down.append(d); up.append(u)
        if down.count > Self.historyLength { down.removeFirst(); up.removeFirst() }
    }
}

func formatSpeed(_ bps: Double, short: Bool = false) -> String {
    let units = short ? ["B", "K", "M", "G"] : ["Б/с", "КБ/с", "МБ/с", "ГБ/с"]
    var v = bps, i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
    let num = (v < 10 && i > 0) ? String(format: "%.1f", v) : String(format: "%.0f", v)
    return short ? num + units[i] : num + " " + units[i]
}

func formatBytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .binary
    return f.string(fromByteCount: Int64(b))
}
