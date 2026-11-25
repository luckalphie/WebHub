import AppKit
import SwiftUI

// MARK: - 启动器

final class LauncherWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let model = LauncherModel()
    private var iconKeys: [String: String] = [:]
    private var launcherView: NSHostingView<LauncherView>!
    private lazy var settingsController = SettingsController(
        parentWindow: { [weak self] in self?.window },
        onRefresh: { [weak self] in self?.refresh() }
    )
    private var changingFullScreen = false
    /// 单宿主下菜单是全局的，站点窗口会挂上自己那份；切回应用中心时要还原
    private var launcherMenu: NSMenu?

    func show() {
        // 保留系统标准标题栏：既能显示标题，也提供可靠的窗口拖动区域。
        // 标题栏同时承担窗口拖动和标题展示，内容区全部交给原生 SwiftUI 视图。
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
        model.action = { [weak self] in self?.handleLauncherAction($0) }
        model.edit = { [weak self] in self?.showEditor(id: $0) }
        model.settings = { [weak self] in self?.showSettings() }
        launcherView = NSHostingView(rootView: LauncherView(model: model))
        window.contentView = launcherView
        window.makeKeyAndOrderFront(nil)
        refresh()
        refreshRunning()

        buildMenu()
        if !RunnerPackager.hasStandalonePreference {
            DispatchQueue.main.async { [weak self] in self?.settingsController.disableStandaloneAppsIfNeeded() }
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
        settingsController.show()
    }

    private func showEditor(id: String?) {
        model.editor = EditorRequest(app: id.flatMap { identifier in AppStore.shared.apps.first { $0.id == identifier } })
    }

    /// 关红叉只是收起窗口，进程留在后台 —— 和 Chrome 一致。
    /// 站点窗口还开着时更不能因为「应用中心关了」而影响它们。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if settingsController.owns(sender) {
            return settingsController.windowShouldClose(sender)
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

    // MARK: 数据刷新

    @objc func refresh() {
        let apps = AppStore.shared.apps
        var iconKeys: [String: String] = [:]
        var icons: [String: NSImage] = [:]
        for app in apps {
            let iconURL = AppStore.shared.iconURL(for: app)
            let attributes = iconURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(app.name)|\(app.accent)|\(app.effectiveIconMode.rawValue)|\(iconURL?.path ?? "")|\(modified)"
            iconKeys[app.id] = key
            if iconKeys[app.id] == key, let icon = model.icons[app.id] {
                icons[app.id] = icon
                continue
            }
            let glyph = iconURL.flatMap { NSImage(contentsOf: $0) }
            let imageData = (app.effectiveIconMode == .website ? glyph.flatMap { IconBuilder.composeIcon(glyph: $0, accent: app.accent, size: 160) } : nil)
                ?? IconBuilder.nameIcon(name: app.name, accent: app.accent, size: 160)
            icons[app.id] = imageData.flatMap { NSImage(data: $0) }
        }
        self.iconKeys = iconKeys
        model.icons = icons
        model.apps = apps
    }

    @objc private func refreshRunning() {
        model.running = Set(RunningApps.shared.ids())
    }

    private func handleLauncherAction(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
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

    @objc private func addApp() {
        showEditor(id: nil)
    }
}

// MARK: - 运行中应用追踪

final class RunningApps {
    static let shared = RunningApps()

    func ids() -> [String] {
        SiteWindowManager.shared.openSiteIDs
    }
}
