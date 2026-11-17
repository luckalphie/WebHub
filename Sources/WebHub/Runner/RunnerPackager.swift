import Foundation
import AppKit
import CryptoKit
import WebHubIPC

/// 把站点打包成独立的 .app，从而在 Dock 里拥有自己的图标
enum RunnerPackager {
    private static let standaloneKey = "WebHub.createStandaloneApps"
    static var createsStandaloneApps: Bool {
        get { UserDefaults.standard.bool(forKey: standaloneKey) }
        set { UserDefaults.standard.set(newValue, forKey: standaloneKey) }
    }
    static var hasStandalonePreference: Bool { UserDefaults.standard.object(forKey: standaloneKey) != nil }
    static var isChangingStandaloneApps = false

    /// 给 ~/Applications/WebHub Apps 设置 Edge Apps 风格的文件夹图标。
    /// 文件夹不存在时静默跳过。
    static func refreshRunnerDirectoryIcon() {
        let directory = AppStore.shared.runnerDir
        guard FileManager.default.fileExists(atPath: directory.path),
              let folderIcon = IconBuilder.folderIcon() else { return }
        NSWorkspace.shared.setIcon(folderIcon, forFile: directory.path, options: [])
    }
    private static var runtimeDir: URL { AppStore.shared.rootDir.appendingPathComponent("runtime-shims", isDirectory: true) }
    private static var runtimeHelperURL: URL { runtimeDir.appendingPathComponent("WebHubHelper.app", isDirectory: true) }

    /// 微信式内嵌 Helper：固定使用主 App 资源中的 Helper，不复制到用户目录。
    static var embeddedHelperURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("WebHubRunner.app"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/WebHubRunner").path)
        else { return nil }
        return url
    }

