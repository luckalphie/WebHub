import AppKit
import WebHubIPC

/// 站点 shim —— 相当于 Chrome 的 `app_mode_loader`。
///
/// 它**不创建窗口、不加载 WebKit**，只做两件事：
///   1. 启动时通过 CFMessagePort 请 WebHub 主进程（唯一宿主）打开本站点窗口
///   2. 常驻，给这个站点在 Dock 里占一个独立图标
///
/// 站点窗口全部关闭后，主进程会向它发 SIGTERM，它退出、Dock 图标消失。
/// 因为窗口和 WebKit 都在主进程里，登录态天然是同一份 profile，
/// 不再需要跨进程 cookie 同步。
final class ShimDelegate: NSObject, NSApplicationDelegate {

    private var appID = ""
    private var appName = "Web App"
    private var didLaunchHost = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        appID = (info["WebHubAppID"] as? String) ?? ""
        appName = (info["WebHubAppName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String) ?? "Web App"

        guard !appID.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        // 同站点已有 shim 在跑：让它去激活窗口，自己安静退出，避免出现两个 Dock 图标
        let me = ProcessInfo.processInfo.processIdentifier
        let siblings = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if !siblings.isEmpty {
            _ = send(WebHubIPC.Command.activate)
            NSApp.terminate(nil)
            return
        }

        sendWithRetry(.open)
    }

    /// 本 shim 退出时（Dock 右键「退出」、或系统要重启）把窗口一起关掉。
    /// 否则会留下一个「窗口还在、但 Dock 图标没了」的孤儿，除非去应用中心才找得回来。
    func applicationWillTerminate(_ notification: Notification) {
        guard !appID.isEmpty else { return }
        _ = send(.close)
    }

    /// 点 Dock 图标：把宿主进程里的窗口提到前面
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sendWithRetry(.activate)
        // 点 Dock 时被激活的是 shim 自己（它没有窗口、也没有菜单栏），
        // 不把前台交还给宿主的话，Cmd+W / Cmd+Q 会落到一个什么都没有的进程上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ShimDelegate.activateHost()
        }
        return true
    }

    /// 把前台让给 WebHub 主进程：菜单栏、键盘焦点都回到真正持有窗口的进程
    static func activateHost() {
        guard let pid = hostPID() else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// 宿主 pid 由主进程写在 launcher.pid 里（AppStore.rootDir / launcher.pid）
    private static func hostPID() -> pid_t? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = base
            .appendingPathComponent("WebHub", isDirectory: true)
            .appendingPathComponent("launcher.pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // pid 可能已被复用：确认它确实是活着的 WebHub
        guard kill(pid, 0) == 0 else { return nil }
        return pid
    }

    // MARK: - 与宿主通信

    private func send(_ command: WebHubIPC.Command) -> Bool {
        guard let remote = CFMessagePortCreateRemote(
            nil, WebHubIPC.portName as CFString
        ) else { return false }

        let payload: [String: Any] = [
            "cmd": command.rawValue,
            "appID": appID,
            "pid": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        let status = CFMessagePortSendRequest(
            remote, WebHubIPC.messageID, data as CFData, 2.0, 2.0, nil, nil
        )
        return status == kCFMessagePortSuccess
    }

    /// 宿主可能还没启动（用户直接从 Dock 点了站点图标）。
    /// 先拉起 WebHub，再退避重试几次；始终失败就自己退出，不留死图标。
    private func sendWithRetry(_ command: WebHubIPC.Command, attempt: Int = 0) {
        if send(command) { return }

        if !didLaunchHost {
            didLaunchHost = true
            launchHost()
        }
        guard attempt < 8 else {
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.sendWithRetry(command, attempt: attempt + 1)
        }
    }

    private func launchHost() {
        guard let path = Bundle.main.infoDictionary?[WebHubIPC.hostPathKey] as? String,
              FileManager.default.fileExists(atPath: path) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path), configuration: cfg, completionHandler: nil
        )
    }
}

let shimApp = NSApplication.shared
let shimDelegate = ShimDelegate()
shimApp.delegate = shimDelegate
// .regular 才有 Dock 图标；shim 本身不显示任何窗口
shimApp.setActivationPolicy(.regular)
shimApp.run()
