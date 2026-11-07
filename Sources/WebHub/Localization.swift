import AppKit

enum WebHubLanguage {
    static var languagePreference: String { UserDefaults.standard.string(forKey: "WebHub.language") ?? "system" }
    static var isChinese: Bool {
        switch languagePreference {
        case "zh-CN": return true
        case "en": return false
        default: return Bundle.main.preferredLocalizations.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
    static let translations: [String: String] = {
        let url = Bundle.main.url(forResource: "zh-CN", withExtension: "json")
            ?? Bundle.module.url(forResource: "zh-CN", withExtension: "json")
        guard let url = url, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()
    static func text(_ english: String) -> String { isChinese ? (translations[english] ?? english) : english }
    static func format(_ english: String, _ value: String) -> String {
        String(format: text(english), value)
    }
}

final class LanguageMenu: NSObject {
    static let shared = LanguageMenu()

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: WebHubLanguage.text("Language"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: WebHubLanguage.text("Language"))
        for (title, value) in [(WebHubLanguage.text("System Default"), "system"), ("English", "en"), ("简体中文", "zh-CN")] {
            let choice = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = value
            choice.state = (WebHubLanguage.languagePreference == value) ? .on : .off
            menu.addItem(choice)
        }
        item.submenu = menu
        return item
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String,
              language != WebHubLanguage.languagePreference else { return }
        UserDefaults.standard.set(language, forKey: "WebHub.language")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        let alert = NSAlert()
        alert.messageText = WebHubLanguage.text("Language changed")
        alert.informativeText = WebHubLanguage.text("Restart WebHub to apply the language change to all windows.")
        alert.addButton(withTitle: WebHubLanguage.text("OK"))
        alert.runModal()
    }
}
