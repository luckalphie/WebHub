import AppKit
import WebKit

// MARK: - 单站点的标签页

final class TabItem {
    let id = UUID()
    var webView: WKWebView?
    var title: String
    var url: URL
    var favicon: NSImage?
    var faviconURL: String?
    var titleObservation: NSKeyValueObservation?
    var urlObservation: NSKeyValueObservation?
    var unloadWork: DispatchWorkItem?
    var unloadDeadline: Date?
    fileprivate var tooltipOwner: TabToolTipOwner?

    init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

private final class TabToolTipOwner: NSObject, NSViewToolTipOwner {
    weak var controller: RunnerWindowController?
    weak var tab: TabItem?

    init(controller: RunnerWindowController, tab: TabItem) {
        self.controller = controller
        self.tab = tab
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let controller = controller, let tab = tab else { return "" }
        return controller.tooltipText(for: tab)
    }
}

// 全尺寸内容覆盖标题栏时，空白区域由自定义视图接收鼠标事件。
private final class TitlebarBackgroundView: AppearanceBackgroundView {
    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        if event.clickCount == 2 {
            // 遵循「桌面与程序坞」中窗口标题栏连按的系统设置。
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action.lowercased() {
            case "maximize": window.performZoom(nil)
            case "minimize": window.performMiniaturize(nil)
            default: break
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

// MARK: - 运行器窗口

final class RunnerWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static let maxTabWidth: CGFloat = 150

    let appID: String
    private let appName: String
    private let homeURL: URL
    private let siteApp: WebApp

    private var window: NSWindow!
    private var topBar: NSView!
    private var tabBar: NSView!
    private var tabStack: NSStackView!
    private var tabStackWidth: NSLayoutConstraint!
    var bookmarkIcons: [String: NSImage] = [:]
    var bookmarkIconRequests: Set<String> = []
    var bookmarkIconsInFlight: Set<String> = []
    var bookmarkBar: BookmarkScrollView!
    var bookmarkBarHeight: NSLayoutConstraint!
    var bookmarkStack: NSStackView!
    private var contentHost: NSView!
    private var addressField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var homeButton: NSButton!
    private var reloadButton: NSButton!
    private var newTabButton: NSButton!

    var tabs: [TabItem] = []
    private var activeIndex = 0
    private var running = false
    private var isClamping = false
    private var changingFullScreen = false
    /// 后台标签闲置 5 分钟后卸载，切回时重新加载。
    private let backgroundTabTimeout: TimeInterval = 5 * 60
    /// 本站点窗口专属菜单，等窗口成为 key 时才挂到全局
    private var siteMenu: NSMenu?

    private var activeTab: TabItem? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex]
    }

    init(app: WebApp, url: URL) {
        self.siteApp = app
        self.appID = app.id
        self.appName = app.name
        self.homeURL = url
        super.init()
    }

    // MARK: 单宿主接口
    //
    // 站点窗口现在活在 WebHub 主进程里（Chrome 式），由 SiteWindowManager 统管。
    // 这些是它对外的把手。

    var siteAppID: String { appID }
    var siteAppName: String { appName }
    var hostWindow: NSWindow? { window }

    /// 窗口被关掉时通知 manager（manager 据此让对应的 shim 退出、收起 Dock 图标）
    var onWindowClosed: (() -> Void)?

