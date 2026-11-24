import AppKit
import WebKit
import ObjectiveC

// MARK: - 单站点的标签页

final class TabItem {
    let id = UUID()
    var webView: WKWebView?
    var title: String
    var url: URL
    var favicon: NSImage?
    var faviconURL: String?
    var faviconRequestID = UUID()
    weak var faviconButton: NSButton?
    var titleObservation: NSKeyValueObservation?
    var urlObservation: NSKeyValueObservation?
    var unloadWork: DispatchWorkItem?
    var unloadDeadline: Date?
    var isUnloadDeferred = false
    let mediaMonitor = TabMediaMonitor()
    weak var popupOpener: TabItem?
    fileprivate var tooltipOwner: TabToolTipOwner?

    init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

private final class TabToolTipOwner: NSObject, NSViewToolTipOwner {
    weak var controller: SiteWindowController?
    weak var tab: TabItem?

    init(controller: SiteWindowController, tab: TabItem) {
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
    weak var selectedTab: NSView?
    weak var tabStack: NSStackView?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let tabStack {
            SiteChromeColors.tabSeparator.setFill()
            for (left, right) in zip(tabStack.arrangedSubviews, tabStack.arrangedSubviews.dropFirst()) {
                guard left !== selectedTab, right !== selectedTab else { continue }
                let leftFrame = convert(left.bounds, from: left)
                let rightFrame = convert(right.bounds, from: right)
                let separator = NSRect(x: (leftFrame.maxX + rightFrame.minX) / 2 - 0.5,
                                       y: leftFrame.midY - 10, width: 1, height: 20)
                NSBezierPath(roundedRect: separator, xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
        guard let selectedTab, selectedTab.superview != nil else { return }
        let frame = convert(selectedTab.bounds, from: selectedTab)
        let radius: CGFloat = 10
        SiteChromeColors.selectedTab.setFill()
        let left = NSBezierPath()
        left.move(to: NSPoint(x: frame.minX - radius, y: frame.minY))
        left.curve(to: NSPoint(x: frame.minX, y: frame.minY + radius), controlPoint1: NSPoint(x: frame.minX - radius * 0.45, y: frame.minY), controlPoint2: NSPoint(x: frame.minX, y: frame.minY + radius * 0.45))
        left.line(to: NSPoint(x: frame.minX, y: frame.minY))
        left.close()
        left.fill()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: frame.maxX, y: frame.minY + radius))
        right.curve(to: NSPoint(x: frame.maxX + radius, y: frame.minY), controlPoint1: NSPoint(x: frame.maxX, y: frame.minY + radius * 0.45), controlPoint2: NSPoint(x: frame.maxX + radius * 0.45, y: frame.minY))
        right.line(to: NSPoint(x: frame.maxX, y: frame.minY))
        right.close()
        right.fill()
    }

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

// MARK: - 站点窗口

final class SiteWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSSearchFieldDelegate, NSTextFieldDelegate {
    private static let maxTabWidth: CGFloat = 150

    let appID: String
    private let appName: String
    private let homeURL: URL
    private let siteApp: WebApp
    private lazy var websiteDataStore: WKWebsiteDataStore = {
        let store = SharedStorage.dataStore(for: siteApp)
        SharedStorage.applyProxy(networkProxy, to: store)
        return store
    }()

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
    private var findBar: NSView!
    private var findField: NSSearchField!
    private var findStatus: NSTextField!
    private var findRequestID = UUID()
    private var addressField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var homeButton: NSButton!
    private var reloadButton: NSButton!
    private var newTabButton: NSButton!

    var tabs: [TabItem] = []
    private var activeIndex = 0
    /// 按最近展示顺序记录标签，关闭当前标签时优先回到上一个展示的标签。
    private var tabActivationHistory: [TabItem] = []
    private var running = false
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
    var networkProxy: NetworkProxyProfile? { NetworkProxyStore.shared.profile }

    func refreshNetworkProxy() {
        SharedStorage.applyProxy(networkProxy, to: websiteDataStore)
    }

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
        }
        if let homeIndex = tabs.firstIndex(where: { isHomeURL($0.url) }) {
            selectTab(homeIndex)
        } else {
            addTab(url: homeURL, activate: true, at: 0)
        }
    }

