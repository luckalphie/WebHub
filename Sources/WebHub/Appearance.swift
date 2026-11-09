import AppKit

enum WebHubAppearance: String {
    case system, light, dark

    private static let preferenceKey = "WebHub.appearance"

    static var preference: WebHubAppearance {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(WebHubAppearance.init(rawValue:)) ?? .system
    }

    static func apply(_ appearance: WebHubAppearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func select(_ appearance: WebHubAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: preferenceKey)
        apply(appearance)
    }
}

final class AppearanceMenu: NSObject, NSMenuDelegate {
    static let shared = AppearanceMenu()

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: WebHubLanguage.text("Appearance"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: WebHubLanguage.text("Appearance"))
        menu.delegate = self
        for (title, appearance) in [(WebHubLanguage.text("System Default"), WebHubAppearance.system), (WebHubLanguage.text("Light Mode"), .light), (WebHubLanguage.text("Dark Mode"), .dark)] {
            let choice = NSMenuItem(title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = appearance.rawValue
            choice.state = appearance == WebHubAppearance.preference ? .on : .off
            menu.addItem(choice)
        }
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = (item.representedObject as? String) == WebHubAppearance.preference.rawValue ? .on : .off
        }
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let appearance = WebHubAppearance(rawValue: value) else { return }
        WebHubAppearance.select(appearance)
        if let menu = sender.menu { menuNeedsUpdate(menu) }
    }
}

// CALayer 保存的是固定 CGColor，外观变化时需要重新解析系统动态颜色。
class AppearanceBackgroundView: NSView {
    private let backgroundColor: NSColor

    init(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }
}
