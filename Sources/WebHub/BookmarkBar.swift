import AppKit
import WebKit

private let bookmarkPasteboardType = NSPasteboard.PasteboardType("cn.webhub.bookmark")

// 用系统拖放会话显示书签快照；普通点击仍交给 NSButton 处理。
private final class BookmarkButton: NSButton, NSDraggingSource {
    let bookmarkID: UUID

    init(bookmarkID: UUID) {
        self.bookmarkID = bookmarkID
        super.init(frame: .zero)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(beginBookmarkDrag(_:)))
        pan.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func beginBookmarkDrag(_ gesture: NSPanGestureRecognizer) {
        guard gesture.state == .began, let event = NSApp.currentEvent,
              event.type == .leftMouseDragged,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(bookmarkID.uuidString, forType: bookmarkPasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        alphaValue = 0.4
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
    }
}

// 在滚动视图上接收拖放，书签右侧空白区域也可以作为落点。
final class BookmarkScrollView: NSScrollView {
    var onBookmarkDrop: ((UUID, Int) -> Void)?
    private let insertionMarker = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([bookmarkPasteboardType])
        wantsLayer = true
        insertionMarker.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMarker.zPosition = 1000
        insertionMarker.isHidden = true
        layer?.addSublayer(insertionMarker)
    }

    required init?(coder: NSCoder) { return nil }

    private func dropTarget(for sender: NSDraggingInfo) -> (UUID, Int, CGFloat)? {
        guard let button = sender.draggingSource as? BookmarkButton,
              button.enclosingScrollView === self,
              let stack = documentView as? NSStackView else { return nil }
        let point = stack.convert(sender.draggingLocation, from: nil)
        let otherButtons = stack.arrangedSubviews.compactMap { $0 as? BookmarkButton }
            .filter { $0 !== button }
        let index = otherButtons.filter { $0.frame.midX < point.x }.count
        let markerX: CGFloat
        if index < otherButtons.count {
            markerX = otherButtons[index].frame.minX - stack.spacing / 2
        } else {
            markerX = (otherButtons.last?.frame.maxX ?? button.frame.minX) + stack.spacing / 2
        }
        return (button.bookmarkID, index, convert(NSPoint(x: markerX, y: 0), from: stack).x)
    }

    private func updateDropTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (_, _, x) = dropTarget(for: sender) else {
            insertionMarker.isHidden = true
            return []
        }
        insertionMarker.frame = CGRect(x: x - 1, y: 3, width: 2, height: max(0, bounds.height - 6))
        insertionMarker.isHidden = false
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDropTarget(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDropTarget(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionMarker.isHidden = true
        guard let (id, index, _) = dropTarget(for: sender), let onBookmarkDrop = onBookmarkDrop else { return false }
        onBookmarkDrop(id, index)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { insertionMarker.isHidden = true }
}

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
        var iconData: Data?
        if let icon = tab.favicon?.copy() as? NSImage {
            iconData = IconFetcher.pngData(from: icon, size: 64)
            icon.size = NSSize(width: 16, height: 16)
            bookmarkIcons[url] = icon
        }
        items.append(Bookmark(id: UUID(), title: tab.title, url: url, iconData: iconData))
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
            let button: NSButton
            if let existing = stack.arrangedSubviews.first(where: { $0.identifier == identifier }) as? NSButton {
                button = existing
                button.title = bookmark.title
            } else {
                button = BookmarkButton(bookmarkID: bookmark.id)
                button.title = bookmark.title
                button.target = self
                button.action = #selector(openBookmark(_:))
                button.bezelStyle = .inline
                button.imagePosition = .imageLeading
                button.imageScaling = .scaleProportionallyDown
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            }
            if bookmarkIcons[bookmark.url] == nil, let data = bookmark.iconData, let image = NSImage(data: data) {
                image.size = NSSize(width: 16, height: 16)
                bookmarkIcons[bookmark.url] = image
            }
            button.image = bookmarkIcons[bookmark.url] ?? NSImage(systemSymbolName: "globe", accessibilityDescription: WebHubLanguage.text("Website"))
            fetchBookmarkIcon(for: bookmark.url, retry: false)
            let currentIndex = stack.arrangedSubviews.firstIndex(of: button)
            if currentIndex != index {
                if currentIndex != nil { stack.removeArrangedSubview(button) }
                stack.insertArrangedSubview(button, at: index)
            }
        }
        updateBookmarkBarWidth()
    }

    private func updateBookmarkBarWidth() {
        guard let stack = bookmarkStack else { return }
        // 书签栏需要横向滚动，不能让容器宽度不足时把按钮标题压没。
        let buttons = stack.arrangedSubviews.filter { !$0.isHidden }
        let width = buttons.reduce(CGFloat.zero) { $0 + $1.fittingSize.width }
            + CGFloat(max(0, buttons.count - 1)) * stack.spacing
        stack.setFrameSize(NSSize(width: max(ceil(width), 1), height: 30))
        stack.layoutSubtreeIfNeeded()
    }

    func reorderBookmark(_ id: UUID, to targetIndex: Int) {
        var items = AppStore.shared.bookmarks(for: appID)
        guard let sourceIndex = items.firstIndex(where: { $0.id == id }) else { return }
        let source = items.remove(at: sourceIndex)
        let boundedIndex = max(0, min(targetIndex, items.count))
        guard boundedIndex != sourceIndex else { return }
        items.insert(source, at: boundedIndex)
        saveBookmarks(items)
    }

    // 网页实际加载出的图标优先于后台抓取的站点图标，同时写入书签和备份。
    func updateBookmarkIcon(_ data: Data, for address: String) {
        guard let image = NSImage(data: data), let png = IconFetcher.pngData(from: image, size: 64) else { return }
        var items = AppStore.shared.bookmarks(for: appID)
        guard let index = items.firstIndex(where: { $0.url == address }) else { return }
        image.size = NSSize(width: 16, height: 16)
        bookmarkIcons[address] = image
        for case let button as NSButton in bookmarkStack.arrangedSubviews where button.toolTip == address {
            button.image = image
        }
        updateBookmarkBarWidth()
        guard items[index].iconData != png else { return }
        items[index].iconData = png
        do {
            if try !AppStore.shared.saveBookmarks(items, for: appID) {
                NSLog("WebHub: Failed to back up bookmark icon")
            }
        } catch {
            NSLog("WebHub: Failed to save bookmark icon: %@", error.localizedDescription)
        }
    }

    private func fetchBookmarkIcon(for address: String, retry: Bool) {
        guard bookmarkIcons[address] == nil, !bookmarkIconsInFlight.contains(address),
              retry || !bookmarkIconRequests.contains(address),
              let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return }
        bookmarkIconRequests.insert(address)
        bookmarkIconsInFlight.insert(address)
        IconFetcher.fetch(for: address) { [weak self] data in
            guard let self = self else { return }
            self.bookmarkIconsInFlight.remove(address)
            guard self.bookmarkIcons[address] == nil, let data = data else { return }
            self.updateBookmarkIcon(data, for: address)
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
