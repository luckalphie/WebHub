import AppKit
import WebKit

// MARK: - 单站点的标签页

final class TabItem {
    let id = UUID()
    let webView: WKWebView
    var title: String
    var url: URL

    init(webView: WKWebView, title: String, url: URL) {
        self.webView = webView
        self.title = title
        self.url = url
    }
}

// MARK: - 运行器窗口

final class RunnerWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private let appID: String
    private let appName: String
    private let homeURL: URL

    private var window: NSWindow!
    private var topBar: NSView!
    private var tabBar: NSView!
    private var tabStack: NSStackView!
    private var contentHost: NSView!
    private var addressField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var homeButton: NSButton!
    private var reloadButton: NSButton!
    private var newTabButton: NSButton!

    private var tabs: [TabItem] = []
    private var activeIndex = 0
    private var running = false
    private var isClamping = false
    /// 本站点窗口专属菜单，等窗口成为 key 时才挂到全局
    private var siteMenu: NSMenu?

    private var activeTab: TabItem? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex]
    }

    init(appID: String, appName: String, url: URL) {
        self.appID = appID
        self.appName = appName
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
            for u in session.urls {
                addTab(url: URL(string: u) ?? homeURL, activate: false)
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
        let visible = visibleScreenFrame()
        let width = min(1200, visible.width - 80)
        let height = min(800, visible.height - 80)
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
        window.delegate = self

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = root

        // 工具栏（标签栏下面一行）
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.addSubview(topBar)
        self.topBar = topBar

        // 标签栏（最顶）
        tabBar = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.addSubview(tabBar)

        tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .centerY
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        // 标签变多时允许压缩，绝不让标签栏把窗口往宽撑
        tabStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabStack.setHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addSubview(tabStack)

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

            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildToolbar() {
        guard let topBar = self.topBar else { return }

        backButton = toolbarButton("chevron.left", "后退", #selector(goBack))
        forwardButton = toolbarButton("chevron.right", "前进", #selector(goForward))
        homeButton = toolbarButton("house", "主页", #selector(goHome))
        reloadButton = toolbarButton("arrow.clockwise", "刷新", #selector(reload))
        newTabButton = toolbarButton("plus", "新标签页", #selector(newTab))

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
    private func addTab(url: URL, activate: Bool) -> TabItem {
        let cfg = WKWebViewConfiguration()
        // 共享数据仓库：所有站点窗口互通 cookie / localStorage → 共享登录态
        cfg.websiteDataStore = SharedStorage.dataStore()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 自动填充脚本
        let host = url.host ?? ""
        cfg.userContentController.addUserScript(AutofillScript.make(host: host))
        cfg.userContentController.add(self, name: "autofill")
        cfg.userContentController.add(self, name: "tab")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.translatesAutoresizingMaskIntoConstraints = false

        let tab = TabItem(webView: wv, title: "加载中…", url: url)
        tabs.append(tab)

        wv.load(URLRequest(url: url))
        if activate {
            selectTab(tabs.count - 1)
        } else {
            rebuildTabBar()
        }
        return tab
    }

    /// 标签关闭按钮 + 切换
    @objc private func tabClicked(_ sender: NSButton) {
        selectTab(sender.tag)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        closeTab(at: sender.tag)
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index

        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let tab = tabs[index]
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(tab.webView)
        NSLayoutConstraint.activate([
            tab.webView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            tab.webView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])

        rebuildTabBar()
        updateAddress()
        updateToolbarState()
        window.title = tab.title
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.webView.configuration.userContentController.removeScriptMessageHandler(forName: "tab")
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()

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

        let newIndex = min(index, tabs.count - 1)
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
            let holder = NSView()
            holder.wantsLayer = true
            holder.layer?.cornerRadius = 7
            holder.layer?.backgroundColor = (i == activeIndex
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor)
            holder.translatesAutoresizingMaskIntoConstraints = false

            let titleBtn = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            titleBtn.tag = i
            titleBtn.isBordered = false
            titleBtn.font = NSFont.systemFont(ofSize: 12, weight: i == activeIndex ? .medium : .regular)
            titleBtn.contentTintColor = i == activeIndex ? .labelColor : .secondaryLabelColor
            titleBtn.lineBreakMode = .byTruncatingTail
            // 标签标题同样要允许压缩，否则标签一多就把窗口撑宽
            titleBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleBtn.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(titleBtn)

            let closeBtn = NSButton(title: "", target: self, action: #selector(closeTabClicked(_:)))
            closeBtn.tag = i
            closeBtn.isBordered = false
            if #available(macOS 11.0, *) {
                closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签")
            }
            closeBtn.contentTintColor = .tertiaryLabelColor
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(closeBtn)

            let minTabWidth = holder.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
            minTabWidth.priority = .defaultLow
            NSLayoutConstraint.activate([
                minTabWidth,
                holder.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
                holder.heightAnchor.constraint(equalToConstant: 26),
                titleBtn.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 9),
                titleBtn.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                titleBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -4),
                closeBtn.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -5),
                closeBtn.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 14)
            ])

            tabStack.addArrangedSubview(holder)
        }
    }

    private func updateAddress() {
        guard let tab = activeTab else { return }
        addressField.stringValue = tab.webView.url?.absoluteString ?? tab.url.absoluteString
    }

    private func updateToolbarState() {
        let wv = activeTab?.webView
        backButton?.isEnabled = wv?.canGoBack ?? false
        forwardButton?.isEnabled = wv?.canGoForward ?? false
    }

    private func persistSession() {
        let urls = tabs.map { $0.webView.url?.absoluteString ?? $0.url.absoluteString }
        guard !urls.isEmpty else { return }
        AppStore.shared.saveSession(TabSession(urls: urls, activeIndex: activeIndex), for: appID)
    }

    // MARK: 动作

    @objc private func goBack() { activeTab?.webView.goBack() }
    @objc private func goForward() { activeTab?.webView.goForward() }
    @objc private func goHome() { activeTab?.webView.load(URLRequest(url: homeURL)) }
    @objc private func reload() {
        guard let wv = activeTab?.webView else { return }
        if wv.url == nil { wv.load(URLRequest(url: homeURL)) } else { wv.reload() }
    }

    @objc private func newTab() {
        addTab(url: homeURL, activate: true)
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
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func observeAppState() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func appWillTerminate() {
        persistSession()
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⚠️ 单宿主（Chrome 式）：所有站点窗口共享同一个 NSApplication。
        // 所以这里的「隐藏 / 退出」**绝不能**用 NSApplication.hide/terminate ——
        // 那会把整个 WebHub 连同其他站点一起收掉。必须降级成「只作用于本窗口」。
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(aboutSite), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(hideSite), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(closeSite), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = makeEditMenu()
        mainMenu.addItem(editItem)

        let navItem = NSMenuItem()
        let navMenu = NSMenu(title: "导航")
        navMenu.addItem(withTitle: "后退", action: #selector(goBack), keyEquivalent: "[")
        navMenu.addItem(withTitle: "前进", action: #selector(goForward), keyEquivalent: "]")
        navMenu.addItem(withTitle: "主页", action: #selector(goHome), keyEquivalent: "H")
        navMenu.addItem(withTitle: "刷新", action: #selector(reload), keyEquivalent: "r")
        navMenu.addItem(NSMenuItem.separator())
        navMenu.addItem(withTitle: "新建标签页", action: #selector(newTab), keyEquivalent: "t")
        navMenu.addItem(withTitle: "关闭标签页", action: #selector(closeCurrentTab), keyEquivalent: "w")
        navItem.submenu = navMenu
        mainMenu.addItem(navItem)

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
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

    /// 主机名完全一致才算站内。
    /// 子域也算出站——例如站点是 a.example.com，链到 b.example.com 同样交给默认浏览器。
    private func isSameSite(_ host: String) -> Bool {
        let target = Self.normalizedHost(host)
        let site = Self.normalizedHost(siteHost)
        guard !target.isEmpty, !site.isEmpty else { return false }
        return target == site
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

    // 支持 alert/confirm
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
        completionHandler()
    }

    // MARK: 消息

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "autofill",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let host = (body["host"] as? String) ?? activeTab?.webView.url?.host ?? ""
        let senderWebView = message.webView
        let store = CredentialStore.shared

        switch type {
        case "requestCredential":
            // 页面找到了登录框 → 用已保存的凭据自动填充
            guard let found = store.find(forHost: host) else { return }
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
            store.save(host: key, username: username, password: password)
            NSLog("WebHub: 已保存 \(key) 的登录凭据")

        default:
            break
        }
    }
}

extension RunnerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        persistSession()
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

    func windowDidResize(_ notification: Notification) { clampFrameToScreen() }
    func windowDidMove(_ notification: Notification) { clampFrameToScreen() }

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
        let copyItem = NSMenuItem(title: "复制地址", action: #selector(copyAll(_:)), keyEquivalent: "")
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
