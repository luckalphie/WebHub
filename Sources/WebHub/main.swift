import AppKit

// 单实例保护：同一个 bundle 标识只允许一个宿主进程。
//
// 两个实例并存时它们会互相抢 `CFMessagePort`（后启动的那个建不出端口，
// 于是它点任何站点图标都打不开窗口），而且共用同一份 WebKit 数据仓库。
// 发现已有实例就把它叫到前台，自己安静退出。
if let bundleID = Bundle.main.bundleIdentifier {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let existing = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != myPID }
    if let existing {
        _ = existing.activate()
        exit(0)
    }
}

let launcherApp = NSApplication.shared
let launcherDelegate = LauncherAppDelegate()
launcherApp.delegate = launcherDelegate
launcherApp.setActivationPolicy(.regular)
launcherApp.run()