    private func isHomeURL(_ url: URL) -> Bool {
        guard var candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var home = URLComponents(url: homeURL, resolvingAgainstBaseURL: false) else { return url == homeURL }
        // 根地址导航后通常会补上斜杠，匹配主页时将两种写法视为相同地址。
        if candidate.path.isEmpty { candidate.path = "/" }
        if home.path.isEmpty { home.path = "/" }
        return candidate == home
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
        // 仅在创建时约束到目标屏幕；后续交由系统处理拖动和缩放。
        let x = min(max(savedFrame?.minX ?? visible.midX - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(savedFrame?.minY ?? visible.midY - height / 2, visible.minY), visible.maxY - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        window.delegate = self

        let root = AppearanceBackgroundView(backgroundColor: SiteChromeColors.toolbar)
        window.contentView = root

        // 工具栏（标签栏下面一行）
        let topBar = AppearanceBackgroundView(backgroundColor: SiteChromeColors.toolbar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)
        self.topBar = topBar

        // 标签栏（最顶）
        tabBar = TitlebarBackgroundView(backgroundColor: SiteChromeColors.titleBar)
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
        (tabBar as? TitlebarBackgroundView)?.tabStack = tabStack
        tabStackWidth = tabStack.widthAnchor.constraint(equalToConstant: 0)
        tabStackWidth.isActive = true
        newTabButton = toolbarButton("plus", WebHubLanguage.text("New Tab"), #selector(newTab))
        newTabButton.isBordered = false
        tabBar.addSubview(newTabButton)

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

        let findBar = AppearanceBackgroundView(backgroundColor: .controlBackgroundColor)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        root.addSubview(findBar, positioned: .above, relativeTo: contentHost)
        self.findBar = findBar
        findField = NSSearchField()
        findField.placeholderString = WebHubLanguage.text("Find in Page")
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findStatus = NSTextField(labelWithString: "")
        findStatus.textColor = .secondaryLabelColor
        let previous = NSButton(title: "‹", target: self, action: #selector(findPrevious))
        let next = NSButton(title: "›", target: self, action: #selector(findNext))
        let close = NSButton(title: "×", target: self, action: #selector(closeFindBar))
        previous.toolTip = WebHubLanguage.text("Previous Match")
        next.toolTip = WebHubLanguage.text("Next Match")
        close.toolTip = WebHubLanguage.text("Close Find")
        let findStack = NSStackView(views: [findField, findStatus, previous, next, close])
        findStack.orientation = .horizontal
        findStack.alignment = .centerY
        findStack.spacing = 6
        findStack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(findStack)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: contentHost.topAnchor),
            findBar.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findStack.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 6),
            findStack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -6),
            findField.widthAnchor.constraint(equalToConstant: 220)
        ])

        NSLayoutConstraint.activate([
            // 标签栏在最顶（让开红绿灯）
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 44),

            // 工具栏（后退/前进/主页/刷新 + 地址栏）在标签栏下面
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 42),

            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 84),
            tabStack.widthAnchor.constraint(lessThanOrEqualTo: tabBar.widthAnchor, constant: -130),
            newTabButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 4),
            newTabButton.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),

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

        let buttons = [backButton!, forwardButton!, homeButton!, reloadButton!]
        for b in buttons { topBar.addSubview(b) }

