import AppKit
import Foundation

/// 从站点抓取 favicon / apple-touch-icon
enum IconFetcher {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    /// 抓取站点图标；失败返回 nil
    /// - Parameters:
    ///   - pageURL: 站点入口
    ///   - completion: 主线程回调 PNG 数据
    static func fetch(for pageURL: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: pageURL) else { completion(nil); return }
        loadHTML(url: url) { html, finalURL in
            let base = finalURL ?? url
            let candidates = iconCandidates(html: html, base: base)
            downloadFirst(candidates: candidates, index: 0) { data in
                DispatchQueue.main.async { completion(data) }
            }
        }
    }

    // MARK: - 内部

    private static func loadHTML(url: URL, completion: @escaping (String?, URL?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let data = data,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                completion(nil, nil)
                return
            }
            completion(html, response?.url)
        }
        task.resume()
    }

    /// 解析 HTML 中的图标声明，按优先级排序
    static func iconCandidates(html: String?, base: URL) -> [URL] {
        var scored: [(Int, URL)] = []

        if let html = html {
            // <link rel="apple-touch-icon" href="...">
            // <link rel="icon" / "shortcut icon" href="...">
            let pattern = "<link[^>]*>"
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsHTML = html as NSString
            let matches = regex?.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length)) ?? []

            for m in matches {
                let tag = nsHTML.substring(with: m.range)
                let lower = tag.lowercased()
                guard lower.contains("icon") else { continue }
                guard let href = attributeValue(in: tag, name: "href"), !href.isEmpty else { continue }
                guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL else { continue }

                var score = 50
                if lower.contains("apple-touch-icon") { score = 100 }
                else if lower.contains("shortcut") { score = 60 }

                // 尺寸越大越好
                if let sizes = attributeValue(in: tag, name: "sizes"),
                   let px = sizes.split(separator: "x").first.flatMap({ Int($0) }) {
                    score += min(px, 512) / 8
                }
                // png/svg 优于 ico
                if resolved.pathExtension.lowercased() == "png" { score += 10 }
                if resolved.pathExtension.lowercased() == "svg" { score += 8 }
                scored.append((score, resolved))
            }
        }

        // 常见兜底路径
        let origin = "\(base.scheme ?? "https")://\(base.host ?? "")"
        var fallbacks = [
            "\(origin)/apple-touch-icon.png",
            "\(origin)/apple-touch-icon-precomposed.png",
            "\(origin)/favicon.ico",
            "\(origin)/favicon.png"
        ]

        // 启发式：静态资源常放在独立 CDN 域名上，其根目录往往也有 favicon
        // （例如 passport.xxx.com 的图标在 s2static.xxx.com/favicon.ico）
        if let html = html {
            for host in staticHosts(in: html, base: base) where host != base.host {
                fallbacks.append("https://\(host)/favicon.ico")
                fallbacks.append("https://\(host)/favicon.png")
            }
        }

        for (i, f) in fallbacks.enumerated() {
            if let u = URL(string: f) {
                scored.append((30 - i, u))
            }
        }

        var seen = Set<String>()
        return scored.sorted { $0.0 > $1.0 }
            .compactMap { item in
                let key = item.1.absoluteString
                if seen.contains(key) { return nil }
                seen.insert(key)
                return item.1
            }
    }

    private static func attributeValue(in tag: String, name: String) -> String? {
        let patterns = [
            "\(name)\\s*=\\s*\"([^\"]*)\"",
            "\(name)\\s*=\\s*'([^']*)'"
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: tag, options: [], range: NSRange(location: 0, length: (tag as NSString).length)),
               m.numberOfRanges > 1 {
                return (tag as NSString).substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    /// 从 HTML 里找出被引用的外链主机名（静态资源 CDN）
    static func staticHosts(in html: String, base: URL) -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        let pattern = "(?:src|href)\\s*=\\s*[\"'](?:https?:)?//([a-zA-Z0-9.-]+)"
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = html as NSString
            for m in re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges > 1 else { continue }
                let host = ns.substring(with: m.range(at: 1)).lowercased()
                guard !host.isEmpty, !seen.contains(host) else { continue }
                seen.insert(host)
                hosts.append(host)
            }
        }
        return hosts
    }

    private static func downloadFirst(candidates: [URL], index: Int, completion: @escaping (Data?) -> Void) {
        guard index < candidates.count else { completion(nil); return }
        let url = candidates[index]
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data = data, data.count > 64, status == 200 else {
                downloadFirst(candidates: candidates, index: index + 1, completion: completion)
                return
            }
            // 校验内容类型，跳过 HTML 错误页
            let ctype = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if ctype.contains("text/html") {
                downloadFirst(candidates: candidates, index: index + 1, completion: completion)
                return
            }
            guard let png = normalizeToPNG(data) else {
                downloadFirst(candidates: candidates, index: index + 1, completion: completion)
                return
            }
            completion(png)
        }.resume()
    }

    /// 任意图片数据 → PNG（处理 ICO / SVG / 各种位图）
    static func normalizeToPNG(_ data: Data) -> Data? {
        // SVG 直接位图化
        if let text = String(data: data, encoding: .utf8), text.contains("<svg") {
            if let image = NSImage(data: data) {
                return pngData(from: image, size: 512)
            }
            return nil
        }
        guard let image = NSImage(data: data) else { return nil }
        // 太小（如 16x16）直接放大没有意义，但仍可使用
        let maxSide = max(image.size.width, image.size.height)
        let target: CGFloat = maxSide < 256 ? 512 : 1024
        return pngData(from: image, size: target)
    }

    static func pngData(from image: NSImage, size: CGFloat) -> Data? {
        guard let resized = IconBuilder.resize(image: image, to: size) else { return nil }
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
