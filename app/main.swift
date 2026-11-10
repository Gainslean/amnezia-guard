import AppKit

// Только одна копия значка в строке меню.
let me = Bundle.main.bundleIdentifier ?? "com.amneziaguard.menubar"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без значка в Dock, только в строке меню
app.run()
