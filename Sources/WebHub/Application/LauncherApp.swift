import AppKit
import WebKit
import SwiftUI

// MARK: - 启动器

final class LauncherWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let nativeModel = NativeLauncherModel()
    private var nativeIconKeys: [String: String] = [:]
    private var nativeView: NSHostingView<NativeLauncherView>!
    private var settingsWindow: NSWindow?
    private var ready = false
    private var pendingSettings = false
    private var pendingPayload: String?
    private var changingFullScreen = false
    /// 单宿主下菜单是全局的，站点窗口会挂上自己那份；切回应用中心时要还原
    private var launcherMenu: NSMenu?
    private var changingStandaloneApps = false

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let translationData = (try? JSONEncoder().encode(WebHubLanguage.translations)) ?? Data("{}".utf8)
        let translationJSON = String(data: translationData, encoding: .utf8) ?? "{}"
        config.userContentController.addUserScript(WKUserScript(source: "window.webHubChinese = \(WebHubLanguage.isChinese ? "true" : "false"); window.webHubTranslations = \(translationJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "hub")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = SafariUserAgent.value
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
        window.tabbingMode = .disallowed
        window.title = "WebHub"
        // ARC 下必须为 false：否则 close 后系统会 release 掉，controller 里的引用变野指针
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 620, height: 460)
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.center()
        restoreWindowFrame()
        window.delegate = self
        nativeModel.action = { [weak self] in self?.handleLauncherAction($0) }
        nativeModel.edit = { [weak self] in self?.showEditor(id: $0) }
        nativeModel.settings = { [weak self] in self?.showSettings() }
        nativeModel.dismissSettings = { [weak self] in self?.dismissSettings() }
        nativeView = NSHostingView(rootView: NativeLauncherView(model: nativeModel))
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        if let html = LauncherWindowController.htmlURL() {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        buildMenu()
        if !RunnerPackager.hasStandalonePreference {
            DispatchQueue.main.async { [weak self] in self?.disableStandaloneApps { _ in } }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRunning),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRunning),
                                               name: SiteWindowManager.runningSitesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .webHubDisplayPreferencesChanged, object: nil)
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

    func showSettings() {
        reveal()
        guard ready else { pendingSettings = true; return }
        guard settingsWindow == nil else { settingsWindow?.makeKeyAndOrderFront(nil); return }
        nativeModel.settingsShown = true
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = WebHubLanguage.text("Settings")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: NativeSettingsView(model: nativeModel))
        let parentFrame = window.frame
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parentFrame
        let originX = min(max(parentFrame.midX - panel.frame.width / 2, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
        let originY = min(max(parentFrame.midY - panel.frame.height / 2, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        settingsWindow = panel
        panel.makeKeyAndOrderFront(nil)
        // 等 SwiftUI 的按钮事件返回后再进入 AppKit 模态循环，避免重入阻塞后续按钮事件。
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.settingsWindow === panel else { return }
            NSApp.runModal(for: panel)
            panel.orderOut(nil)
            self.settingsWindow = nil
            self.nativeModel.settingsShown = false
        }
    }

    private func dismissSettings() {
        guard let panel = settingsWindow, !nativeModel.settingsBusy, NSApp.modalWindow === panel else { return }
        NSApp.stopModal()
    }

    private func showEditor(id: String?) {
        guard ready else { return }
        nativeModel.editor = NativeEditorRequest(app: id.flatMap { identifier in AppStore.shared.apps.first { $0.id == identifier } })
    }

    /// 关红叉只是收起窗口，进程留在后台 —— 和 Chrome 一致。
    /// 站点窗口还开着时更不能因为「应用中心关了」而影响它们。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            dismissSettings()
            return false
        }
        saveWindowFrame()
        sender.orderOut(nil)
        return false
    }

    private func restoreWindowFrame() {
        guard let saved = AppStore.shared.launcherWindowFrame() else { return }
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
        AppStore.shared.saveLauncherWindowFrame(frame)
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
                    // 与 Dock 图标一样裁掉透明留白，再按磁贴的 Retina 尺寸生成预览。
                    let preview = NSImage(data: data)
                        .flatMap { IconBuilder.squareGlyph(glyph: $0, box: 160) }
                        .flatMap { $0.tiffRepresentation }
                        .flatMap { NSBitmapImageRep(data: $0) }
                        .flatMap { $0.representation(using: .png, properties: [:]) } ?? data
                    item["icon"] = "data:image/png;base64," + preview.base64EncodedString()
                }
            }
            items.append(item)
        }
        let profile = NetworkProxyStore.shared.profile
        let proxy: [String: Any] = ["kind": profile?.kind.rawValue ?? "system", "host": profile?.host ?? "", "port": profile.map { String($0.port) } ?? "", "bypass": profile?.bypassDomains.joined(separator: ", ") ?? "", "username": profile?.username ?? "", "hasPassword": profile?.password != nil]
        let obj: [String: Any] = ["apps": items, "running": RunningApps.shared.ids(), "proxy": proxy, "appearance": WebHubAppearance.preference.rawValue, "language": WebHubLanguage.languagePreference]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{\"apps\":[],\"running\":[]}" }
        return str
    }

    @objc func refresh() {
        guard ready else { return }
        let apps = AppStore.shared.apps
        var iconKeys: [String: String] = [:]
        var icons: [String: NSImage] = [:]
        for app in apps {
            let iconURL = AppStore.shared.iconURL(for: app)
            let attributes = iconURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(app.name)|\(app.accent)|\(app.effectiveIconMode.rawValue)|\(iconURL?.path ?? "")|\(modified)"
            iconKeys[app.id] = key
            if nativeIconKeys[app.id] == key, let icon = nativeModel.icons[app.id] {
                icons[app.id] = icon
                continue
            }
            let glyph = iconURL.flatMap { NSImage(contentsOf: $0) }
            let imageData = (app.effectiveIconMode == .website ? glyph.flatMap { IconBuilder.composeIcon(glyph: $0, accent: app.accent, size: 160) } : nil)
                ?? IconBuilder.nameIcon(name: app.name, accent: app.accent, size: 160)
            icons[app.id] = imageData.flatMap { NSImage(data: $0) }
        }
        nativeIconKeys = iconKeys
        nativeModel.icons = icons
        nativeModel.apps = apps
        let json = payload()
        eval("window.hubRender(\(jsString(json)))")
    }

    @objc private func refreshRunning() {
        guard ready else { return }
        nativeModel.running = Set(RunningApps.shared.ids())
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
        updateStandaloneControl()
        if pendingSettings {
            pendingSettings = false
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        window.contentView = nativeView
    }

    // MARK: 消息桥

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        handleLauncherAction(body)
    }

    private func handleLauncherAction(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        let store = AppStore.shared

        switch type {
        case "returnNative":
            window.contentView = nativeView
            refresh()

        case "saveSettings":
            saveSettings(body)

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
            guard let id = body["id"] as? String,
                  let app = store.apps.first(where: { $0.id == id }) else { return }
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.format("Remove %@?", app.name)
            alert.informativeText = WebHubLanguage.text("This also deletes the app's bookmarks and their backup.")
            alert.addButton(withTitle: WebHubLanguage.text("Remove"))
            alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SiteWindowManager.shared.close(id)
            do {
                try store.remove(id: id)
                refresh()
            } catch {
                let failure = NSAlert(error: error)
                failure.messageText = WebHubLanguage.text("Unable to Remove App")
                failure.runModal()
            }

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

    private func saveSettings(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String, let enabled = body["enabled"] as? Bool,
              let appearanceValue = body["appearance"] as? String, let appearance = WebHubAppearance(rawValue: appearanceValue),
              let language = body["language"] as? String, ["system", "en", "zh-CN"].contains(language) else {
            nativeModel.settingsBusy = false
            return
        }
        let profile: NetworkProxyProfile?
        if kind == "system" {
            profile = nil
        } else {
            let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredPassword = body["password"] as? String ?? ""
            guard !username.isEmpty || enteredPassword.isEmpty else {
                settingsFailed("Enter a proxy username.")
                return
            }
            let previous = NetworkProxyStore.shared.profile
            let host = body["host"] as? String ?? ""
            let portText = body["port"] as? String ?? ""
            let canReusePassword = previous?.kind.rawValue == kind && previous?.host == host.trimmingCharacters(in: .whitespacesAndNewlines) && previous.map { String($0.port) } == portText && previous?.username == username
            let password = username.isEmpty ? nil : (enteredPassword.isEmpty && canReusePassword ? previous?.password : enteredPassword)
            guard username.isEmpty || !(password ?? "").isEmpty else {
                settingsFailed("Enter a proxy password.")
                return
            }
            guard let type = NetworkProxyProfile.Kind(rawValue: kind),
                  let port = UInt16(portText),
                  let value = NetworkProxyProfile(name: "Global", kind: type, host: host, port: port, bypassDomains: body["bypass"] as? String ?? "", username: username, password: password) else {
                settingsFailed("Enter a valid host and port from 1 to 65535.")
                return
            }
            profile = value
        }
        setStandaloneApps(enabled) { [weak self] success in
            guard let self else { return }
            guard success else { self.nativeModel.settingsBusy = false; return }
            do {
                try NetworkProxyStore.shared.save(profile)
                SiteWindowManager.shared.refreshNetworkProxy()
                let languageChanged = (body["languageChanged"] as? Bool == true) && language != WebHubLanguage.languagePreference
                if body["appearanceChanged"] as? Bool == true { WebHubAppearance.select(appearance) }
                if languageChanged { UserDefaults.standard.set(language, forKey: "WebHub.language") }
                self.refresh()
                self.nativeModel.settingsBusy = false
                self.dismissSettings()
                if languageChanged {
                    let alert = NSAlert()
                    alert.messageText = WebHubLanguage.text("Language changed")
                    alert.informativeText = WebHubLanguage.text("Restart WebHub to apply the language change to all windows.")
                    alert.addButton(withTitle: WebHubLanguage.text("OK"))
                    alert.runModal()
                }
            } catch {
                self.settingsFailed("Unable to save proxy settings.")
            }
        }
    }

    private func settingsFailed(_ message: String) {
        nativeModel.settingsBusy = false
        let alert = NSAlert()
        alert.messageText = WebHubLanguage.text(message)
        alert.runModal()
    }

    /// 清除某站点的登录态（cookie/localStorage）与已保存密码
    private func clearLoginState(for app: WebApp) {
        let host = URL(string: app.url)?.host ?? ""
        let root = CredentialStore.registrableDomain(host)

        let alert = NSAlert()
        alert.messageText = WebHubLanguage.format("Clear sign-in data for %@?", app.name)
        alert.informativeText = WebHubLanguage.format("Cookies, local storage, and saved credentials for %@ will be cleared. You will need to sign in again.", root)
        alert.addButton(withTitle: WebHubLanguage.text("Clear"))
        alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let credentialScope = app.usesIsolatedLogin ? app.id : nil
        CredentialStore.shared.delete(host: root, appID: credentialScope)
        if root != host { CredentialStore.shared.delete(host: host, appID: credentialScope) }

        // 单宿主：所有窗口共用同一个数据仓库，直接清一次就全都没了，
        // 不需要再往共享池写墓碑通知「其它进程」。
        SharedStorage.clear(for: app) { [weak self] in
            self?.showMessage(WebHubLanguage.format("Sign-in data cleared for %@", root))
        }
    }

    // MARK: 图标

    private func fetchIcon(for app: WebApp, announce: Bool) {
        let proxy = NetworkProxyStore.shared.profile
        let completion: (Data?) -> Void = { [weak self] png in
            guard let self = self,
                  let current = AppStore.shared.apps.first(where: { $0.id == app.id }),
                  current.url == app.url, current.iconURL == app.iconURL,
                  NetworkProxyStore.shared.profile == proxy,
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
                if announce { self.showMessage(WebHubLanguage.text("Could not fetch the website icon; using a name icon.")) }
            }
        }
        if let iconURL = app.iconURL, !iconURL.isEmpty {
            IconFetcher.fetchIcon(from: iconURL, proxy: proxy, completion: completion)
        } else {
            IconFetcher.fetch(for: app.url, proxy: proxy, completion: completion)
        }
    }

    private func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: WebHubLanguage.text("About WebHub"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updateItem = NSMenuItem(title: WebHubLanguage.text("Check for Updates…"), action: #selector(UpdateChecker.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = UpdateChecker.shared
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: WebHubLanguage.text("Settings") + "…", action: #selector(LauncherAppDelegate.showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = NSApp.delegate
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: WebHubLanguage.text("Hide WebHub"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: WebHubLanguage.text("Quit WebHub"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: WebHubLanguage.text("Edit"))

        func standard(_ title: String, _ actionName: String, _ key: String,
                      _ mask: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(actionName), keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            editMenu.addItem(item)
        }
        standard(WebHubLanguage.text("Undo"), "undo:", "z")
        standard(WebHubLanguage.text("Redo"), "redo:", "z", [.command, .shift])
        editMenu.addItem(NSMenuItem.separator())
        standard(WebHubLanguage.text("Cut"), "cut:", "x")
        standard(WebHubLanguage.text("Copy"), "copy:", "c")

        standard(WebHubLanguage.text("Paste"), "paste:", "v")

        standard(WebHubLanguage.text("Select All"), "selectAll:", "a")
        editMenu.addItem(NSMenuItem.separator())

        let addItem = NSMenuItem(title: WebHubLanguage.text("Add App…"), action: #selector(addApp), keyEquivalent: "n")
        addItem.target = self
        editMenu.addItem(addItem)
        let refreshItem = NSMenuItem(title: WebHubLanguage.text("Reload"), action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        editMenu.addItem(refreshItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        mainMenu.addItem(ViewMenu.makeItem())
        launcherMenu = mainMenu
        WindowHelpMenus.shared.activate(mainMenu)
    }

    /// 站点窗口切走后再切回应用中心：把菜单还原成启动器这份
    func windowDidBecomeKey(_ notification: Notification) {
        if let m = launcherMenu, NSApplication.shared.mainMenu !== m {
            WindowHelpMenus.shared.activate(m)
        }
    }

    /// 所有站点窗口都关掉后，把菜单还原。
    /// 否则菜单栏还停在最后那个站点的菜单上，它的「退出」只关该站点窗口（已经没了），
    /// 按 Cmd+Q 会毫无反应。
    func restoreMenu() {
        guard let m = launcherMenu else { return }
        WindowHelpMenus.shared.activate(m)
    }

    private func setStandaloneApps(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard !changingStandaloneApps else { updateStandaloneControl(); completion(false); return }
        guard enabled != RunnerPackager.createsStandaloneApps else { updateStandaloneControl(); completion(true); return }
        if !enabled {
            disableStandaloneApps(completion: completion)
        } else {
            RunnerPackager.createsStandaloneApps = true
            updateStandaloneControl()
            createStandaloneApps(AppStore.shared.apps)
            completion(true)
        }
    }

    private func updateStandaloneControl() {
        guard ready else { return }
        eval("window.hubSetStandaloneApps(\(RunnerPackager.createsStandaloneApps), \(changingStandaloneApps))")
    }

    private func createStandaloneApps(_ apps: [WebApp], index: Int = 0) {
        guard RunnerPackager.createsStandaloneApps, !changingStandaloneApps, index < apps.count else { return }
        guard let current = AppStore.shared.apps.first(where: { $0.id == apps[index].id }) else {
            createStandaloneApps(apps, index: index + 1)
            return
        }
        if RunnerPackager.ensureApp(for: current, iconPNG: nil) == nil {
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.format("Unable to create standalone app for %@", current.name)
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.createStandaloneApps(apps, index: index + 1)
        }
    }

    private func disableStandaloneApps(completion: @escaping (Bool) -> Void) {
        guard !changingStandaloneApps else { completion(false); return }
        let bundles: [URL]
        do { bundles = try RunnerPackager.standaloneBundles() }
        catch {
            RunnerPackager.createsStandaloneApps = true
            updateStandaloneControl()
            showStandaloneError(error)
            completion(false)
            return
        }
        let paths = Set(bundles.map { $0.resolvingSymlinksInPath().path })
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let url = $0.bundleURL else { return false }
            return paths.contains(url.resolvingSymlinksInPath().path) && !$0.isTerminated
        }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.text("Quit running standalone apps?")
            alert.informativeText = WebHubLanguage.text("Running site windows will close and their standalone apps will be removed. Site data will be kept.")
            alert.addButton(withTitle: WebHubLanguage.text("Quit and Remove"))
            alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                RunnerPackager.createsStandaloneApps = true
                updateStandaloneControl()
                completion(false)
                return
            }
        }
        changingStandaloneApps = true
        RunnerPackager.isChangingStandaloneApps = true
        updateStandaloneControl()
        for process in running {
            let runner = process.bundleURL.flatMap { RunnerPackager.appID(in: $0) }.flatMap { RunnerProcess(application: process, appID: $0) }
            if let url = process.bundleURL, let id = RunnerPackager.appID(in: url), SiteWindowManager.shared.openSiteIDs.contains(id) {
                SiteWindowManager.shared.close(id)
            }
            runner?.requestTermination()
        }
        finishDisablingStandaloneApps(bundles, running: running, deadline: Date().addingTimeInterval(5), completion: completion)
    }

    private func finishDisablingStandaloneApps(_ bundles: [URL], running: [NSRunningApplication], deadline: Date, completion: @escaping (Bool) -> Void) {
        if running.contains(where: { !$0.isTerminated }) {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.finishDisablingStandaloneApps(bundles, running: running, deadline: deadline, completion: completion)
                }
                return
            }
            changingStandaloneApps = false
            RunnerPackager.isChangingStandaloneApps = false
            RunnerPackager.createsStandaloneApps = true
            updateStandaloneControl()
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.text("Some standalone apps did not quit")
            alert.informativeText = WebHubLanguage.text("No standalone apps were removed. Close them and try again.")
            alert.runModal()
            completion(false)
            return
        }
        do {
            try RunnerPackager.deleteStandaloneBundles(bundles)
            RunnerPackager.createsStandaloneApps = false
        } catch {
            RunnerPackager.createsStandaloneApps = true
            showStandaloneError(error)
        }
        changingStandaloneApps = false
        RunnerPackager.isChangingStandaloneApps = false
        updateStandaloneControl()
        completion(!RunnerPackager.createsStandaloneApps)
    }

    private func showStandaloneError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = WebHubLanguage.text("Unable to remove standalone apps")
        alert.runModal()
    }

    @objc private func addApp() {
        showEditor(id: nil)
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
        SiteWindowManager.shared.openSiteIDs
    }
}
