import AppKit
import WebKit

// 收藏栏及其操作；窗口布局由 RunnerWindowController 管理。
extension RunnerWindowController {
    private func saveBookmarks(_ items: [Bookmark]) {
        do {
            try AppStore.shared.saveBookmarks(items, for: appID)
            refreshBookmarks()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法保存收藏"
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
            alert.messageText = "此页面已收藏"
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
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for bookmark in AppStore.shared.bookmarks(for: appID) {
            let button = NSButton(title: bookmark.title, target: self, action: #selector(openBookmark(_:)))
            button.bezelStyle = .inline
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.image = bookmarkIcons[bookmark.url] ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "网页")
            if bookmarkIcons[bookmark.url] == nil, !bookmarkIconRequests.contains(bookmark.url),
               let url = URL(string: bookmark.url), let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme), let host = url.host {
                bookmarkIconRequests.insert(bookmark.url)
                var origin = URLComponents()
                origin.scheme = scheme
                origin.host = host
                origin.port = url.port
                if let originURL = origin.url {
                    IconFetcher.fetch(for: originURL.absoluteString) { [weak self] data in
                        guard let self = self, let data = data, let image = NSImage(data: data) else { return }
                        image.size = NSSize(width: 16, height: 16)
                        self.bookmarkIcons[bookmark.url] = image
                        self.refreshBookmarks()
                    }
                }
            }
            button.identifier = NSUserInterfaceItemIdentifier(bookmark.id.uuidString)
            button.toolTip = bookmark.url
            let menu = NSMenu()
            for (title, action) in [("编辑名称", #selector(renameBookmark(_:))), ("复制地址", #selector(copyBookmark(_:))), ("删除收藏", #selector(deleteBookmark(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = bookmark.id
                menu.addItem(item)
            }
            button.menu = menu
            stack.addArrangedSubview(button)
        }
        stack.frame = NSRect(x: 0, y: 0, width: max(stack.fittingSize.width, 1), height: 30)
    }

    @objc private func openBookmark(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let bookmark = AppStore.shared.bookmarks(for: appID).first(where: { $0.id == id }),
              let url = URL(string: bookmark.url) else { return }
        addTab(url: url, activate: true)
        persistSession()
    }

    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        var items = AppStore.shared.bookmarks(for: appID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "编辑收藏名称"
        let field = NSTextField(string: items[index].title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
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
