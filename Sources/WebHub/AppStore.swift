import Foundation
import AppKit

// MARK: - 数据模型

enum SiteIconMode: String, Codable {
    case website, name
}

struct WebApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var iconFile: String?
    var iconURL: String?
    var accent: String
    var iconMode: SiteIconMode?
    var isolatedLogin: Bool?
    var supportedDomains: [String]?
    var effectiveIconMode: SiteIconMode { iconMode ?? .website }
    var usesIsolatedLogin: Bool { isolatedLogin ?? false }

    static func make(name: String, url: String, iconURL: String? = nil, accent: String? = nil, iconMode: SiteIconMode = .website, isolatedLogin: Bool = false, supportedDomains: [String] = []) -> WebApp {
        WebApp(id: UUID().uuidString.lowercased(),
               name: name,
               url: url,
               iconFile: nil,
               iconURL: iconURL?.isEmpty == false ? iconURL : nil,
               accent: accent ?? AccentPalette.defaultColor,
               iconMode: iconMode,
               isolatedLogin: isolatedLogin,
               supportedDomains: supportedDomains.isEmpty ? nil : supportedDomains)
    }
}

enum AccentPalette {
    static let defaultColor = "#FFFFFF"
    static let colors = [
        defaultColor, "#F06030", "#3B82F6", "#8B5CF6", "#10B981",
        "#F59E0B", "#EC4899", "#06B6D4", "#6366F1"
    ]

    /// 注意：绝不能在这里访问 AppStore.shared，
    /// 否则会与 AppStore 的 init 形成递归（dispatch_once 死锁）。
    static func random() -> String {
        colors.randomElement() ?? colors[0]
    }

    static func next(count: Int) -> String {
        colors[count % colors.count]
    }
}

/// 标签页会话（用于下次打开时恢复）
struct Bookmark: Codable {
    var id: UUID
    var title: String
    var url: String
    var iconData: Data? = nil
}

struct TabSession: Codable {
    var urls: [String]
    var activeIndex: Int
}

// MARK: - 存储

final class AppStore {
    static let shared = AppStore()

    private let fm = FileManager.default
    private(set) var apps: [WebApp] = []

