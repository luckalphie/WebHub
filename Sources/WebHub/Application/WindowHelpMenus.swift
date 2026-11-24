import AppKit

enum ViewMenu {
    static func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: WebHubLanguage.text("View"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: WebHubLanguage.text("View"))
        menu.addItem(AppearanceMenu.shared.makeItem())
        menu.addItem(LanguageMenu.shared.makeItem())
        item.submenu = menu
        return item
    }
}

/// 每套主菜单拥有自己的窗口和帮助菜单，切换时不移动正在显示的菜单项。
final class WindowHelpMenus: NSObject, NSMenuDelegate {
    static let shared = WindowHelpMenus()
    private let dynamicItemTag = 0x574853

    func activate(_ menu: NSMenu) {
        if !menu.items.contains(where: { $0.submenu?.delegate === self }) {
            let windowItem = NSMenuItem()
            let windowMenu = NSMenu(title: WebHubLanguage.text("Window"))
            windowMenu.addItem(withTitle: WebHubLanguage.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            windowMenu.addItem(withTitle: WebHubLanguage.text("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            windowMenu.addItem(.separator())
            windowMenu.addItem(withTitle: WebHubLanguage.text("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            windowMenu.delegate = self
            windowItem.submenu = windowMenu
            menu.addItem(windowItem)

            let helpItem = NSMenuItem()
            let helpMenu = NSMenu(title: WebHubLanguage.text("Help"))
            let help = NSMenuItem(title: WebHubLanguage.text("WebHub Help"), action: #selector(openHelp), keyEquivalent: "")
            help.target = self
            helpMenu.addItem(help)
            helpItem.submenu = helpMenu
            menu.addItem(helpItem)
        }
        guard let windowMenu = menu.items.compactMap(\.submenu).first(where: { $0.delegate === self }),
              let helpMenu = menu.items.compactMap(\.submenu).first(where: { $0.title == WebHubLanguage.text("Help") }) else { return }
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == dynamicItemTag { menu.removeItem(item) }
        let sites = SiteWindowManager.shared.openSites
        guard !sites.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = dynamicItemTag
        menu.addItem(separator)
        for site in sites {
            let item = NSMenuItem(title: site.name, action: #selector(activateSite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = site.id
            item.state = site.isKey ? .on : .off
            item.tag = dynamicItemTag
            menu.addItem(item)
        }
    }

    @objc private func activateSite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SiteWindowManager.shared.activate(id)
    }

    @objc private func openHelp() {
        guard let url = URL(string: "https://github.com/luckalphie/WebHub#readme") else { return }
        NSWorkspace.shared.open(url)
    }
}
