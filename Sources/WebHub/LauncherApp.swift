import AppKit
import WebKit

// MARK: - 启动器

final class LauncherWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var ready = false
    private var pendingPayload: String?
    private let windowFrameKey = "WebHub.launcherWindowFrame"
    private var changingFullScreen = false
    /// 单宿主下菜单是全局的，站点窗口会挂上自己那份；切回应用中心时要还原
    private var launcherMenu: NSMenu?

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "hub")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        // 保留系统标准标题栏：既能显示标题，也提供可靠的窗口拖动区域。
        // 不用 fullSizeContentView —— WKWebView 会吞掉拖拽事件，
        // isMovableByWindowBackground 和 CSS 的 -webkit-app-region 在 WKWebView 里都无效。
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "WebHub"
        // ARC 下必须为 false：否则 close 后系统会 release 掉，controller 里的引用变野指针
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 620, height: 460)
        window.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        window.isMovableByWindowBackground = true
        window.center()
        restoreWindowFrame()
        window.delegate = self
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)

        if let html = LauncherWindowController.htmlURL() {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        buildMenu()
        installPasteShortcut()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRunning),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveWindowFrameOnExit),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    /// 点 Dock 图标 / reopen 时把应用中心窗口叫回来。
    /// 窗口关掉只是 orderOut，不销毁，所以这里能原样恢复（保留上次的滚动位置与状态）。
    func reveal() {
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关红叉只是收起窗口，进程留在后台 —— 和 Chrome 一致。
    /// 站点窗口还开着时更不能因为「应用中心关了」而影响它们。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        saveWindowFrame()
        sender.orderOut(nil)
        return false
    }

    private func restoreWindowFrame() {
        guard let values = UserDefaults.standard.array(forKey: windowFrameKey) as? [Double],
              values.count == 4, values.allSatisfy({ $0.isFinite }),
              values[2] > 0, values[3] > 0 else { return }
        let saved = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let screens = NSScreen.screens
        let screen = screens.max { left, right in
            let a = saved.intersection(left.visibleFrame)
            let b = saved.intersection(right.visibleFrame)
            return max(0, a.width) * max(0, a.height) < max(0, b.width) * max(0, b.height)
        }
        let visible = (screen.flatMap { saved.intersects($0.visibleFrame) ? $0 : nil } ?? NSScreen.main ?? screens.first)?.visibleFrame
        guard let visible = visible else { return }
        let width = min(max(saved.width, window.minSize.width), visible.width)
        let height = min(max(saved.height, window.minSize.height), visible.height)
        let x = min(max(saved.minX, visible.minX), visible.maxX - width)
        let y = min(max(saved.minY, visible.minY), visible.maxY - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    private func saveWindowFrame() {
        guard let window = window, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set([Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)], forKey: windowFrameKey)
    }

    @objc private func saveWindowFrameOnExit() { saveWindowFrame() }

    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    func windowWillEnterFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullScreen = false
        saveWindowFrame()
    }

    private static func htmlURL() -> URL? {
        // 打包成 .app 后由 scripts/build-app.sh 放进 Contents/Resources；
        // 直接 `swift run` 时它在 SwiftPM 生成的资源 bundle 里。
        if let res = Bundle.main.resourceURL?.appendingPathComponent("launcher.html"),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        return Bundle.module.url(forResource: "launcher.html", withExtension: nil)
    }

    // MARK: 数据推送

    private func payload() -> String {
        let store = AppStore.shared
        var items: [[String: Any]] = []
        for app in store.apps {
            var item: [String: Any] = ["id": app.id, "name": app.name,
                                       "url": app.url, "accent": app.accent,
                                       "iconMode": app.effectiveIconMode.rawValue,
                                       "isolatedLogin": app.usesIsolatedLogin,
                                       "supportedDomains": app.supportedDomains?.joined(separator: ", ") ?? "",
                                       "iconURL": app.iconURL ?? ""]
            if app.effectiveIconMode == .website, let iconURL = store.iconURL(for: app) {
                // 用 data URI 避免 file:// 权限问题
                if let data = try? Data(contentsOf: iconURL) {
                    item["icon"] = "data:image/png;base64," + data.base64EncodedString()
                }
            }
            items.append(item)
        }
        let obj: [String: Any] = ["apps": items, "running": RunningApps.shared.ids()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{\"apps\":[],\"running\":[]}" }
        return str
    }

    @objc func refresh() {
        guard ready else { return }
        let json = payload()
        eval("window.hubRender(\(jsString(json)))")
    }

    @objc private func refreshRunning() {
        guard ready else { return }
        let ids = (try? JSONSerialization.data(withJSONObject: RunningApps.shared.ids()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        eval("window.hubSetRunning(\(jsString(ids)))")
    }

    private func eval(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        refresh()
        refreshRunning()
    }

    // MARK: 消息桥

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let store = AppStore.shared

        switch type {
        case "open":
            guard let id = body["id"] as? String,
                  let app = store.apps.first(where: { $0.id == id }) else { return }
            RunnerPackager.launch(app: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refreshRunning() }

        case "add":
            guard let name = body["name"] as? String, let url = body["url"] as? String else { return }
            let accent = body["accent"] as? String
            let iconURL = body["iconURL"] as? String
            let mode = (body["iconMode"] as? String).flatMap(SiteIconMode.init(rawValue:)) ?? .website
            let isolatedLogin = body["isolatedLogin"] as? Bool ?? false
            let supportedDomains = body["supportedDomains"] as? String
            let app = store.add(name: name, url: url, iconURL: iconURL, accent: accent, iconMode: mode, isolatedLogin: isolatedLogin, supportedDomains: supportedDomains)
            refresh()
            if mode == .website {
                fetchIcon(for: app, announce: true)
            } else {
                _ = RunnerPackager.ensureApp(for: app, iconPNG: nil)
            }

        case "update":
            guard let id = body["id"] as? String else { return }
            guard let previous = store.apps.first(where: { $0.id == id }) else { return }
            let name = body["name"] as? String
            let url = body["url"] as? String
            let iconURL = body["iconURL"] as? String
            let accent = body["accent"] as? String
            let mode = (body["iconMode"] as? String).flatMap(SiteIconMode.init(rawValue:))
            let isolatedLogin = body["isolatedLogin"] as? Bool
            let supportedDomains = body["supportedDomains"] as? String
            guard var updated = store.update(id: id, name: name, url: url, iconURL: iconURL, accent: accent, iconMode: mode, isolatedLogin: isolatedLogin, supportedDomains: supportedDomains) else { return }
            let urlChanged = previous.url != updated.url
            let iconURLChanged = previous.iconURL != updated.iconURL
            if urlChanged || iconURLChanged {
                store.clearIcon(id: id)
                guard let current = store.apps.first(where: { $0.id == id }) else { return }
                updated = current
            }
            refresh()
            if updated.effectiveIconMode == .website && (urlChanged || iconURLChanged || store.iconURL(for: updated) == nil) {
                fetchIcon(for: updated, announce: false)
            }
            // 已打包过的 app 需要更新元数据
            _ = RunnerPackager.ensureApp(for: updated, iconPNG: nil)

        case "delete":
            guard let id = body["id"] as? String else { return }
            SiteWindowManager.shared.close(id)
            store.remove(id: id)
            refresh()

        case "reicon":
            guard let id = body["id"] as? String,
                  let app = store.apps.first(where: { $0.id == id }), app.effectiveIconMode == .website else { return }
            fetchIcon(for: app, announce: true)

        case "clearlogin":
            guard let id = body["id"] as? String,
                  let app = store.apps.first(where: { $0.id == id }) else { return }
            clearLoginState(for: app)

        case "move":
            guard let from = body["from"] as? String, let to = body["to"] as? String else { return }
            store.move(from: from, to: to)
            refresh()

        default:
            break
        }
    }

    // MARK: 登录态

    /// 清除某站点的登录态（cookie/localStorage）与已保存密码
    private func clearLoginState(for app: WebApp) {
        let host = URL(string: app.url)?.host ?? ""
        let root = CredentialStore.registrableDomain(host)

        let alert = NSAlert()
        alert.messageText = "清除 \(app.name) 的登录状态？"
        alert.informativeText = "将清除 \(root) 的 Cookie、本地存储，以及已保存的账号密码。清除后需要重新登录。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let credentialScope = app.usesIsolatedLogin ? app.id : nil
        CredentialStore.shared.delete(host: root, appID: credentialScope)
        if root != host { CredentialStore.shared.delete(host: host, appID: credentialScope) }

        // 单宿主：所有窗口共用同一个数据仓库，直接清一次就全都没了，
        // 不需要再往共享池写墓碑通知「其它进程」。
        SharedStorage.clear(for: app) { [weak self] in
            self?.eval("window.hubToast('已清除 \(root) 的登录状态')")
        }
    }

    // MARK: 图标

    private func fetchIcon(for app: WebApp, announce: Bool) {
        let completion: (Data?) -> Void = { [weak self] png in
            guard let self = self,
                  let current = AppStore.shared.apps.first(where: { $0.id == app.id }),
                  current.url == app.url, current.iconURL == app.iconURL,
                  current.effectiveIconMode == .website else { return }
            if let png = png, let _ = AppStore.shared.setIcon(id: app.id, png: png) {
                // 重新打包以更新 Dock 图标
                if let updated = AppStore.shared.apps.first(where: { $0.id == app.id }) {
                    _ = RunnerPackager.ensureApp(for: updated, iconPNG: png)
                }
                self.refresh()
            } else {
                // 兜底：名称图标
                AppStore.shared.clearIcon(id: current.id)
                if let updated = AppStore.shared.apps.first(where: { $0.id == app.id }) {
                    _ = RunnerPackager.ensureApp(for: updated, iconPNG: nil)
                }
                self.refresh()
                if announce { self.eval("window.hubToast('未能抓取网站图标，已使用名称图标')") }
            }
        }
        if let iconURL = app.iconURL, !iconURL.isEmpty {
            IconFetcher.fetchIcon(from: iconURL, completion: completion)
        } else {
            IconFetcher.fetch(for: app.url, completion: completion)
        }
    }

    // MARK: 剪贴板

    /// 手写 NSApplication 缺完整「编辑」菜单，WKWebView 输入框收不到 Cmd+V；
    /// macOS 也不把 Ctrl+V 映射成粘贴。这里统一接管两个快捷键，
    /// 把剪贴板文本插到当前聚焦的输入框（保留光标与选区语义）。
    private func installPasteShortcut() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 本地事件监听覆盖整个宿主进程；站点窗口的粘贴必须交给它自己的 WKWebView。
            guard let self = self, self.window.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control),
                  !flags.contains(.option),
                  (event.charactersIgnoringModifiers ?? "").caseInsensitiveCompare("v") == .orderedSame
            else { return event }
            self.pasteFromClipboard()
            return nil
        }
    }

    @objc private func pasteFromMenu() { pasteFromClipboard() }

    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        let literal = jsString(text)
        let offset = (text as NSString).length
        let js = """
        (function(){
          var el = document.activeElement;
          if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
          var s = (el.selectionStart == null) ? el.value.length : el.selectionStart;
          var e = (el.selectionEnd == null) ? el.value.length : el.selectionEnd;
          el.value = el.value.slice(0, s) + \(literal) + el.value.slice(e);
          var p = s + \(offset);
          try { el.setSelectionRange(p, p); } catch (_) {}
          el.dispatchEvent(new Event('input', { bubbles: true }));
        })()
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WebHub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 WebHub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 WebHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")

        func standard(_ title: String, _ actionName: String, _ key: String,
                      _ mask: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(actionName), keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            editMenu.addItem(item)
        }
        standard("撤销", "undo:", "z")
        standard("重做", "redo:", "z", [.command, .shift])
        editMenu.addItem(NSMenuItem.separator())
        standard("剪切", "cut:", "x")
        standard("拷贝", "copy:", "c")

        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(pasteFromMenu), keyEquivalent: "v")
        pasteItem.target = self
        editMenu.addItem(pasteItem)

        standard("全选", "selectAll:", "a")
        editMenu.addItem(NSMenuItem.separator())

        let addItem = NSMenuItem(title: "添加应用…", action: #selector(addApp), keyEquivalent: "n")
        addItem.target = self
        editMenu.addItem(addItem)
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        editMenu.addItem(refreshItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        launcherMenu = mainMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    /// 站点窗口切走后再切回应用中心：把菜单还原成启动器这份
    func windowDidBecomeKey(_ notification: Notification) {
        if let m = launcherMenu, NSApplication.shared.mainMenu !== m {
            NSApplication.shared.mainMenu = m
        }
    }

    /// 所有站点窗口都关掉后，把菜单还原。
    /// 否则菜单栏还停在最后那个站点的菜单上，它的「退出」只关该站点窗口（已经没了），
    /// 按 Cmd+Q 会毫无反应。
    func restoreMenu() {
        guard let m = launcherMenu else { return }
        NSApplication.shared.mainMenu = m
    }

    @objc private func addApp() {
        eval("openSheet(null)")
    }
}

// MARK: - 工具

/// 把 Swift 字符串转成安全的 JS 字面量
func jsString(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s]),
          let json = String(data: data, encoding: .utf8) else { return "\"\"" }
    // json 形如 ["..."]，去掉外层方括号
    var inner = json
    if inner.hasPrefix("[") { inner.removeFirst() }
    if inner.hasSuffix("]") { inner.removeLast() }
    return inner
}

// MARK: - 运行中应用追踪

final class RunningApps {
    static let shared = RunningApps()

    func ids() -> [String] {
        let store = AppStore.shared
        var result: [String] = []
        for app in store.apps {
            let bundleID = "cn.webhub.runner.\(app.id)"
            if isRunning(bundleID: bundleID) { result.append(app.id) }
        }
        return result
    }

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }
}
