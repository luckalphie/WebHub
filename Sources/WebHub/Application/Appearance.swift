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
        NotificationCenter.default.post(name: .webHubDisplayPreferencesChanged, object: nil)
    }
}

enum AppCenterIconSize {
    static let minimum: CGFloat = 72
    static let maximum: CGFloat = 160
    static let step: CGFloat = 4
    static let defaultValue: CGFloat = 100

    private static let preferenceKey = "WebHub.appCenterIconSize"

    static var preference: CGFloat {
        guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return defaultValue }
        return normalized(CGFloat(UserDefaults.standard.double(forKey: preferenceKey)))
    }

    static func normalized(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, minimum), maximum)
        return (clamped / step).rounded() * step
    }

    static func save(_ value: CGFloat) {
        UserDefaults.standard.set(Double(normalized(value)), forKey: preferenceKey)
    }
}

enum SiteChromeColors {
    private static func adaptive(light: NSColor, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: dark, alpha: 1) : light
        }
    }

    static let titleBar = adaptive(light: NSColor(srgbRed: 0.82, green: 0.88, blue: 0.98, alpha: 1), dark: 0.075)
    static let toolbar = adaptive(light: .white, dark: 0.18)
    static let selectedTab = adaptive(light: .white, dark: 0.18)
    static let tabSeparator = adaptive(light: NSColor(white: 0.60, alpha: 1), dark: 0.30)
    static let address = adaptive(light: .white, dark: 0.12)
    static let addressText = adaptive(light: .labelColor, dark: 0.88)
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