    /// 从 Dock / 应用中心再次点进来时，把已有窗口提到前面
    func focus() {
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 生命周期

    func show() {
        buildWindow()
        buildToolbar()
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        running = true
        observeAppState()

        // 单宿主：所有站点窗口共用同一个 WKWebsiteDataStore，
        // 登录态本来就是同一份数据，不需要任何预热或同步。
        restoreTabs()

        if let runningApp = NSRunningApplication.current as NSRunningApplication? {
            if #available(macOS 14.0, *) {
                runningApp.activate()
            } else {
                runningApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    private func restoreTabs() {
        guard tabs.isEmpty else { return }
        if let session = AppStore.shared.session(for: appID), !session.urls.isEmpty {
            for (index, u) in session.urls.enumerated() {
                let title = session.titles.flatMap { index < $0.count ? $0[index] : nil }
                addTab(url: URL(string: u) ?? homeURL, activate: false, title: title)
            }
            let idx = min(max(session.activeIndex, 0), tabs.count - 1)
            selectTab(idx)
        } else {
            addTab(url: homeURL, activate: true)
        }
    }

    /// 当前屏幕的可见区域（扣掉菜单栏与 Dock）
    private func visibleScreenFrame() -> NSRect {
        (window?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func buildWindow() {
        let saved = UserDefaults.standard.dictionary(forKey: "WebHub.windowSize.\(appID)")
        let savedWidth = (saved?["width"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let savedHeight = (saved?["height"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let savedX = (saved?["x"] as? Double).flatMap { $0.isFinite ? $0 : nil }
        let savedY = (saved?["y"] as? Double).flatMap { $0.isFinite ? $0 : nil }
        let savedFrame: NSRect? = {
            guard let x = savedX, let y = savedY, let width = savedWidth, let height = savedHeight else { return nil }
            return NSRect(x: x, y: y, width: width, height: height)
        }()
        // 优先使用原窗口所在屏幕；显示器移除后回退到当前主屏幕。
        let screen = savedFrame.flatMap { frame in
            NSScreen.screens.filter { frame.intersects($0.visibleFrame) }.max { left, right in
                let a = frame.intersection(left.visibleFrame)
                let b = frame.intersection(right.visibleFrame)
                return a.width * a.height < b.width * b.height
            }
        }
        let visible = screen?.visibleFrame ?? visibleScreenFrame()
        let width = min(max(760, savedWidth ?? 1200), max(1, savedWidth == nil ? visible.width - 80 : visible.width))
        let height = min(max(480, savedHeight ?? 800), max(1, savedHeight == nil ? visible.height - 80 : visible.height))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = appName
        // ⚠️ ARC 下必须关掉：默认 true 时窗口 close 后会被系统 release 一次，
        // 而 controller 仍持有 window 引用 → 变成野指针，再访问 isVisible 就 SIGSEGV。
        // 这是「关掉一个站点窗口后偶发崩溃」的根源。
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: min(760, width), height: min(480, height))
        window.maxSize = NSSize(width: visible.width, height: visible.height)
        window.center()
        if let frame = savedFrame {
            let x = min(max(frame.minX, visible.minX), visible.maxX - width)
            let y = min(max(frame.minY, visible.minY), visible.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }
        window.delegate = self

        let root = AppearanceBackgroundView(backgroundColor: .windowBackgroundColor)
        window.contentView = root

        // 工具栏（标签栏下面一行）
        let topBar = AppearanceBackgroundView(backgroundColor: .controlBackgroundColor)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)
        self.topBar = topBar

        // 标签栏（最顶）
        tabBar = TitlebarBackgroundView(backgroundColor: .controlBackgroundColor)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)

        tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .centerY
        tabStack.distribution = .fillEqually
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        // 标签变多时允许压缩，绝不让标签栏把窗口往宽撑
        tabStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabStack.setHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addSubview(tabStack)
        tabStackWidth = tabStack.widthAnchor.constraint(equalToConstant: 0)
        tabStackWidth.isActive = true

        bookmarkBar = BookmarkScrollView()
        bookmarkBar.onBookmarkDrop = { [weak self] id, index in
            self?.reorderBookmark(id, to: index)
        }
        bookmarkBar.translatesAutoresizingMaskIntoConstraints = false
        bookmarkBar.hasHorizontalScroller = true
        bookmarkBar.autohidesScrollers = true
        bookmarkBar.drawsBackground = false
        root.addSubview(bookmarkBar)
        bookmarkStack = NSStackView()
        bookmarkStack.orientation = .horizontal
        bookmarkStack.alignment = .centerY
        bookmarkStack.spacing = 6
        bookmarkBar.documentView = bookmarkStack
        bookmarkBarHeight = bookmarkBar.heightAnchor.constraint(equalToConstant: 0)
        refreshBookmarks()

        // 内容区
        contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)

        NSLayoutConstraint.activate([
            // 标签栏在最顶（让开红绿灯）
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 38),

            // 工具栏（后退/前进/主页/刷新 + 地址栏）在标签栏下面
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48),

            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 84),
            tabStack.widthAnchor.constraint(lessThanOrEqualTo: tabBar.widthAnchor, constant: -94),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -10),
            tabStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor, constant: 2),

            bookmarkBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bookmarkBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bookmarkBar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            bookmarkBarHeight,
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: bookmarkBar.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildToolbar() {
        guard let topBar = self.topBar else { return }

        backButton = toolbarButton("chevron.left", WebHubLanguage.text("Back"), #selector(goBack))
        forwardButton = toolbarButton("chevron.right", WebHubLanguage.text("Forward"), #selector(goForward))
        homeButton = toolbarButton("house", WebHubLanguage.text("Home"), #selector(goHome))
        reloadButton = toolbarButton("arrow.clockwise", WebHubLanguage.text("Reload"), #selector(reload))
        newTabButton = toolbarButton("plus", WebHubLanguage.text("Duplicate Current Tab"), #selector(newTab))

        let buttons = [backButton!, forwardButton!, homeButton!, reloadButton!]
        for b in buttons { topBar.addSubview(b) }

        addressField = CopyableTextField()
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = NSFont.systemFont(ofSize: 12.5)
        addressField.textColor = .secondaryLabelColor
        addressField.isEditable = false
        addressField.isSelectable = true
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        // 不加这两行，NSTextField 会按 URL 全长索要宽度，把窗口顶得比屏幕还宽
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addSubview(addressField)

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(newTabButton)

        var constraints: [NSLayoutConstraint] = [
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ]
        var prev: NSView = backButton
        for b in buttons.dropFirst() {
            constraints.append(b.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 6))
            constraints.append(b.centerYAnchor.constraint(equalTo: topBar.centerYAnchor))
            prev = b
        }
        constraints += [
            newTabButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            newTabButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -10),
            addressField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ]
        NSLayoutConstraint.activate(constraints)

        updateToolbarState()
    }

    private func toolbarButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        }
        b.imagePosition = .imageOnly
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.target = self
        b.action = action
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return b
    }

    // MARK: 标签管理

    @discardableResult
    func addTab(url: URL, activate: Bool, title: String? = nil) -> TabItem {
        let savedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = TabItem(title: (savedTitle?.isEmpty == false ? savedTitle : nil) ?? url.host ?? WebHubLanguage.text("Loading…"), url: url)
        tabs.append(tab)
        if activate {
            selectTab(tabs.count - 1)
        } else {
            rebuildTabBar()
        }
        return tab
    }

    private func loadTab(_ tab: TabItem) -> WKWebView {
        if let webView = tab.webView { return webView }
        let cfg = WKWebViewConfiguration()
        // 共享数据仓库：所有站点窗口互通 cookie / localStorage → 共享登录态
        cfg.websiteDataStore = SharedStorage.dataStore(for: siteApp)
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 自动填充脚本
        let host = tab.url.host ?? ""
        cfg.userContentController.addUserScript(AutofillScript.make(host: host))
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.faviconObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        cfg.userContentController.add(self, name: "autofill")
        cfg.userContentController.add(self, name: "tab")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.translatesAutoresizingMaskIntoConstraints = false

        tab.webView = wv
        tab.titleObservation = wv.observe(\.title, options: [.new]) { [weak self, weak tab] webView, _ in
            guard let self = self, let tab = tab,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let updated = title, !updated.isEmpty else { return }
            guard tab.title != updated else { return }
            tab.title = updated
            if self.activeTab === tab { self.window.title = updated }
            self.rebuildTabBar()
            self.persistSession()
        }
        tab.urlObservation = wv.observe(\.url, options: [.new]) { [weak self, weak tab, weak wv] _, _ in
            DispatchQueue.main.async { [weak self, weak tab, weak wv] in
                guard let self = self, let tab = tab, let webView = wv,
                      self.tabs.contains(where: { $0 === tab }), tab.webView === webView,
                      let url = webView.url else { return }
                tab.url = url
                if self.activeTab === tab {
                    self.updateAddress()
                    self.updateToolbarState()
                }
                self.persistSession()
            }
        }

        wv.load(URLRequest(url: tab.url))
        return wv
    }

    private func unloadTab(_ tab: TabItem) {
        tab.unloadWork?.cancel()
        tab.unloadWork = nil
        guard let webView = tab.webView else { return }
        tab.url = webView.url ?? tab.url
        tab.titleObservation?.invalidate()
        tab.titleObservation = nil
        tab.urlObservation?.invalidate()
        tab.urlObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "autofill")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tab")
        webView.removeFromSuperview()
        tab.webView = nil
        tab.unloadDeadline = nil
    }

    private func scheduleTabUnload(_ tab: TabItem) {
        tab.unloadWork?.cancel()
        guard tab.webView != nil else { return }
        tab.unloadDeadline = Date().addingTimeInterval(backgroundTabTimeout)
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self = self, let tab = tab,
                  self.tabs.contains(where: { $0 === tab }), self.activeTab !== tab else { return }
            self.unloadTab(tab)
            self.persistSession()
        }
        tab.unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundTabTimeout, execute: work)
    }

    /// 标签关闭按钮 + 切换
    @objc private func tabClicked(_ sender: NSButton) {
        selectTab(sender.tag)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        closeTab(at: sender.tag)
    }

    @objc private func duplicateTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        addTab(url: tab.webView?.url ?? tab.url, activate: true)
        persistSession()
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index)
    }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let keptTab = tabs.first(where: { $0.id == id }) else { return }
        let otherTabs = tabs.filter { $0.id != id }
        guard !otherTabs.isEmpty else { return }

