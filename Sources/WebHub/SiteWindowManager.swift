import AppKit
import WebHubIPC

/// 单宿主模式下的站点窗口管理（Chrome 式）。
///
/// 所有站点窗口都活在 **WebHub 这一个进程**里，共用同一个
/// `WKWebsiteDataStore` —— 于是 cookie / localStorage / IndexedDB
/// 是同一份数据，不再需要任何跨进程同步，也不会有多个进程抢
/// WebKit 进程而导致的 `CFRetain() called with NULL`。
///
/// 关闭独立 App 时，所有站点复用一个 Helper（见 Runner/main.swift）：
/// Helper 不建窗口、不加载 WebKit，只负责通过 CFMessagePort 请本进程开窗。
final class SiteWindowManager {

    static let shared = SiteWindowManager()

    /// shim 与本进程之间的通道名
    static let portName = WebHubIPC.portName

    private var controllers: [String: RunnerWindowController] = [:]
    /// 站点 id → 该站点 shim 的 pid（窗口全关时用它收掉 Dock 图标）
    private var shimPIDs: [String: pid_t] = [:]
    private var localPort: CFMessagePort?

    private init() {}

    var hasAnySiteWindow: Bool { !controllers.isEmpty }
    var openSiteIDs: [String] { Array(controllers.keys) }

    /// 最后一个站点窗口也关掉时回调（宿主据此把菜单还原成应用中心那份）
    var onAllSitesClosed: (() -> Void)?

    // MARK: - 窗口

    /// 打开（或激活）某个站点的窗口
    func open(_ app: WebApp, shimPID: pid_t? = nil) {
        if let pid = shimPID, pid > 1 { shimPIDs[app.id] = pid }

        if let existing = controllers[app.id] {
            existing.focus()
            return
        }
        guard let url = URL(string: app.url) else { return }

        let wc = RunnerWindowController(app: app, url: url)
        wc.onWindowClosed = { [weak self] in
            self?.siteWindowDidClose(app.id)
        }
        controllers[app.id] = wc
        wc.show()
    }

    func activate(_ appID: String) {
        controllers[appID]?.focus()
    }

    /// 用户在应用中心/菜单里主动关掉某站点
    func close(_ appID: String) {
        controllers[appID]?.hostWindow?.performClose(nil)
    }

    /// 站点窗口关闭 → 收掉它的 shim（Dock 图标随之消失）
    private func siteWindowDidClose(_ appID: String) {
        controllers.removeValue(forKey: appID)
        if let pid = shimPIDs.removeValue(forKey: appID), pid > 1 {
            kill(pid, SIGTERM)
        }
        if controllers.isEmpty { onAllSitesClosed?() }
    }

    /// WebHub 退出时把所有 shim 一起收掉，别在 Dock 里留孤儿图标
    func terminateAllShims() {
        for (_, pid) in shimPIDs where pid > 1 {
            kill(pid, SIGTERM)
        }
        shimPIDs.removeAll()
    }

    // MARK: - IPC 服务端

    /// 起一个本地 message port，等站点 shim 来「请我开窗」
    func startIPCServer() {
        guard localPort == nil else { return }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: CFMessagePortCallBack = { _, messageID, data, info in
            guard let info = info, let data = data else { return nil }
            let manager = Unmanaged<SiteWindowManager>.fromOpaque(info).takeUnretainedValue()
            manager.receive(messageID: messageID, payload: data as Data)
            return nil
        }

        guard let port = CFMessagePortCreateLocal(
            nil, Self.portName as CFString, callback, &context, nil
        ) else {
            NSLog("[WebHub] 无法创建 IPC 端口 \(Self.portName)")
            return
        }
        CFMessagePortSetDispatchQueue(port, DispatchQueue.main)
        localPort = port
    }

    private func receive(messageID: Int32, payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let cmd = obj["cmd"] as? String,
              let appID = obj["appID"] as? String, !appID.isEmpty
        else { return }

        let pid = (obj["pid"] as? Int).map { pid_t($0) } ?? 0

        switch cmd {
        case "open":
            guard let app = AppStore.shared.apps.first(where: { $0.id == appID }) else {
                // 站点已被删除：让 shim 自己退掉，别留个死图标
                if pid > 1 { kill(pid, SIGTERM) }
                return
            }
            open(app, shimPID: pid)
        case "activate":
            if controllers[appID] != nil {
                activate(appID)
            } else if let app = AppStore.shared.apps.first(where: { $0.id == appID }) {
                open(app, shimPID: pid > 1 ? pid : nil)
            }
        case "close":
            // shim 自己在退出（Dock 右键「退出」）：把窗口一并关掉，
            // 但不要再去 kill 它 —— 它已经在退出的路上了。
            guard let wc = controllers[appID] else { return }
            shimPIDs.removeValue(forKey: appID)
            wc.hostWindow?.performClose(nil)
        default:
            break
        }
    }
}
