import AppKit
import WebKit

// 收藏栏及其操作；窗口布局由 RunnerWindowController 管理。
extension RunnerWindowController {
    private func saveBookmarks(_ items: [Bookmark]) {
        do {
            let backupSaved = try AppStore.shared.saveBookmarks(items, for: appID)
            refreshBookmarks()
            if !backupSaved {
                let alert = NSAlert()
                alert.messageText = WebHubLanguage.text("Bookmarks Saved, Backup Failed")
                alert.informativeText = WebHubLanguage.text("Your bookmarks were saved, but their backup could not be updated.")
                alert.runModal()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = WebHubLanguage.text("Unable to Save Bookmarks")
            alert.runModal()
        }
    }

    @objc func bookmarkTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        let url = (tab.webView?.url ?? tab.url).absoluteString
        var items = AppStore.shared.bookmarks(for: appID)
        guard !items.contains(where: { $0.url == url }) else {
            let alert = NSAlert()
            alert.messageText = WebHubLanguage.text("Page Already Bookmarked")
            alert.runModal()
            return
        }
        if let icon = tab.favicon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            bookmarkIcons[url] = icon
        }
        items.append(Bookmark(id: UUID(), title: tab.title, url: url))
        saveBookmarks(items)
    }

    func refreshBookmarks() {
        guard let stack = bookmarkStack else { return }
        let bookmarks = AppStore.shared.bookmarks(for: appID)
        bookmarkBar.isHidden = bookmarks.isEmpty
        bookmarkBarHeight.constant = bookmarks.isEmpty ? 0 : 32
        let ids = Set(bookmarks.map { $0.id.uuidString })
        for view in stack.arrangedSubviews where !ids.contains(view.identifier?.rawValue ?? "") {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, bookmark) in bookmarks.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier(bookmark.id.uuidString)
            if let button = stack.arrangedSubviews.first(where: { $0.identifier == identifier }) as? NSButton {
                if button.title != bookmark.title { button.title = bookmark.title }
                continue
            }
            let button = NSButton(title: bookmark.title, target: self, action: #selector(openBookmark(_:)))
            button.bezelStyle = .inline
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.image = bookmarkIcons[bookmark.url] ?? NSImage(systemSymbolName: "globe", accessibilityDescription: WebHubLanguage.text("Website"))
            fetchBookmarkIcon(for: bookmark.url, retry: false)
            button.identifier = identifier
            button.toolTip = bookmark.url
            let menu = NSMenu()
            for (title, action) in [(WebHubLanguage.text("Edit Name"), #selector(renameBookmark(_:))), (WebHubLanguage.text("Copy Address"), #selector(copyBookmark(_:))), (WebHubLanguage.text("Delete Bookmark"), #selector(deleteBookmark(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = bookmark.id
                menu.addItem(item)
            }
            button.menu = menu
            stack.insertArrangedSubview(button, at: index)
        }
        stack.frame = NSRect(x: 0, y: 0, width: max(stack.fittingSize.width, 1), height: 30)
    }

    private func fetchBookmarkIcon(for address: String, retry: Bool) {
        guard bookmarkIcons[address] == nil, !bookmarkIconsInFlight.contains(address),
              retry || !bookmarkIconRequests.contains(address),
              let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host else { return }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = url.port
        guard let originURL = origin.url else { return }
        bookmarkIconRequests.insert(address)
        bookmarkIconsInFlight.insert(address)
        IconFetcher.fetch(for: originURL.absoluteString) { [weak self] data in
            guard let self = self else { return }
            self.bookmarkIconsInFlight.remove(address)
            guard let data = data, let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 16, height: 16)
            self.bookmarkIcons[address] = image
            for case let button as NSButton in self.bookmarkStack.arrangedSubviews where button.toolTip == address {
                button.image = image
            }
        }
    }

    @objc private func openBookmark(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let bookmark = AppStore.shared.bookmarks(for: appID).first(where: { $0.id == id }),
              let url = URL(string: bookmark.url) else { return }
        fetchBookmarkIcon(for: bookmark.url, retry: true)
        addTab(url: url, activate: true)
        persistSession()
    }

    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        var items = AppStore.shared.bookmarks(for: appID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = WebHubLanguage.text("Edit Bookmark Name")
        let field = NSTextField(string: items[index].title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: WebHubLanguage.text("Save"))
        alert.addButton(withTitle: WebHubLanguage.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        items[index].title = title
        saveBookmarks(items)
    }

    @objc private func copyBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = AppStore.shared.bookmarks(for: appID).first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url, forType: .string)
    }

    @objc private func deleteBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        saveBookmarks(AppStore.shared.bookmarks(for: appID).filter { $0.id != id })
    }

}