    /// 生成当前站点最终使用的图标文件，供内嵌 Helper 启动时设置 Dock 图标。
    private static func runtimeIconURL(for app: WebApp, iconPNG: Data?) -> URL? {
        let fm = FileManager.default
        let dir = AppStore.shared.appDataDir(for: app.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let glyphData = iconPNG ?? AppStore.shared.iconURL(for: app).flatMap { try? Data(contentsOf: $0) }
        let glyph = glyphData.flatMap { NSImage(data: $0) }
        guard let themedIcon = (app.effectiveIconMode == .website ? glyph.flatMap { IconBuilder.composeIcon(glyph: $0, accent: app.accent) } : nil)
            ?? IconBuilder.nameIcon(name: app.name, accent: app.accent) else { return nil }
        let url = dir.appendingPathComponent("runtime-icon.png")
        guard (try? themedIcon.write(to: url)) != nil else { return nil }
        return url
    }

    static func runnerBinaryPath() -> String? {
        // 正式形态：打包脚本把 WebHubRunner.app 内嵌在宿主 Resources 里
        if let res = Bundle.main.resourceURL?
            .appendingPathComponent("WebHubRunner.app")
            .appendingPathComponent("Contents/MacOS/WebHubRunner").path,
           FileManager.default.fileExists(atPath: res) {
            return res
        }
        // 开发态：`swift build` 产出的两个可执行文件在同目录
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let dev = exeDir.appendingPathComponent("WebHubRunner").path
        if FileManager.default.fileExists(atPath: dev) { return dev }
        return nil
    }

    /// 站点名 → 可用的包文件名（去掉文件系统非法字符，限制长度）
    static func bundleName(for app: WebApp) -> String {
        var name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.components(separatedBy: bad).joined(separator: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "WebApp" }
        if name.count > 40 { name = String(name.prefix(40)) }
        return name
    }

    /// 站点 .app 的路径。
    /// ⚠️ 包目录名必须用站点名而不是 UUID：Dock 在某些情况下（新建包、LS 缓存未及时刷新）
    /// 会回退用「包文件名」当悬停标签，UUID 目录名就会显示成一串乱码。
    static func bundleURL(for app: WebApp, runtime: Bool = false) -> URL {
        let dir = runtime ? AppStore.shared.appDataDir(for: app.id) : AppStore.shared.runnerDir
        let base = bundleName(for: app)
        // 保留已分配的同名冲突路径，避免其他应用删除后生成第二份站点包。
        if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           let existing = entries.first(where: {
               let name = $0.deletingPathExtension().lastPathComponent
               return $0.pathExtension == "app" && (name == base || name.hasPrefix("\(base)-\(app.id)")) && appID(in: $0) == app.id
           }) {
            return existing
        }
        var index = 0
        while true {
            let suffix = index == 0 ? "" : (index == 1 ? "-\(app.id)" : "-\(app.id)-\(index)")
            let candidate = dir.appendingPathComponent("\(base)\(suffix).app")
            if !FileManager.default.fileExists(atPath: candidate.path) || appID(in: candidate) == app.id {
                return candidate
            }
            index += 1
        }
    }

    static func appID(in bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        guard let id = dict["WebHubAppID"] as? String, UUID(uuidString: id) != nil,
              dict["CFBundleIdentifier"] as? String == "cn.webhub.runner.\(id)" else { return nil }
        return id
    }

    static func standaloneBundles() throws -> [URL] {
        let dir = AppStore.shared.runnerDir
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { url in
                url.pathExtension == "app" && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && appID(in: url) != nil
            }
    }

    static func deleteStandaloneBundles(_ bundles: [URL]) throws {
        for url in bundles {
            guard appID(in: url) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 未开启独立 App 时只使用一个共用 Helper。Helper 不保存站点身份，
    /// 站点 ID 通过启动参数传入，因此不会为每个站点生成临时 .app。
    static func ensureRuntimeHelper(for app: WebApp, iconPNG: Data?) -> URL? {
        let fm = FileManager.default
        let bundleURL = runtimeHelperURL
        let macosDir = bundleURL.appendingPathComponent("Contents/MacOS")
        do { try fm.createDirectory(at: macosDir, withIntermediateDirectories: true) } catch { return nil }
        guard let src = runnerBinaryPath(),
              let size = (try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber,
              size.intValue >= 50_000 else { return nil }
        let dest = macosDir.appendingPathComponent("WebHubRunner")
        if (try? Data(contentsOf: URL(fileURLWithPath: src))) != (try? Data(contentsOf: dest)) {
            try? fm.removeItem(at: dest)
            guard (try? fm.copyItem(atPath: src, toPath: dest.path)) != nil else { return nil }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        let resDir = bundleURL.appendingPathComponent("Contents/Resources")
        do { try fm.createDirectory(at: resDir, withIntermediateDirectories: true) } catch { return nil }
        let glyphData = iconPNG ?? AppStore.shared.iconURL(for: app).flatMap { try? Data(contentsOf: $0) }
        let glyph = glyphData.flatMap { NSImage(data: $0) }
        let themedIcon = (app.effectiveIconMode == .website ? glyph.flatMap { IconBuilder.composeIcon(glyph: $0, accent: app.accent) } : nil)
            ?? IconBuilder.nameIcon(name: app.name, accent: app.accent)
        var iconName = "AppIcon"
        if let png = themedIcon {
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            iconName = "AppIcon-\(hash.prefix(12))"
            let icnsURL = resDir.appendingPathComponent("\(iconName).icns")
            if !IconBuilder.icns(fromPNG: png, to: icnsURL) { iconName = "AppIcon" }
            if let resources = try? fm.contentsOfDirectory(at: resDir, includingPropertiesForKeys: nil) {
                for oldIcon in resources where oldIcon.pathExtension == "icns" && oldIcon != icnsURL {
                    try? fm.removeItem(at: oldIcon)
                }
            }
        }
        let info: [String: Any] = [
            "CFBundleExecutable": "WebHubRunner",
            "CFBundleIdentifier": "cn.webhub.runtime-helper",
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundleIconFile": iconName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "LSUIElement": false,
            WebHubIPC.hostPathKey: Bundle.main.bundlePath
        ]
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard (info as NSDictionary).write(to: plistURL, atomically: true) else { return nil }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", bundleURL.path]
        sign.standardError = FileHandle.nullDevice
        sign.standardOutput = FileHandle.nullDevice
        try? sign.run(); sign.waitUntilExit()
        return bundleURL
    }

    /// 清理旧版本生成在 Application Support 中的 runtime shim。
    static func removeLegacyRuntimeShims() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: runtimeDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "app" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// 只迁移能确认属于现有站点的旧应用，不覆盖目标目录中的其他文件。
    static func migrateLegacyBundles() {
        let fm = FileManager.default
        let store = AppStore.shared
        let dirs = [store.legacyRunnerDir, store.runnerDir]
        for dir in dirs {
            guard let bundles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for legacy in bundles where legacy.pathExtension == "app" {
                guard let id = appID(in: legacy),
                      let app = store.apps.first(where: { $0.id == id }) else { continue }
                let target = bundleURL(for: app)
                guard legacy.standardizedFileURL != target.standardizedFileURL,
                      !fm.fileExists(atPath: target.path) else { continue }
                do {
                    try fm.moveItem(at: legacy, to: target)
                } catch {
                    NSLog("[WebHub] 迁移站点应用失败：%@", error.localizedDescription)
                }
            }
        }
    }

    /// 包内容指纹：站点信息 + 运行器二进制大小 + 图标标识。
    /// 用来判断「现有包是否已经是最新的」，避免每次点图标都重写二进制并重签。
    private static func stampText(for app: WebApp, bundleURL: URL) -> String? {
        let fm = FileManager.default
        guard let src = runnerBinaryPath(),
              let srcSize = (try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber
        else { return nil }
        let iconKey = AppStore.shared.iconURL(for: app)
            .flatMap { try? Data(contentsOf: $0) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        // 图标绘制规则变化时更新版本，使已有站点包重新生成图标。
        return "icon-v13|\(app.id)|\(app.name)|\(app.url)|\(app.iconURL ?? "")|\(app.accent)|\(app.effectiveIconMode.rawValue)|\(srcSize.intValue)|\(iconKey)"
    }

    private static func stampURL(_ bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/.webhub-stamp")
    }

    /// 包已是最新且二进制完整时返回 true —— 此时完全跳过覆盖与重签
    private static func isUpToDate(_ app: WebApp, _ bundleURL: URL) -> Bool {
        let fm = FileManager.default
        guard let want = stampText(for: app, bundleURL: bundleURL),
              let have = try? String(contentsOf: stampURL(bundleURL), encoding: .utf8),
              have.trimmingCharacters(in: .whitespacesAndNewlines) == want
        else { return false }
        // 指纹一致还要确认可执行文件真的在、且大小与源一致（防止上次构建中断留下残缺包）
        guard let src = runnerBinaryPath(),
              let srcSize = (try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber,
              let binSize = (try? fm.attributesOfItem(
                atPath: bundleURL.appendingPathComponent("Contents/MacOS/WebHubRunner").path
              ))?[.size] as? NSNumber
        else { return false }
        return srcSize == binSize && srcSize.intValue > 0
    }

    /// 生成（或更新）某站点的独立 app 包，返回可 open 的 URL
    @discardableResult
    static func ensureApp(for app: WebApp, iconPNG: Data?, runtime: Bool = false) -> URL? {
        guard !isChangingStandaloneApps, runtime || createsStandaloneApps else { return nil }
        let fm = FileManager.default
        let store = AppStore.shared
        let bundleURL = bundleURL(for: app, runtime: runtime)
        let existed = fm.fileExists(atPath: bundleURL.path)

        // 已经是最新的包：不覆盖二进制、不重签，直接启动。
        // ⚠️ 这一步很关键：如果每次都 codesign --force 重写包，
        // 一旦此时主 App 正在重新编译（内嵌的 WebHubRunner 被删/在建），
        // 新进程会拿到残缺二进制，启动后 0.4s 内在 WebKit 初始化里崩掉。
        if existed, isUpToDate(app, bundleURL) {
            return bundleURL
        }

        // 站点改名后旧包要清掉，否则 Dock 里会多留一个旧名字的图标
        if let siblings = try? fm.contentsOfDirectory(at: runtime ? runtimeDir : store.runnerDir,
                                                      includingPropertiesForKeys: nil) {
            for url in siblings where url.pathExtension == "app"
                && url.standardizedFileURL != bundleURL.standardizedFileURL {
                let p = url.appendingPathComponent("Contents/Info.plist")
                guard let d = try? Data(contentsOf: p),
                      let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil),
                      let dict = obj as? [String: Any],
                      dict["WebHubAppID"] as? String == app.id else { continue }
                try? fm.removeItem(at: url)
            }
        }
        let macosDir = bundleURL.appendingPathComponent("Contents/MacOS")
        let resDir = bundleURL.appendingPathComponent("Contents/Resources")

        do {
            try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: resDir, withIntermediateDirectories: true)
        } catch { return nil }

        // 复制运行器二进制（每次都覆盖，保证版本一致）
        guard let src = runnerBinaryPath() else { return nil }
        // 主 App 正在重新编译时，内嵌的 WebHubRunner 可能处于被删除/半写入状态。
        // 这种残缺二进制拷进站点包会让新进程 0.4s 内在 WebKit 初始化里崩掉，
        // 所以这里直接拒绝打包，宁可这次启动失败也不要产出一个必然崩溃的包。
        if let size = (try? fm.attributesOfItem(atPath: src))?[.size] as? NSNumber,
           size.intValue < 50_000 {
            return nil
        }
        let dest = macosDir.appendingPathComponent("WebHubRunner")
        let srcData = try? Data(contentsOf: URL(fileURLWithPath: src))
        let destData = try? Data(contentsOf: dest)
        if srcData != destData {
            try? fm.removeItem(at: dest)
            guard (try? fm.copyItem(atPath: src, toPath: dest.path)) != nil else { return nil }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }

        // 图标
        var iconName = ""
        let glyphData = iconPNG ?? store.iconURL(for: app).flatMap({ try? Data(contentsOf: $0) })
        let glyph = glyphData.flatMap { NSImage(data: $0) }
        let themedIcon = (app.effectiveIconMode == .website ? glyph.flatMap { IconBuilder.composeIcon(glyph: $0, accent: app.accent) } : nil)
            ?? IconBuilder.nameIcon(name: app.name, accent: app.accent)
        if let png = themedIcon {
            let iconHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            iconName = "AppIcon-\(iconHash.prefix(12))"
            let icnsURL = resDir.appendingPathComponent("\(iconName).icns")
            if IconBuilder.icns(fromPNG: png, to: icnsURL) {
                // 图标文件名随内容变化，绕开 Launch Services 按 bundle 和路径复用的旧图标缓存。
                if let resources = try? fm.contentsOfDirectory(at: resDir, includingPropertiesForKeys: nil) {
                    for oldIcon in resources where oldIcon.lastPathComponent.hasPrefix("AppIcon-")
                        && oldIcon.pathExtension == "icns" && oldIcon != icnsURL {
                        try? fm.removeItem(at: oldIcon)
                    }
                }
            } else {
                iconName = ""
            }
        }

        // Info.plist
        var info: [String: Any] = [
            "CFBundleDisplayName": app.name,
            "CFBundleName": app.name,
            "CFBundleExecutable": "WebHubRunner",
            "CFBundleIdentifier": "cn.webhub.runner.\(app.id)",
            "CFBundleIconFile": iconName.isEmpty ? "AppIcon" : iconName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "12.0",
            "NSHighResolutionCapable": true,
            "LSUIElement": false,
            "NSAppTransportSecurity": [
                "NSAllowsArbitraryLoads": true,
                "NSAllowsArbitraryLoadsInWebContent": true,
                "NSAllowsLocalNetworking": true
            ],
            "WebHubAppID": app.id,
            "WebHubAppName": app.name,
            "WebHubAppURL": app.url
        ]
        // 单宿主：shim 本身只占 Dock 位，真正开窗的是宿主。
        // 宿主没在跑时 shim 会用它把 WebHub 拉起来。
        // 只在 .app 形态下写：`swift run` 出来的裸二进制不是能 open 的应用。
        let hostPath = Bundle.main.bundlePath
        if hostPath.hasSuffix(".app") { info[WebHubIPC.hostPathKey] = hostPath }
        let plist = info as NSDictionary
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard (plist as NSDictionary).write(to: plistURL, atomically: true) else { return nil }

        // 自签名（ad-hoc）
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", bundleURL.path]
        sign.standardError = FileHandle.nullDevice
        sign.standardOutput = FileHandle.nullDevice
        try? sign.run()
        sign.waitUntilExit()

        // 指纹要在签名之后写：签名会动 _CodeSignature，但不影响指纹内容
        if let stamp = stampText(for: app, bundleURL: bundleURL) {
            try? stamp.write(to: stampURL(bundleURL), atomically: true, encoding: .utf8)
        }
        return bundleURL
    }

    static func removeApp(_ app: WebApp) {
        let dir = AppStore.shared.runnerDir
        for url in [dir.appendingPathComponent("\(app.id).app"), bundleURL(for: app), bundleURL(for: app, runtime: true)] {
            guard appID(in: url) == app.id else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 打开站点窗口
    static func launch(app: WebApp) {
        guard !isChangingStandaloneApps else { return }
        if SiteWindowManager.shared.openSiteIDs.contains(app.id) {
            SiteWindowManager.shared.activate(app.id)
            return
        }
        let iconData = AppStore.shared.iconURL(for: app).flatMap { try? Data(contentsOf: $0) }
        let bundle: URL
        if createsStandaloneApps {
            guard let standalone = ensureApp(for: app, iconPNG: iconData) else { return }
            bundle = standalone
        } else {
            guard let helper = embeddedHelperURL else { return }
            bundle = helper
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        // 共用内嵌 Helper 不在 Info.plist 固定站点身份，必须通过参数传入。
        if !createsStandaloneApps {
            var arguments = [app.id]
            if let iconPath = runtimeIconURL(for: app, iconPNG: iconData)?.path { arguments.append(iconPath) }
            arguments.append(app.name)
            cfg.createsNewApplicationInstance = true
            cfg.arguments = arguments
        }
        NSWorkspace.shared.openApplication(at: bundle, configuration: cfg) { _, error in
            if let error = error {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = WebHubLanguage.format("Unable to open %@", app.name)
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
