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

/// 两类窗口切换菜单时复用同一组系统窗口和帮助菜单。
final class WindowHelpMenus: NSObject {
    static let shared = WindowHelpMenus()

    private let windowItem = NSMenuItem()
    private let helpItem = NSMenuItem()
    private let windowMenu = NSMenu(title: WebHubLanguage.text("Window"))
    private let helpMenu = NSMenu(title: WebHubLanguage.text("Help"))

    private override init() {
        super.init()
        windowMenu.addItem(withTitle: WebHubLanguage.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: WebHubLanguage.text("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: WebHubLanguage.text("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        let help = NSMenuItem(title: WebHubLanguage.text("WebHub Help"), action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        helpMenu.addItem(help)
        helpItem.submenu = helpMenu
    }

    func activate(_ menu: NSMenu) {
        windowItem.menu?.removeItem(windowItem)
        helpItem.menu?.removeItem(helpItem)
        menu.addItem(windowItem)
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @objc private func openHelp() {
        guard let url = URL(string: "https://github.com/luckalphie/WebHub#readme") else { return }
        NSWorkspace.shared.open(url)
    }
}