    let rootDir: URL
    let iconsDir: URL
    let runnerDir: URL
    var legacyRunnerDir: URL { rootDir.appendingPathComponent("runners", isDirectory: true) }
    private var appsFile: URL { rootDir.appendingPathComponent("apps.json") }
    private var sessionsFile: URL { rootDir.appendingPathComponent("sessions.json") }

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDir = base.appendingPathComponent("WebHub", isDirectory: true)
        iconsDir = rootDir.appendingPathComponent("icons", isDirectory: true)
        runnerDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WebHub Apps", isDirectory: true)
        for dir in [rootDir, iconsDir, runnerDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: 读写

    /// 备份目录：放在 WebKit 的 launcher 数据目录里。
    ///
    /// 为什么不放在 `Application Support/WebHub` 自己旁边？
    /// 2026-11-04 出现过整个 `~/Library/Application Support/WebHub`
    /// 被外部整个删掉的情况（apps.json / icons / runners 全没）。
    /// 备份必须放在不会被同一个动作顺手带走的地方 —— 登录态存在
    /// `~/Library/WebKit/cn.webhub.launcher`，这里和它同生共死。
    private var backupDir: URL {
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("WebKit/cn.webhub.launcher", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var appsBackupFile: URL { backupDir.appendingPathComponent("apps-backup.json") }
    private var sessionsBackupFile: URL { backupDir.appendingPathComponent("sessions-backup.json") }

    func load() {
        if let data = try? Data(contentsOf: appsFile),
           let decoded = try? JSONDecoder().decode([WebApp].self, from: data) {
            apps = decoded
            try? data.write(to: appsBackupFile, options: .atomic)
            return
        }
        // apps.json 不见了 / 坏了：优先从备份恢复，别让用户白配一遍
        if let data = try? Data(contentsOf: appsBackupFile),
           let decoded = try? JSONDecoder().decode([WebApp].self, from: data) {
            apps = decoded
            save()
            return
        }
        apps = AppStore.defaults()
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(apps) {
            try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
            try? data.write(to: appsFile, options: .atomic)
            try? data.write(to: appsBackupFile, options: .atomic)
        }
    }

    private static func defaults() -> [WebApp] {
        [
            WebApp.make(name: "Bing", url: "https://www.bing.com")
        ]
    }

    // MARK: 增删改

    func add(name: String, url: String, iconURL: String? = nil, accent: String? = nil, iconMode: SiteIconMode = .website, isolatedLogin: Bool = false, supportedDomains: String? = nil) -> WebApp {
        let normalizedIconURL = iconURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = WebApp.make(name: name, url: normalizedURL(url), iconURL: normalizedIconURL.map(normalizedURL), accent: accent, iconMode: iconMode, isolatedLogin: isolatedLogin, supportedDomains: Self.normalizeSupportedDomains(supportedDomains))
        apps.append(app)
        save()
        return app
    }

    @discardableResult
    func update(id: String, name: String?, url: String?, iconURL: String?, accent: String?, iconMode: SiteIconMode?, isolatedLogin: Bool?, supportedDomains: String?) -> WebApp? {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return nil }
        if let name = name, !name.isEmpty { apps[idx].name = name }
        if let url = url, !url.isEmpty { apps[idx].url = normalizedURL(url) }
        if let iconURL = iconURL { apps[idx].iconURL = iconURL.isEmpty ? nil : normalizedURL(iconURL) }
        if let accent = accent { apps[idx].accent = accent }
        if let iconMode = iconMode { apps[idx].iconMode = iconMode }
        if let isolatedLogin = isolatedLogin { apps[idx].isolatedLogin = isolatedLogin }
        if let supportedDomains = supportedDomains {
            apps[idx].supportedDomains = Self.normalizeSupportedDomains(supportedDomains)
        }
        save()
        return apps[idx]
    }

    private static func normalizeSupportedDomains(_ raw: String?) -> [String] {
        let domains = (raw ?? "").split(separator: ",").compactMap { item -> String? in
            var domain = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasPrefix("*.") { domain.removeFirst(2) }
            while domain.hasSuffix(".") { domain.removeLast() }
            return domain.isEmpty ? nil : domain
        }
        var seen = Set<String>()
        return domains.filter { seen.insert($0).inserted }
    }

    func remove(id: String) throws {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        let app = apps[idx]
        try removeBookmarks(for: id)
        if app.usesIsolatedLogin {
            SharedStorage.deletePersistentStore(for: app)
            CredentialStore.shared.deleteAll(appID: app.id)
        }
        apps.remove(at: idx)
        save()
        if let icon = app.iconFile {
            try? fm.removeItem(at: iconsDir.appendingPathComponent(icon))
        }
        // 包目录名与 UUID 无关了，交给打包器按站点名定位并注销
        RunnerPackager.removeApp(app)
    }

    /// 拖拽排序
    func move(from: String, to: String) {
        guard let fromIdx = apps.firstIndex(where: { $0.id == from }),
              let toIdx = apps.firstIndex(where: { $0.id == to }),
              fromIdx != toIdx else { return }
        let item = apps.remove(at: fromIdx)
        apps.insert(item, at: toIdx)
        save()
    }

    func setIcon(id: String, png: Data) -> String? {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return nil }
        let filename = "\(id).png"
        let target = iconsDir.appendingPathComponent(filename)
        do {
            try png.write(to: target, options: .atomic)
        } catch { return nil }
        apps[idx].iconFile = filename
        save()
        return filename
    }

    func clearIcon(id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        if let icon = apps[idx].iconFile {
            try? fm.removeItem(at: iconsDir.appendingPathComponent(icon))
        }
        apps[idx].iconFile = nil
        save()
    }

    func iconURL(for app: WebApp) -> URL? {
        guard let name = app.iconFile else { return nil }
        let url = iconsDir.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: 收藏

    private var bookmarksFile: URL { rootDir.appendingPathComponent("bookmarks.json") }
    private var bookmarksBackupFile: URL { backupDir.appendingPathComponent("bookmarks-backup.json") }

    private func bookmarksFile(for id: String, backup: Bool) -> URL {
        let name = UUID(uuidString: id)?.uuidString.lowercased()
            ?? "id-" + id.utf8.map { String(format: "%02x", $0) }.joined()
        let directory = (backup ? backupDir : rootDir).appendingPathComponent("bookmarks", isDirectory: true)
        return directory.appendingPathComponent(name + ".json")
    }

    private func removeBookmarks(for id: String) throws {
        // 旧版合并文件可能尚未迁移，逐条清理而不影响其他站点。
        for file in [bookmarksFile, bookmarksBackupFile] where fm.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            var all = try JSONDecoder().decode([String: [Bookmark]].self, from: data)
            if all.removeValue(forKey: id) != nil {
                try JSONEncoder().encode(all).write(to: file, options: .atomic)
            }
        }
        for backup in [false, true] {
            let file = bookmarksFile(for: id, backup: backup)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }

    private func readBookmarks(at file: URL) -> [Bookmark]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([Bookmark].self, from: data)
    }

    func bookmarks(for id: String) -> [Bookmark] {
        let primary = bookmarksFile(for: id, backup: false)
        let backup = bookmarksFile(for: id, backup: true)
        if let items = readBookmarks(at: primary) { return items }
        if let items = readBookmarks(at: backup) {
            do {
                try fm.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(items).write(to: primary, options: .atomic)
            } catch { NSLog("WebHub: Failed to restore bookmarks: %@", error.localizedDescription) }
            return items
        }
        // 避免新版文件损坏时恢复过期的旧收藏。
        guard !fm.fileExists(atPath: primary.path), !fm.fileExists(atPath: backup.path) else { return [] }
        for file in [bookmarksFile, bookmarksBackupFile] {
            guard let data = try? Data(contentsOf: file),
                  let all = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) else { continue }
            guard let items = all[id] else { return [] }
            do { _ = try saveBookmarks(items, for: id) }
            catch { NSLog("WebHub: Failed to migrate bookmarks: %@", error.localizedDescription) }
            return items
        }
        return []
    }