        otherTabs.forEach(unloadTab)
        tabs = [keptTab]
        activeIndex = 0
        selectTab(0)
        persistSession()
    }

    @objc private func openTabInDefaultBrowser(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(tab.webView?.url ?? tab.url)
    }

    private func tabContextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let bookmark = NSMenuItem(title: WebHubLanguage.text("Bookmark This Page"), action: #selector(bookmarkTab(_:)), keyEquivalent: "")
        bookmark.target = self
        bookmark.representedObject = id
        menu.addItem(bookmark)
        let duplicate = NSMenuItem(title: WebHubLanguage.text("Duplicate Tab"), action: #selector(duplicateTabFromMenu(_:)), keyEquivalent: "")
        duplicate.target = self
        duplicate.representedObject = id
        menu.addItem(duplicate)
        let openInBrowser = NSMenuItem(title: WebHubLanguage.text("Open in Default Browser"), action: #selector(openTabInDefaultBrowser(_:)), keyEquivalent: "")
        openInBrowser.target = self
        openInBrowser.representedObject = id
        menu.addItem(openInBrowser)
        menu.addItem(NSMenuItem.separator())
        let closeOthers = NSMenuItem(title: WebHubLanguage.text("Close Other Tabs"), action: #selector(closeOtherTabsFromMenu(_:)), keyEquivalent: "")
        closeOthers.target = self
        closeOthers.representedObject = id
        closeOthers.isEnabled = tabs.count > 1
        menu.addItem(closeOthers)
        let close = NSMenuItem(title: WebHubLanguage.text("Close Tab"), action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        menu.addItem(close)
        return menu
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let previous = activeTab
        let tab = tabs[index]
        if let previous = previous, previous !== tab { scheduleTabUnload(previous) }
        activeIndex = index
        tab.unloadWork?.cancel()
        tab.unloadWork = nil
        tab.unloadDeadline = nil

        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let webView = loadTab(tab)
        // WebKit 停靠检查器时会调整网页视图的布局；固定四边约束会遮住检查器。
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = contentHost.bounds
        webView.autoresizingMask = [.width, .height]
        contentHost.addSubview(webView)

        rebuildTabBar()
        updateAddress()
        updateToolbarState()
        window.title = tab.title
        persistSession()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let selected = activeTab
        let tab = tabs.remove(at: index)
        unloadTab(tab)

        // 最后一个标签关掉 = 关窗口；applicationShouldTerminateAfterLastWindowClosed
        // 会让整个进程一起退出，Dock 图标也随之消失
        if tabs.isEmpty {
            clearSession()
            window.performClose(nil)
            if !window.isVisible { return }
            // performClose 被系统拒掉时的兜底，避免留下一个空窗口
            addTab(url: homeURL, activate: true)
            return
        }

        let newIndex = selected.flatMap { selected in tabs.firstIndex(where: { $0 === selected }) } ?? min(index, tabs.count - 1)
        activeIndex = newIndex
        selectTab(newIndex)
        persistSession()
    }

    /// 标签被关光：下次打开应该回到主页，而不是恢复上一次那批页面
    private func clearSession() {
        AppStore.shared.saveSession(TabSession(urls: [], activeIndex: 0), for: appID)
    }

    private func rebuildTabBar() {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (i, tab) in tabs.enumerated() {
            let holder = AppearanceBackgroundView(backgroundColor: i == activeIndex
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22) : .clear)
            holder.layer?.cornerRadius = 7
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.menu = tabContextMenu(for: tab.id)

            // 标题和图标按钮之间、标签两侧的留白也要能切换标签。
            let selectionButton = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            selectionButton.tag = i
            selectionButton.menu = tabContextMenu(for: tab.id)
            selectionButton.isBordered = false
            selectionButton.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(selectionButton)

            let faviconButton = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            faviconButton.tag = i
            faviconButton.menu = tabContextMenu(for: tab.id)
            faviconButton.isBordered = false
            faviconButton.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: WebHubLanguage.text("Website"))
            faviconButton.imagePosition = .imageOnly
            faviconButton.imageScaling = .scaleProportionallyDown
            faviconButton.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(faviconButton)

            let titleBtn = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            titleBtn.tag = i
            titleBtn.menu = tabContextMenu(for: tab.id)
            titleBtn.isBordered = false
            titleBtn.alignment = .left
            titleBtn.font = NSFont.systemFont(ofSize: 12, weight: i == activeIndex ? .medium : .regular)
            titleBtn.contentTintColor = i == activeIndex ? .labelColor : .secondaryLabelColor
            titleBtn.lineBreakMode = .byTruncatingTail
            // 标签标题同样要允许压缩，否则标签一多就把窗口撑宽
            titleBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleBtn.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(titleBtn)

            let closeBtn = NSButton(title: "", target: self, action: #selector(closeTabClicked(_:)))
            closeBtn.tag = i
            closeBtn.menu = tabContextMenu(for: tab.id)
            closeBtn.isBordered = false
            if #available(macOS 11.0, *) {
                closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: WebHubLanguage.text("Close Tab"))
            }
            closeBtn.contentTintColor = .tertiaryLabelColor
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(closeBtn)
            holder.removeAllToolTips()
            let tooltipOwner = TabToolTipOwner(controller: self, tab: tab)
            tab.tooltipOwner = tooltipOwner
            holder.addToolTip(NSRect(x: 0, y: 0, width: Self.maxTabWidth, height: 26), owner: tooltipOwner, userData: nil)

            let preferredTabWidth = holder.widthAnchor.constraint(equalToConstant: Self.maxTabWidth)
            // 空间充足时先扩展标签，窗口变窄或标签过多时再压缩。
            preferredTabWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                preferredTabWidth,
                holder.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTabWidth),
                holder.heightAnchor.constraint(equalToConstant: 26),
                selectionButton.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                selectionButton.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                selectionButton.topAnchor.constraint(equalTo: holder.topAnchor),
                selectionButton.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                faviconButton.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 7),
                faviconButton.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                faviconButton.widthAnchor.constraint(equalToConstant: 20),
                faviconButton.heightAnchor.constraint(equalToConstant: 20),
                titleBtn.leadingAnchor.constraint(equalTo: faviconButton.trailingAnchor, constant: 4),
                titleBtn.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                titleBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -4),
                closeBtn.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -5),
                closeBtn.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 14)
            ])

            tabStack.addArrangedSubview(holder)
            // 每个标签平分可用宽度，避免 NSStackView 将内容绘制到自身边界之外。
            holder.widthAnchor.constraint(equalTo: tabStack.widthAnchor, multiplier: 1 / CGFloat(tabs.count), constant: -tabStack.spacing * CGFloat(tabs.count - 1) / CGFloat(tabs.count)).isActive = true
        }
        updateTabStackWidth()
    }

    private func updateTabStackWidth() {
        guard tabStackWidth != nil, tabBar != nil else { return }
        let available = max(0, tabBar.bounds.width - 94)
        let preferred = CGFloat(tabs.count) * Self.maxTabWidth + CGFloat(max(tabs.count - 1, 0)) * tabStack.spacing
        tabStackWidth.constant = min(available, preferred)
    }

    fileprivate func tooltipText(for tab: TabItem) -> String {
        var tooltip = tab.title
        if tab.webView != nil, tab !== activeTab, let deadline = tab.unloadDeadline {
            let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            tooltip += WebHubLanguage.format("\nPage unloads in %@", "\(seconds / 60):\(String(format: "%02d", seconds % 60))")
        }
        return tooltip
    }

    private static let faviconObserverScript = """
    (() => {
      const send = () => {
        const links = Array.from(document.querySelectorAll('link[rel]'))
          .filter(link => /(^|\\s)(icon|shortcut icon|apple-touch-icon)(\\s|$)/i.test(link.rel) && link.href);
        const link = links.find(item => /apple-touch-icon/i.test(item.rel)) || links[0];
        if (link && window.webkit?.messageHandlers?.tab) {
          window.webkit.messageHandlers.tab.postMessage({type: 'favicon', url: link.href});
        }
      };
      window.__webhubRefreshFavicon = send;
      send();
      new MutationObserver(send).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, attributeFilter: ['rel', 'href']
      });
    })();
    """

    private func updateFavicon(for webView: WKWebView, url: String) {
        guard let tab = tabs.first(where: { $0.webView === webView }),
              let iconURL = URL(string: url),
              ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { return }
        let requestedURL = iconURL.absoluteString
        let pageURL = webView.url?.absoluteString
        tab.faviconURL = requestedURL
        IconFetcher.fetchIcon(from: requestedURL) { [weak self, weak tab, weak webView] png in
            guard let self = self, let tab = tab, let webView = webView,
                  self.tabs.contains(where: { $0 === tab }), tab.webView === webView,
                  tab.faviconURL == requestedURL else { return }
            tab.favicon = png.flatMap(NSImage.init(data:))
            self.rebuildTabBar()
            if let png = png, let pageURL = pageURL, webView.url?.absoluteString == pageURL {
                self.updateBookmarkIcon(png, for: pageURL)
            }
        }
    }

    private func updateAddress() {
        guard let tab = activeTab else { return }
        addressField.stringValue = tab.webView?.url?.absoluteString ?? tab.url.absoluteString
    }

    private func updateToolbarState() {
        let wv = activeTab?.webView
        backButton?.isEnabled = wv?.canGoBack ?? false
        forwardButton?.isEnabled = wv?.canGoForward ?? false
    }

    func persistSession() {
        let urls = tabs.map { $0.webView?.url?.absoluteString ?? $0.url.absoluteString }
        guard !urls.isEmpty else { return }
        AppStore.shared.saveSession(TabSession(urls: urls, activeIndex: activeIndex, titles: tabs.map(\.title)), for: appID)
    }

    // MARK: 动作

    @objc private func goBack() { activeTab?.webView?.goBack() }
    @objc private func goForward() { activeTab?.webView?.goForward() }
    @objc private func goHome() { activeTab?.webView?.load(URLRequest(url: homeURL)) }
    @objc private func reload() {
        guard let wv = activeTab?.webView else { return }
        if wv.url == nil { wv.load(URLRequest(url: homeURL)) } else { wv.reload() }
    }

    @objc private func newTab() {
        let url = activeTab.map { $0.webView?.url ?? $0.url } ?? homeURL
        addTab(url: url, activate: true)
        persistSession()
    }

    @objc private func closeCurrentTab() {
        closeTab(at: activeIndex)
    }

    // MARK: 站点级「退出 / 隐藏 / 关于」
    //
    // 单宿主下这些动作只影响当前站点窗口：关掉它 = 该站点的 shim 退出、
    // Dock 图标消失，其他站点窗口与 WebHub 主进程完全不受影响。
    // 要退出整个 WebHub（连带所有站点），只有在应用中心窗口里 Cmd+Q。

    @objc private func closeSite() {
        guard let w = window else { return }
        w.performClose(nil)
    }

    @objc private func hideSite() {
        window?.orderOut(nil)
    }

    @objc private func aboutSite() {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = homeURL.absoluteString
        alert.addButton(withTitle: WebHubLanguage.text("OK"))
        alert.runModal()
    }

    private func observeAppState() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func appWillTerminate() {
        persistWindowFrame()
        persistSession()
    }

    private func persistWindowFrame() {
        guard let window = window, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set(["x": Double(frame.minX), "y": Double(frame.minY),
                                   "width": Double(frame.width), "height": Double(frame.height)],
                                  forKey: "WebHub.windowSize.\(appID)")
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⚠️ 单宿主（Chrome 式）：所有站点窗口共享同一个 NSApplication。
        // 所以这里的「隐藏 / 退出」**绝不能**用 NSApplication.hide/terminate ——
        // 那会把整个 WebHub 连同其他站点一起收掉。必须降级成「只作用于本窗口」。
        appMenu.addItem(withTitle: WebHubLanguage.format("About %@", appName), action: #selector(aboutSite), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: WebHubLanguage.format("Hide %@", appName), action: #selector(hideSite), keyEquivalent: "h")
        appMenu.addItem(withTitle: WebHubLanguage.format("Quit %@", appName), action: #selector(closeSite), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = makeEditMenu()
        mainMenu.addItem(editItem)

        let navItem = NSMenuItem()
        let navMenu = NSMenu(title: WebHubLanguage.text("Navigation"))
        navMenu.addItem(withTitle: WebHubLanguage.text("Back"), action: #selector(goBack), keyEquivalent: "[")
        navMenu.addItem(withTitle: WebHubLanguage.text("Forward"), action: #selector(goForward), keyEquivalent: "]")
        navMenu.addItem(withTitle: WebHubLanguage.text("Home"), action: #selector(goHome), keyEquivalent: "H")
        navMenu.addItem(withTitle: WebHubLanguage.text("Reload"), action: #selector(reload), keyEquivalent: "r")
        navMenu.addItem(NSMenuItem.separator())
        navMenu.addItem(withTitle: WebHubLanguage.text("Duplicate Current Tab"), action: #selector(newTab), keyEquivalent: "t")
        navMenu.addItem(withTitle: WebHubLanguage.text("Close Tab"), action: #selector(closeCurrentTab), keyEquivalent: "w")
        navItem.submenu = navMenu
        mainMenu.addItem(navItem)

        mainMenu.addItem(LanguageMenu.shared.makeItem())
        mainMenu.addItem(AppearanceMenu.shared.makeItem())

        // 单宿主下所有站点窗口共享同一个 NSApplication：
        // 不能在这里直接抢全局 mainMenu，否则后开的站点会把前面的菜单顶掉。
        // 改为记下来，等本窗口成为 key window 时再切换（见 windowDidBecomeKey）。
        siteMenu = mainMenu
        if window?.isKeyWindow == true {
            NSApplication.shared.mainMenu = mainMenu
        }
    }

    /// 站点菜单里原来没有「编辑」，导致 Cmd+C / Cmd+V 这些依赖菜单项的快捷键不生效
    /// ——地址栏和网页里选中的文字都复制不出来。标准 Edit 菜单补齐这一步。
    /// target 留空走响应链，落到当前第一响应者（field editor 或 WKWebView）。
    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: WebHubLanguage.text("Edit"))
        menu.addItem(withTitle: WebHubLanguage.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: WebHubLanguage.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: WebHubLanguage.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: WebHubLanguage.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: WebHubLanguage.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = NSMenuItem(title: WebHubLanguage.text("Paste and Match Style"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pastePlain)
        menu.addItem(withTitle: WebHubLanguage.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    // MARK: WKNavigationDelegate

    /// 本站点的主机名（用于判断链接是否「出站」）
    private var siteHost: String { (homeURL.host ?? "").lowercased() }

    /// 归一化主机名：小写 + 去掉末尾的点
    private static func normalizedHost(_ host: String) -> String {
        var result = host.lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// 当前站点主机和配置的支持域名留在 WebHub；其余域名交给默认浏览器。
    private func isSameSite(_ host: String) -> Bool {
        let target = Self.normalizedHost(host)
        let site = Self.normalizedHost(siteHost)
        guard !target.isEmpty else { return false }
        if !site.isEmpty && target == site { return true }
        let configuredApp = AppStore.shared.apps.first(where: { $0.id == appID }) ?? siteApp
        return (configuredApp.supportedDomains ?? []).contains { rawDomain in
            let domain = Self.normalizedHost(rawDomain)
            return !domain.isEmpty && (target == domain || target.hasSuffix(".\(domain)"))
        }
    }

    // MARK: 中转链接解包

    /// 站点常把出站链接包一层自己的中转页，例如腾讯文档：
    ///   https://docs.qq.com/scenario/link.html?url=https%3A%2F%2Fexample.com
    /// 剥掉这层再判断，否则默认浏览器里也只是停在别人的中转页上。
    private static let redirectParamNames: Set<String> = [
        "url", "u", "link", "target", "to", "goto", "redirect",
        "redirect_uri", "redirect_url", "next", "q", "dest", "destination",
    ]

    /// 单层解包：查询串里哪个参数的值本身是 http(s) 绝对地址，就把它当作真实目标
    private static func redirectTarget(of url: URL) -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        for item in comps.queryItems ?? [] {
            guard redirectParamNames.contains(item.name.lowercased()),
                  let raw = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let inner = URL(string: raw),
                  let scheme = inner.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = inner.host, !host.isEmpty
            else { continue }
            return inner
        }
        return nil
    }

    /// 逐层剥到真实地址（限制层数并防环）
    private static func unwrapRedirects(_ url: URL) -> URL {
        var current = url
        var visited: Set<String> = [url.absoluteString]
        for _ in 0..<3 {
            guard let next = redirectTarget(of: current),
                  !visited.contains(next.absoluteString) else { break }
            visited.insert(next.absoluteString)
            current = next
        }
        return current
    }

    /// 该用默认浏览器打开的地址；nil 表示留在窗口内
    private func externalDestination(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // mailto: / tel: / 自定义协议 —— 本进程处理不了，交给系统更合适
        if scheme != "http" && scheme != "https" { return url }
        let target = Self.unwrapRedirects(url)
        guard let host = target.host, !host.isEmpty else { return nil }
        return isSameSite(host) ? nil : target
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 只拦「用户真的要去别处」的情况：点击链接，或者要开新窗口。
        // 自动重定向（SSO 回调、登录跳转）不拦 —— 否则会在浏览器里莫名蹦出页面。
        let isUserClick = navigationAction.navigationType == .linkActivated
        let wantsNewWindow = navigationAction.targetFrame == nil

        if let url = navigationAction.request.url,
           let destination = externalDestination(for: url),
           isUserClick || wantsNewWindow {
            // 中转链接直接开真实地址，别让浏览器停在包装页上
            NSWorkspace.shared.open(destination)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateToolbarState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.favicon = nil
            tab.faviconURL = nil
            rebuildTabBar()
        }
        updateToolbarState()
        updateAddress()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateToolbarState()
        updateAddress()

        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if let host = webView.url?.host {
            tab.title = webView.title?.isEmpty == false ? webView.title! : host
        }
        if tabs.indices.contains(activeIndex), tabs[activeIndex].webView === webView {
            window.title = tab.title
        }
        webView.evaluateJavaScript("window.__webhubRefreshFavicon?.()", completionHandler: nil)
        rebuildTabBar()
        persistSession()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        updateAddress()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank 之类：站内开新标签页，站外交给默认浏览器
        if let url = navigationAction.request.url {
            if let destination = externalDestination(for: url) {
                NSWorkspace.shared.open(destination)
            } else {
                // 站内中转页也直接落到真实地址，省一次跳转
                addTab(url: Self.unwrapRedirects(url), activate: true)
                persistSession()
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        if ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            NSLog("ATS blocked: %@", webView.url?.absoluteString ?? "")
        }
    }

    // 支持文件上传
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = window else {
            completionHandler(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.prompt = WebHubLanguage.text("Choose")
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // 支持 alert/confirm
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: WebHubLanguage.text("OK"))
        alert.runModal()
        completionHandler()
    }

    // MARK: 消息

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "tab",
           message.frameInfo.isMainFrame,
           let body = message.body as? [String: Any],
           body["type"] as? String == "favicon",
           let url = body["url"] as? String,
           let webView = message.webView {
            updateFavicon(for: webView, url: url)
            return
        }
        guard message.name == "autofill",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let host = (body["host"] as? String) ?? activeTab?.webView?.url?.host ?? ""
        let senderWebView = message.webView
        let store = CredentialStore.shared

        switch type {
        case "requestCredential":
            // 页面找到了登录框 → 用已保存的凭据自动填充
            guard let found = store.find(forHost: host, appID: siteApp.usesIsolatedLogin ? appID : nil) else { return }
            let user = AutofillScript.jsLiteral(found.credential.username)
            let pass = AutofillScript.jsLiteral(found.credential.password)
            senderWebView?.evaluateJavaScript(
                "window.__webhubFill(\(user), \(pass))", completionHandler: nil)

        case "saveCredential":
            guard let username = body["username"] as? String,
                  let password = body["password"] as? String,
                  !username.isEmpty, !password.isEmpty else { return }
            // 用根域保存，这样同域下所有子系统都能填
            let key = CredentialStore.registrableDomain(host)
            store.save(host: key, username: username, password: password, appID: siteApp.usesIsolatedLogin ? appID : nil)
            NSLog("WebHub: 已保存 \(key) 的登录凭据")

        default:
            break
        }
    }
}

extension RunnerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        persistWindowFrame()
        persistSession()
        NotificationCenter.default.removeObserver(self)
        for tab in tabs { unloadTab(tab) }
        tabs.removeAll()
        // 单宿主：窗口没了就告诉 manager，让它收掉本站点的 shim 与 Dock 图标
        onWindowClosed?()
    }

    /// 单宿主下菜单是全局的，谁成为 key window 谁切自己那份
    func windowDidBecomeKey(_ notification: Notification) {
        if let m = siteMenu, NSApplication.shared.mainMenu !== m {
            NSApplication.shared.mainMenu = m
        }
    }

    /// 无论标签栏约束还是网页想撑大窗口，都限制在当前屏幕内
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let v = sender.screen?.visibleFrame ?? visibleScreenFrame()
        return NSSize(width: min(frameSize.width, v.width),
                      height: min(frameSize.height, v.height))
    }

    func windowDidResize(_ notification: Notification) {
        updateTabStackWidth()
        guard !isClamping, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        clampFrameToScreen()
        persistWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isClamping, !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        clampFrameToScreen()
        persistWindowFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        persistWindowFrame()
        changingFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullScreen = false
        persistWindowFrame()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        changingFullScreen = false
        persistWindowFrame()
    }

    private func clampFrameToScreen() {
        guard let w = window, !isClamping else { return }
        let v = w.screen?.visibleFrame ?? visibleScreenFrame()
        let f = w.frame
        let width = min(f.size.width, v.width)
        let height = min(f.size.height, v.height)
        // 保证整个窗口都落在可见区域内（右/下边缘不越界）
        let maxX = max(v.minX, v.maxX - width)
        let maxY = max(v.minY, v.maxY - height)
        let x = min(max(f.origin.x, v.minX), maxX)
        let y = min(max(f.origin.y, v.minY), maxY)
        guard abs(x - f.origin.x) > 1 || abs(y - f.origin.y) > 1 ||
              abs(width - f.size.width) > 1 || abs(height - f.size.height) > 1 else { return }
        isClamping = true
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        isClamping = false
    }
}

/// 地址栏用的只读文本框：可选中复制，并兼容 Windows 习惯的 Ctrl+C / Ctrl+A。
/// macOS 原生只认 Cmd+C，二爷手上是 Ctrl 肌肉记忆，两个都给。
final class CopyableTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        if handleControlCombo(event) { return }
        super.keyDown(with: event)
    }

    /// 进入选中态后按键是发给 field editor（NSTextView）的，keyDown 收不到，
    /// 所以在 performKeyEquivalent 里再拦一道。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleControlCombo(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Ctrl+C 复制、Ctrl+A 全选（Windows 习惯；不带 Cmd/Alt，免得和系统组合键打架）
    private func handleControlCombo(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
              isActive,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            copySelection()
            return true
        case "a":
            selectAllInEditor()
            return true
        default:
            return false
        }
    }

    /// 鼠标右键菜单里给一个「复制地址」，省得先拖选
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: WebHubLanguage.text("Copy Address"), action: #selector(copyAll(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        return menu
    }

    @objc private func copyAll(_ sender: Any?) {
        guard let editor = ensureEditor() else { return }
        editor.selectAll(nil)
        editor.copy(nil)
    }

    private func copySelection() {
        guard let editor = ensureEditor() as? NSTextView else { return }
        // 没有选区时按「全选复制」处理，符合地址栏的使用直觉
        if editor.selectedRange().length == 0 { editor.selectAll(nil) }
        editor.copy(nil)
    }

    private func selectAllInEditor() {
        guard let editor = ensureEditor() else { return }
        editor.selectAll(nil)
    }

    /// 只有地址栏自己在编辑态时才吃键，别抢网页里的按键
    private var isActive: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        if let editor = currentEditor(), responder === editor { return true }
        return false
    }

    /// 还没进入编辑态时先把自己设成第一响应者，否则拿不到 field editor
    private func ensureEditor() -> NSText? {
        if currentEditor() == nil, let w = window {
            w.makeFirstResponder(self)
        }
        return currentEditor()
    }
}
