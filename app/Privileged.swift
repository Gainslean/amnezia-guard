import AppKit

/// Команды службе (agctl on / off / off 15), которым нужны права root.
///
/// 1. Основной путь — без окна пароля: установщик кладёт узкое правило в /etc/sudoers.d,
///    разрешающее ТОЛЬКО эти три команды, и мы вызываем `sudo -n`.
/// 2. Запасной путь — системное окно пароля. На macOS 27 окно, вызванное из приложения
///    без значка в Dock, может не получать клавиатуру, поэтому на время запроса приложение
///    становится обычным (со значком в Dock) и выходит на передний план.
enum Privileged {
    static let allowed: Set<String> = ["on", "off", "off 15"]

    @discardableResult
    static func agctl(_ args: String) -> Bool {
        guard allowed.contains(args) else { return false }
        if viaSudo(args) { return true }
        return viaPrompt(args)
    }

    /// sudo -n: без вопросов; если правила нет — сразу ошибка, а не ожидание пароля.
    private static func viaSudo(_ args: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", agDir + "/agctl"] + args.split(separator: " ").map(String.init)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func viaPrompt(_ args: String) -> Bool {
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        defer { if wasAccessory { NSApp.setActivationPolicy(.accessory) } }

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
