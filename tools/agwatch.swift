// agwatch — быстрый сторож службы AmneziaGuard (root, запускается из guard.sh).
//
// 1) Сеть: слушает routing-сокет ядра и сразу шлёт службе SIGUSR1, когда появился / пропал
//    интерфейс (utun Amnezia, Wi-Fi), сменился адрес или постоянный маршрут.
//    Временные маршруты, которые система клонирует на каждый новый сайт, игнорируются.
// 2) Брандмауэр: каждые 0,2 с проверяет, что pf включён и правила AmneziaGuard на месте.
//    Если кто-то выключил pf или снял правила — чинит САМ, сразу, и будит службу.
//
//   agwatch <pid> <anchor> <ag_dir>  — рабочий режим; выходит, когда <pid> завершился
//   agwatch --print                  — печатать сетевые события (для проверки)
import Darwin

let args = CommandLine.arguments
let printMode = args.count > 1 && args[1] == "--print"
let target: pid_t = printMode ? 0 : pid_t(args.count > 1 ? args[1] : "") ?? 0
let anchor = args.count > 2 ? args[2] : ""
let agDir = args.count > 3 ? args[3] : ""
if !printMode && (target <= 0 || anchor.isEmpty || agDir.isEmpty) {
    fputs("usage: agwatch <pid> <anchor> <ag_dir> | --print\n", stderr)
    exit(2)
}
setvbuf(stdout, nil, _IOLBF, 0)

let pfctl = (getenv("AG_TEST_PATH").map { String(cString: $0) + "/pfctl" }) ?? "/sbin/pfctl"
let checkEvery = 0.2

// MARK: - запуск pfctl без shell (posix_spawn — самый дешёвый способ)

@discardableResult
func run(_ argv: [String], capture: Bool = true) -> String {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return "" }
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&fa, fds[0])
    var cargs = argv.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, argv[0], &fa, nil, &cargs, environ)
    posix_spawn_file_actions_destroy(&fa)
    cargs.forEach { free($0) }
    close(fds[1])
    var out = [UInt8]()
    if rc == 0 {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fds[0], &chunk, chunk.count)
            if n <= 0 { break }
            if capture { out.append(contentsOf: chunk[0..<n]) }
        }
        var st: Int32 = 0
        waitpid(pid, &st, 0)
    }
    close(fds[0])
    return String(decoding: out, as: UTF8.self)
}

func log(_ msg: String) {
    var t = time(nil)
    var tmv = tm()
    localtime_r(&t, &tmv)
    var buf = [CChar](repeating: 0, count: 32)
    strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tmv)
    print("\(String(cString: buf)) \(msg)")
}

func protectionEnabled() -> Bool {
    guard let f = fopen(agDir + "/enabled", "r") else { return true }
    defer { fclose(f) }
    return fgetc(f) != Int32(UInt8(ascii: "0"))
}

func guardFirewall() {
    guard protectionEnabled() else { return }
    var fixed = false
    if !run([pfctl, "-s", "info"]).contains("Status: Enabled") {
        run([pfctl, "-E"], capture: false)
        log("pf кто-то выключил — включён обратно (сторож)")
        fixed = true
    }
    if !run([pfctl, "-a", anchor, "-sr"]).contains("block drop") {
        let saved = agDir + "/rules.active"
        if access(saved, R_OK) == 0 {
            run([pfctl, "-a", anchor, "-f", saved], capture: false)
            log("правила кто-то снял — восстановлены (сторож)")
            fixed = true
        }
    }
    if fixed { kill(target, SIGUSR1) }
}

// MARK: - сетевые события

let ignoredPrefixes = ["awdl", "llw", "anpi", "ap", "bridge", "gif", "stf", "lo"]

func ifName(_ index: UInt16) -> String {
    var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
    return if_indextoname(UInt32(index), &buf) != nil ? String(cString: buf) : "if\(index)"
}

func interesting(_ name: String) -> Bool { !ignoredPrefixes.contains { name.hasPrefix($0) } }

/// Разбирает пачку сообщений ядра; возвращает описание важных событий или nil.
func parse(_ raw: UnsafeRawBufferPointer, _ n: Int) -> String? {
    var off = 0
    var what = ""
    while off + 4 <= n {
        let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
        if len < 4 || off + len > n { break }
        let type = Int32(raw.load(fromByteOffset: off + 3, as: UInt8.self))
        switch type {
        case RTM_IFINFO, RTM_IFINFO2:
            let name = ifName(raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self).ifm_index)
            if interesting(name) { what += " if:\(name)" }
        case RTM_NEWADDR, RTM_DELADDR:
            let name = ifName(raw.loadUnaligned(fromByteOffset: off, as: ifa_msghdr.self).ifam_index)
            if interesting(name) { what += (type == RTM_NEWADDR ? " +addr:" : " -addr:") + name }
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            let m = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
            let cloned = m.rtm_flags & (RTF_WASCLONED | RTF_LLINFO) != 0
            let name = ifName(m.rtm_index)
            if !cloned && interesting(name) { what += " route:\(name)" }
        default:
            break
        }
        off += len
    }
    return what.isEmpty ? nil : what
}

let sock = socket(PF_ROUTE, SOCK_RAW, 0)
guard sock >= 0 else { perror("socket(PF_ROUTE)"); exit(1) }

var buf = [UInt8](repeating: 0, count: 16384)
var lastCheck = 0.0
func now() -> Double { var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts); return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 }

while true {
    // ждём сообщение ядра, но не дольше, чем до следующей проверки брандмауэра
    var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
    let waitMs = Int32(min(max(lastCheck + checkEvery - now(), 0), checkEvery) * 1000)
    if poll(&pfd, 1, printMode ? -1 : waitMs) > 0 {
        let n = read(sock, &buf, buf.count)
        if n > 0, let what = buf.withUnsafeBytes({ parse($0, n) }) {
            if printMode { print("event" + what) } else { kill(target, SIGUSR1) }
        }
    }
    if printMode { continue }
    if now() - lastCheck >= checkEvery {
        lastCheck = now()
        if kill(target, 0) != 0 { exit(0) } // служба завершилась — уходим и мы
        guardFirewall()
    }
}