        addressField = CopyableTextField()
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.font = NSFont.systemFont(ofSize: 12.5)
        addressField.usesSingleLineMode = true
        addressField.textColor = SiteChromeColors.addressText
        addressField.backgroundColor = SiteChromeColors.address
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(openAddress)
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        // 不加这两行，NSTextField 会按 URL 全长索要宽度，把窗口顶得比屏幕还宽
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addSubview(addressField)

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
            addressField.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            addressField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 32)
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
    func addTab(url: URL, activate: Bool, title: String? = nil, at index: Int? = nil) -> TabItem {
        let savedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = TabItem(title: (savedTitle?.isEmpty == false ? savedTitle : nil) ?? url.host ?? WebHubLanguage.text("Loading…"), url: url)
        let insertionIndex = index ?? tabs.count
        if !tabs.isEmpty, insertionIndex <= activeIndex { activeIndex += 1 }
        tabs.insert(tab, at: insertionIndex)
        if activate {
            selectTab(insertionIndex)
        } else {
            rebuildTabBar()
        }
        return tab
    }

    func openBookmarkInCurrentTab(_ url: URL) {
        guard let tab = activeTab else {
            addTab(url: url, activate: true)
            persistSession()
            return
        }
        loadTab(tab).load(URLRequest(url: url))
    }

    private func loadTab(_ tab: TabItem, popupConfiguration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView = tab.webView { return webView }
        let cfg = popupConfiguration ?? WKWebViewConfiguration()
        if popupConfiguration == nil {
            cfg.websiteDataStore = websiteDataStore
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
            // WebKit 默认关闭网页元素全屏，视频播放器需要开启 Fullscreen API。
            cfg.preferences.isElementFullscreenEnabled = true
            cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        } else {
            // 保留 WebKit 为弹窗提供的关联配置，同时避免标签之间共用消息处理器。
            cfg.userContentController = WKUserContentController()
        }

        // 自动填充脚本
        let host = tab.url.host ?? ""
        cfg.userContentController.addUserScript(AutofillScript.make(host: host))
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.faviconObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        cfg.userContentController.addUserScript(VideoFullscreenGesture.userScript)
        cfg.userContentController.add(self, name: "autofill")
        cfg.userContentController.add(self, name: "tab")
        tab.mediaMonitor.install(in: cfg.userContentController)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = SafariUserAgent.value
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

        // 弹窗的原始请求由 WebKit 加载，以保留 window.opener 和表单请求。
        if popupConfiguration == nil { wv.load(URLRequest(url: tab.url)) }
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
        tab.mediaMonitor.uninstall(from: webView.configuration.userContentController)
        webView.removeFromSuperview()
        tab.webView = nil
        tab.unloadDeadline = nil
    }

    private func scheduleTabUnload(_ tab: TabItem, retrying: Bool = false) {
        tab.unloadWork?.cancel()
        guard let webView = tab.webView else { return }
        let delay = retrying ? 30 : backgroundTabTimeout
        let deadline = Date().addingTimeInterval(delay)
        tab.unloadDeadline = deadline
        tab.isUnloadDeferred = retrying
        let work = DispatchWorkItem { [weak self, weak tab, weak webView] in
            Task { @MainActor in
                guard let self, let tab, let webView, tab.webView === webView,
                      tab.unloadDeadline == deadline, self.activeTab !== tab else { return }
                let hasActiveMedia = await tab.mediaMonitor.hasActiveMedia(in: webView)
                guard tab.webView === webView, tab.unloadDeadline == deadline, self.activeTab !== tab else { return }
                let hasPopup = tab.popupOpener?.webView != nil || self.tabs.contains { $0.popupOpener === tab }
                if hasActiveMedia || webView.fullscreenState != .notInFullscreen
                    || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none || hasPopup {
                    self.scheduleTabUnload(tab, retrying: true)
                    return
                }
                self.unloadTab(tab)
                self.persistSession()
            }
        }
        tab.unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        duplicateTab(tab)
        persistSession()
    }

    private func duplicateTab(_ source: TabItem) {
        // 切换标签会移除原 WebView，必须先读取检查器的显示状态。
        let inspectorWasVisible = source.webView.map { inspectorIsVisible(for: $0) } ?? false
        let tab = addTab(url: source.webView?.url ?? source.url, activate: true, title: source.title)
        guard inspectorWasVisible, let webView = tab.webView else { return }
        // 等新 WebView 加入窗口后打开检查器，才能正确停靠到窗口。
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView, tab.webView === webView,
                  self.activeTab === tab, let inspector = self.inspector(for: webView) else { return }
            let selector = NSSelectorFromString("show")
            guard inspector.responds(to: selector) else { return }
            inspector.perform(selector)
        }
    }

    // WebKit 尚未公开控制本地检查器窗口的 API；运行时检查以兼容系统版本变化。
    private func inspector(for webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private func inspectorIsVisible(for webView: WKWebView) -> Bool {
        guard let inspector = inspector(for: webView) else { return false }
        let selector = NSSelectorFromString("isVisible")
        guard inspector.responds(to: selector), let method = class_getInstanceMethod(type(of: inspector), selector) else { return false }
        let implementation = method_getImplementation(method)
        let invoke = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return invoke(inspector, selector)
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
        if previous !== tab, !findBar.isHidden { clearFindSelection(in: previous?.webView) }
        if let previous, previous !== tab {
            previous.webView?.isHidden = true
            scheduleTabUnload(previous)
        }
        activeIndex = index
        tabActivationHistory.removeAll { $0 === tab }
        tabActivationHistory.insert(tab, at: 0)
        tab.unloadWork?.cancel()
        tab.unloadWork = nil
        tab.unloadDeadline = nil

        let webView = loadTab(tab)
        // 隐藏后台标签，保留 WebView 与窗口的关联，直到标签真正闲置。
        if webView.superview == nil {
            // WebKit 停靠检查器时会调整网页视图的布局；固定四边约束会遮住检查器。
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = contentHost.bounds
            webView.autoresizingMask = [.width, .height]
            contentHost.addSubview(webView)
        }
        webView.isHidden = false

        if !findBar.isHidden { searchPage(backwards: false) }

        rebuildTabBar()
        updateAddress(force: true)
        updateToolbarState()
        window.title = tab.title
        persistSession()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let selected = activeTab
        let tab = tabs.remove(at: index)
        tabActivationHistory.removeAll { $0 === tab }
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

        let newIndex: Int
        if selected === tab {
            // 当前标签关闭后，优先回到最近一次展示过且仍存在的标签。
            if let previous = tabActivationHistory.first(where: { previous in
                tabs.contains(where: { $0 === previous })
            }), let previousIndex = tabs.firstIndex(where: { $0 === previous }) {
                newIndex = previousIndex
            } else {
                newIndex = min(index, tabs.count - 1)
            }
        } else {
            // 关闭非当前标签时保持当前展示内容不变。
            newIndex = selected.flatMap { selected in tabs.firstIndex(where: { $0 === selected }) } ?? min(index, tabs.count - 1)
        }
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
                ? SiteChromeColors.selectedTab : .clear)
            holder.layer?.cornerRadius = 7
            holder.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
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
            tab.faviconButton = faviconButton
            updateFaviconButton(for: tab)
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
            holder.addToolTip(NSRect(x: 0, y: 0, width: Self.maxTabWidth, height: 38), owner: tooltipOwner, userData: nil)

            let preferredTabWidth = holder.widthAnchor.constraint(equalToConstant: Self.maxTabWidth)
            // 空间充足时先扩展标签，窗口变窄或标签过多时再压缩。
            preferredTabWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                preferredTabWidth,
                holder.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTabWidth),
                holder.heightAnchor.constraint(equalToConstant: 38),
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
            if i == activeIndex { (tabBar as? TitlebarBackgroundView)?.selectedTab = holder }
            // 每个标签平分可用宽度，避免 NSStackView 将内容绘制到自身边界之外。
            holder.widthAnchor.constraint(equalTo: tabStack.widthAnchor, multiplier: 1 / CGFloat(tabs.count), constant: -tabStack.spacing * CGFloat(tabs.count - 1) / CGFloat(tabs.count)).isActive = true
        }
        tabBar.needsDisplay = true
        updateTabStackWidth()
    }

    private func updateTabStackWidth() {
        guard tabStackWidth != nil, tabBar != nil else { return }
        let available = max(0, tabBar.bounds.width - 130)
        let preferred = CGFloat(tabs.count) * Self.maxTabWidth + CGFloat(max(tabs.count - 1, 0)) * tabStack.spacing
        tabStackWidth.constant = min(available, preferred)
        tabBar.needsDisplay = true
    }

    fileprivate func tooltipText(for tab: TabItem) -> String {
        var tooltip = tab.title
        if tab.webView != nil, tab !== activeTab, let deadline = tab.unloadDeadline {
            if tab.isUnloadDeferred {
                tooltip += WebHubLanguage.text("\nPage is in use. Unloading deferred.")
            } else {
                let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                tooltip += WebHubLanguage.format("\nPage unloads in %@", "\(seconds / 60):\(String(format: "%02d", seconds % 60))")
            }
        }
        return tooltip
    }

    private static let faviconObserverScript = """
    (() => {
      let lastURL = null;
      let scheduled = false;
      const send = () => {
        scheduled = false;
        const links = Array.from(document.querySelectorAll('link[rel]'))
          .filter(link => /(^|\\s)(icon|shortcut icon|apple-touch-icon)(\\s|$)/i.test(link.rel) && link.href);
        const link = links.find(item => /apple-touch-icon/i.test(item.rel)) || links[0];
        const url = link?.href || '';
        if (url !== lastURL && window.webkit?.messageHandlers?.tab) {
          lastURL = url;
          window.webkit.messageHandlers.tab.postMessage({type: 'favicon', url});
        }
      };
      window.__webhubRefreshFavicon = send;
      send();
      const hasLink = node => node.nodeType === Node.ELEMENT_NODE &&
        (node.matches('link[rel]') || node.querySelector('link[rel]'));
      new MutationObserver(records => {
        const changed = records.some(record => record.type === 'attributes'
          ? record.target.matches('link')
          : [...record.addedNodes, ...record.removedNodes].some(hasLink));
        if (changed && !scheduled) {
          scheduled = true;
          setTimeout(send, 0);
        }
      }).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, attributeFilter: ['rel', 'href']
      });
    })();
    """

    private func updateFaviconButton(for tab: TabItem) {
        tab.faviconButton?.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: WebHubLanguage.text("Website"))
    }

    private func updateFavicon(for webView: WKWebView, url: String) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if url.isEmpty {
            tab.faviconRequestID = UUID()
            tab.faviconURL = nil
            tab.favicon = nil
            updateFaviconButton(for: tab)
            return
        }
        guard tab.faviconURL != url,
              let iconURL = URL(string: url),
              ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { return }
        let requestedURL = iconURL.absoluteString
        let pageURL = webView.url?.absoluteString
        tab.faviconURL = requestedURL
        let requestID = UUID()
        tab.faviconRequestID = requestID
        IconFetcher.fetchTabIcon(from: requestedURL, proxy: networkProxy) { [weak self, weak tab, weak webView] png in
            guard let self = self, let tab = tab, let webView = webView,
                  self.tabs.contains(where: { $0 === tab }), tab.webView === webView,
                  tab.faviconRequestID == requestID else { return }
            tab.favicon = png.flatMap(NSImage.init(data:))
            self.updateFaviconButton(for: tab)
            if let png = png, let pageURL = pageURL, webView.url?.absoluteString == pageURL {
                self.updateBookmarkIcon(png, for: pageURL)
            }
        }
    }

    private func updateAddress(force: Bool = false) {
        if !force, addressField.currentEditor() != nil { return }
        guard let tab = activeTab else { return }
        let address = tab.webView?.url?.absoluteString ?? tab.url.absoluteString
        addressField.stringValue = address == "about:blank" ? "" : address
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
        addTab(url: URL(string: "about:blank")!, activate: true, title: WebHubLanguage.text("New Tab"))
        persistSession()
        window.makeFirstResponder(addressField)
    }

    @objc private func openAddress() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let address = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), url.host?.isEmpty == false else { NSSound.beep(); return }
        activeTab?.webView?.load(URLRequest(url: url))
        window.makeFirstResponder(activeTab?.webView)
    }

    @objc private func focusAddress() {
        window.makeFirstResponder(addressField)
        addressField.selectText(nil)
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
        let settingsItem = NSMenuItem(title: WebHubLanguage.text("Settings") + "…", action: #selector(LauncherAppDelegate.showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = NSApp.delegate
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
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
        navMenu.addItem(withTitle: WebHubLanguage.text("Open Address"), action: #selector(focusAddress), keyEquivalent: "l")
        navMenu.addItem(NSMenuItem.separator())
        navMenu.addItem(withTitle: WebHubLanguage.text("New Tab"), action: #selector(newTab), keyEquivalent: "t")
        navMenu.addItem(withTitle: WebHubLanguage.text("Close Tab"), action: #selector(closeCurrentTab), keyEquivalent: "w")
        navItem.submenu = navMenu
        mainMenu.addItem(navItem)

        mainMenu.addItem(ViewMenu.makeItem())

        // 单宿主下所有站点窗口共享同一个 NSApplication：
        // 不能在这里直接抢全局 mainMenu，否则后开的站点会把前面的菜单顶掉。
        // 改为记下来，等本窗口成为 key window 时再切换（见 windowDidBecomeKey）。
        siteMenu = mainMenu
        if window?.isKeyWindow == true {
            WindowHelpMenus.shared.activate(mainMenu)
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
        menu.addItem(.separator())
        let find = NSMenuItem(title: WebHubLanguage.text("Find in Page"), action: #selector(showFindBar), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)
        let next = NSMenuItem(title: WebHubLanguage.text("Next Match"), action: #selector(findNext), keyEquivalent: "g")
        next.target = self
        menu.addItem(next)
        let previous = NSMenuItem(title: WebHubLanguage.text("Previous Match"), action: #selector(findPrevious), keyEquivalent: "G")
        previous.target = self
        menu.addItem(previous)
        return menu
    }

    @objc private func showFindBar() {
        findBar.isHidden = false
        window.makeFirstResponder(findField)
        findField.selectText(nil)
    }

    @objc private func closeFindBar() {
        findRequestID = UUID()
        clearFindSelection(in: activeTab?.webView)
        findBar.isHidden = true
        findStatus.stringValue = ""
        window.makeFirstResponder(activeTab?.webView)
    }

    @objc private func findNext() {
        if findBar.isHidden { showFindBar() }
        searchPage(backwards: false)
    }
    @objc private func findPrevious() {
        if findBar.isHidden { showFindBar() }
        searchPage(backwards: true)
    }

    private func searchPage(backwards: Bool) {
        let request = UUID()
        findRequestID = request
        guard let webView = activeTab?.webView, !findField.stringValue.isEmpty else {
            findStatus.stringValue = ""
            clearFindSelection(in: activeTab?.webView)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(findField.stringValue, configuration: config) { [weak self, weak webView] result in
            guard let self, let webView else { return }
            if self.findBar.isHidden || self.activeTab?.webView !== webView {
                self.clearFindSelection(in: webView)
                return
            }
            guard self.findRequestID == request else { return }
            self.findStatus.stringValue = result.matchFound ? "" : WebHubLanguage.text("No Matches")
        }
    }

    private func clearFindSelection(in webView: WKWebView?) {
        guard let webView else { return }
        // WebKit 的查找指示器独立于 DOM 选区；系统未公开清理接口，运行时检查兼容性。
        let selector = NSSelectorFromString("_hideFindUI")
        if webView.responds(to: selector) { webView.perform(selector) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === findField else { return }
        searchPage(backwards: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === addressField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            updateAddress(force: true)
            window.makeFirstResponder(activeTab?.webView)
            return true
        }
        guard control === findField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeFindBar(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { findPrevious() } else { findNext() }
            return true
        }
        return false
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

    /// 当前站点主机和配置的支持域名留在 WebHub；* 表示允许所有域名。
    private func isSameSite(_ host: String) -> Bool {
        let target = Self.normalizedHost(host)
        let site = Self.normalizedHost(siteHost)
        guard !target.isEmpty else { return false }
        if !site.isEmpty && target == site { return true }
        let configuredApp = AppStore.shared.apps.first(where: { $0.id == appID }) ?? siteApp
        return (configuredApp.supportedDomains ?? []).contains { rawDomain in
            let domain = Self.normalizedHost(rawDomain)
            // 通配项只放开网页域名，外部应用协议仍由 externalDestination 分流。
            if domain == "*" { return true }
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
    private func externalDestination(for url: URL, unwrapRedirects: Bool = true) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme != "http" && scheme != "https" {
            // WebKit 原生协议留在内部；blob: 依赖网页上下文，单独保留。
            if WKWebView.handlesURLScheme(scheme) || scheme == "blob" { return nil }
            // mailto: / tel: / 其他外部应用协议交给系统。
            return url
        }
        let target = unwrapRedirects ? Self.unwrapRedirects(url) : url
        guard let host = target.host, !host.isEmpty else { return nil }
        return isSameSite(host) ? nil : target
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload,
           let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme == "blob" || WKWebView.handlesURLScheme(scheme) {
            decisionHandler(.download)
            return
        }
        // 只拦「用户真的要去别处」的情况：点击链接，或者要开新窗口。
        // 自动重定向（SSO 回调、登录跳转）不拦 —— 否则会在浏览器里莫名蹦出页面。
        let isUserClick = navigationAction.navigationType == .linkActivated
        let wantsNewWindow = navigationAction.targetFrame == nil
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let isWebLink = scheme == "http" || scheme == "https"
        let isExternalClick = isUserClick && (navigationAction.targetFrame?.isMainFrame == true || !isWebLink)

        if isExternalClick || wantsNewWindow,
           let url = navigationAction.request.url,
           let destination = externalDestination(for: url, unwrapRedirects: isUserClick) {
            // 中转链接直接开真实地址，别让浏览器停在包装页上
            NSWorkspace.shared.open(destination)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response as? HTTPURLResponse
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let isDownload = disposition == "attachment" || (navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType)
        decisionHandler(isDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        SiteDownloads.shared.start(download, in: window)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        SiteDownloads.shared.start(download, in: window)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateToolbarState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.webView === webView }) {
            tab.favicon = nil
            tab.faviconURL = nil
            tab.faviconRequestID = UUID()
            rebuildTabBar()
        }
        updateToolbarState()
        updateAddress()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateToolbarState()
        updateAddress()

        if !findBar.isHidden, activeTab?.webView === webView { searchPage(backwards: false) }

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
        let url = navigationAction.request.url ?? URL(string: "about:blank")!
        if let destination = externalDestination(for: url, unwrapRedirects: navigationAction.navigationType == .linkActivated) {
            NSWorkspace.shared.open(destination)
            return nil
        }

        let tab = addTab(url: url, activate: false)
        // 脚本弹窗可能要在登录后通知父页面，关联仍存在时不要卸载其中之一。
        if navigationAction.navigationType == .other || navigationAction.navigationType == .formSubmitted {
            tab.popupOpener = tabs.first { $0.webView === webView }
        }
        let popup = loadTab(tab, popupConfiguration: configuration)
        selectTab(tabs.count - 1)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        closeTab(at: index)
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

    private func scriptDialog(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let origin = frame.securityOrigin
        let source = origin.host.isEmpty ? appName : origin.host
        alert.messageText = WebHubLanguage.format("Message from %@", source)
        alert.informativeText = message
        alert.addButton(withTitle: WebHubLanguage.text("OK"))
        return alert
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window else { completionHandler(); return }
        scriptDialog(message, from: frame).beginSheetModal(for: webView.window ?? window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window else { completionHandler(false); return }
        let alert = scriptDialog(message, from: frame)
        alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
        alert.beginSheetModal(for: webView.window ?? window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let alert = scriptDialog(prompt, from: frame)
        alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: input.intrinsicContentSize.height)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: webView.window ?? window) { response in
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
        }
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

extension SiteWindowController: NSWindowDelegate {
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
            WindowHelpMenus.shared.activate(m)
        }
    }

    func windowDidResize(_ notification: Notification) {
        updateTabStackWidth()
        guard !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        persistWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        guard !changingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
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

}

/// 地址栏按文字行高居中，避免将边框留白计算为文字高度。
private final class CenteredAddressCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let height = min(result.height, ceil(font.ascender - font.descender + font.leading))
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }
}

final class CopyableTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredAddressCell.self }
        set { }
    }
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