    /// 返回备份是否写入成功；主文件写入失败时抛错。
    @discardableResult
    func saveBookmarks(_ bookmarks: [Bookmark], for id: String) throws -> Bool {
        let data = try JSONEncoder().encode(bookmarks)
        let primary = bookmarksFile(for: id, backup: false)
        try fm.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: primary, options: .atomic)
        let backup = bookmarksFile(for: id, backup: true)
        do {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backup, options: .atomic)
            return true
        } catch {
            NSLog("WebHub: Failed to back up bookmarks: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: 会话

    private func sessionFile(for id: String, backup: Bool) -> URL {
        // UUID 是常见格式；旧数据中的其他 ID 编码为十六进制，避免成为路径。
        let name = UUID(uuidString: id)?.uuidString.lowercased()
            ?? "id-" + id.utf8.map { String(format: "%02x", $0) }.joined()
        let directory = (backup ? backupDir : rootDir).appendingPathComponent("sessions", isDirectory: true)
        return directory.appendingPathComponent(name + ".json")
    }

    private func readSession(at url: URL) -> TabSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TabSession.self, from: data)
    }

    func session(for id: String) -> TabSession? {
        let primary = sessionFile(for: id, backup: false)
        let backup = sessionFile(for: id, backup: true)
        if let session = readSession(at: primary) { return session }
        if let session = readSession(at: backup) {
            // 修复缺失或损坏的主文件，不改变备份。
            do {
                try fm.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(session).write(to: primary, options: .atomic)
            } catch { NSLog("WebHub: Failed to restore session: %@", error.localizedDescription) }
            return session
        }
        // 有新版文件时不能回退到旧数据，以免恢复过期标签。
        guard !fm.fileExists(atPath: primary.path), !fm.fileExists(atPath: backup.path) else { return nil }
        for file in [sessionsFile, sessionsBackupFile] {
            guard let data = try? Data(contentsOf: file),
                  let all = try? JSONDecoder().decode([String: TabSession].self, from: data) else { continue }
            guard let session = all[id] else { return nil }
            saveSession(session, for: id)
            return session
        }
        return nil
    }

    func saveSession(_ session: TabSession, for id: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        for backup in [false, true] {
            let file = sessionFile(for: id, backup: backup)
            do {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                NSLog("WebHub: Failed to save %@ session: %@", backup ? "backup" : "primary", error.localizedDescription)
                if !backup { return }
            }
        }
    }

    // MARK: 工具

    func normalizedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return s
    }

    func host(of app: WebApp) -> String {
        URL(string: app.url)?.host ?? app.url
    }
}
