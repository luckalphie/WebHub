import AppKit
import Foundation

// MARK: - 图标渲染
//
// 注意：全部使用 NSBitmapImageRep + NSGraphicsContext 显式绘制，
// 不使用 NSImage.lockFocus()（在非主线程 / 无 App 上下文时不可靠，
// 会报 "CGImageDestinationFinalize failed"）。

enum IconBuilder {

    /// 站点图标 + 主题色圆角底
    static func composeIcon(glyph: NSImage?, accent: String, size: CGFloat = 1024) -> Data? {
        guard let rep = makeBitmap(size: size) else { return nil }
        draw(rep: rep, size: size, accent: accent) { rect in
            guard let glyph = glyph, let prepared = squareGlyph(glyph: glyph, box: rect.width) else { return false }
            let gx = rect.midX - prepared.size.width / 2
            let gy = rect.midY - prepared.size.height / 2
            prepared.draw(in: NSRect(x: gx, y: gy, width: prepared.size.width, height: prepared.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        return png(from: rep)
    }

    /// 中文可按字换行，英文只在空格处换行；最多显示两行。
    static func nameIcon(name: String, accent: String, size: CGFloat = 1024) -> Data? {
        guard let rep = makeBitmap(size: size) else { return nil }
        draw(rep: rep, size: size, accent: accent) { rect in
            drawName(name, accent: accent, in: rect)
            return true
        }
        return png(from: rep)
    }

    private static func lineLengthDifference(words: [String], split: Int) -> Int {
        let first = words[..<split].joined(separator: " ").count
        let second = words[split...].joined(separator: " ").count
        return abs(first - second)
    }

    private static func drawName(_ name: String, accent: String, in rect: CGRect) {
        var text = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if text.isEmpty { text = "Web" }
        if text.count > 64 { text = String(text.prefix(63)) + "…" }
        let words = text.split(separator: " ").map(String.init)
        var lines: [String] = [text]
        if words.count > 1 {
            let split = (1..<words.count).min { left, right in
                let leftDifference = lineLengthDifference(words: words, split: left)
                let rightDifference = lineLengthDifference(words: words, split: right)
                return leftDifference < rightDifference
            }!
            lines = [words[..<split].joined(separator: " "), words[split...].joined(separator: " ")]
        } else if text.count > 3 && text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            let characters = Array(text)
            let middle = (characters.count + 1) / 2
            lines = [String(characters[..<middle]), String(characters[middle...])]
        }
        let usesWhiteText = accent.uppercased() != "#FFFFFF"
        let color = usesWhiteText ? NSColor.white.withAlphaComponent(0.96) : NSColor.darkGray
        var fontSize = rect.width * 0.33
        var attrs: [NSAttributedString.Key: Any] = [:]
        var rendered: [NSAttributedString] = []
        repeat {
            attrs = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
            if usesWhiteText {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.62)
                shadow.shadowBlurRadius = rect.width * 0.012
                shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.004)
                attrs[.shadow] = shadow
            }
            rendered = lines.map { NSAttributedString(string: $0, attributes: attrs) }
            if rendered.allSatisfy({ $0.size().width <= rect.width * 0.82 }) { break }
            fontSize -= rect.width * 0.01
        } while fontSize >= rect.width * 0.12
        for index in rendered.indices where rendered[index].size().width > rect.width * 0.82 {
            var shortened = lines[index]
            let minimum = lines.count == 1 ? min(4, shortened.count) : min(2, shortened.count)
            while shortened.count > minimum && rendered[index].size().width > rect.width * 0.82 {
                shortened.removeLast()
                rendered[index] = NSAttributedString(string: shortened + "…", attributes: attrs)
            }
            if rendered[index].size().width > rect.width * 0.82 {
                let ratio = rect.width * 0.82 / rendered[index].size().width
                var smallerAttrs = attrs
                smallerAttrs[.font] = NSFont.systemFont(ofSize: fontSize * ratio * 0.98, weight: .semibold)
                rendered[index] = NSAttributedString(string: shortened + (shortened.count < lines[index].count ? "…" : ""), attributes: smallerAttrs)
            }
        }
        let lineHeight = rendered.map { $0.size().height }.max() ?? 0
        let totalHeight = lineHeight * CGFloat(rendered.count)
        for (index, line) in rendered.enumerated() {
            let y = rect.midY + totalHeight / 2 - lineHeight * CGFloat(index + 1)
            line.draw(at: NSPoint(x: rect.midX - line.size().width / 2, y: y))
        }
    }

    // MARK: - 内部

    private static func makeBitmap(size: CGFloat) -> NSBitmapImageRep? {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: px, pixelsHigh: px,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        return rep
    }

    /// 绘制圆角渐变底，再回调画内容
    private static func draw(rep: NSBitmapImageRep, size: CGFloat, accent: String,
                             content: (CGRect) -> Bool) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.current = prev }

        let cg = ctx.cgContext
        cg.setAllowsAntialiasing(true)
        cg.interpolationQuality = .high
        // 保证透明背景
        cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

        let inset = size * 0.098
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = rect.width * 0.225
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        cg.saveGState()
        cg.addPath(path)
        cg.clip()

        let colors = gradientColors(for: accent)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [colors.0, colors.1] as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(gradient,
                                  start: CGPoint(x: rect.minX, y: rect.maxY),
                                  end: CGPoint(x: rect.minX, y: rect.minY),
                                  options: [])
        }
        cg.restoreGState()

        // 内容也裁剪在圆角内
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        _ = content(rect)
        cg.restoreGState()

        ctx.flushGraphics()
    }

    private static func png(from rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }

    /// 把任意图片裁成正方形并缩放到 box
    static func squareGlyph(glyph: NSImage, box: CGFloat) -> NSImage? {
        guard let cg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let bounds = alphaBounds(of: cg) ?? CGRect(x: 0, y: 0, width: w, height: h)
        let side = min(min(w, h), max(bounds.width, bounds.height) * 1.08)
        let cropX = min(max(bounds.midX - side / 2, 0), w - side)
        let cropY = min(max(bounds.midY - side / 2, 0), h - side)
        let cropRect = CGRect(x: cropX, y: cropY, width: side, height: side)
        guard let cropped = cg.cropping(to: cropRect) else { return nil }

        let px = Int(box)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        ctx.cgContext.interpolationQuality = .high
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: box, height: box))
        NSImage(cgImage: cropped, size: NSSize(width: side, height: side))
            .draw(in: NSRect(x: 0, y: 0, width: box, height: box),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.flushGraphics()
        NSGraphicsContext.current = prev

        guard let out = rep.representation(using: .png, properties: [:]) else { return nil }
        return NSImage(data: out)
    }

    /// 找到透明 PNG 的实际内容范围，避免图标自带留白导致合成后主体过小。
    private static func alphaBounds(of image: CGImage) -> CGRect? {
        guard image.alphaInfo != .none,
              image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast,
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else { return nil }
        let alphaOffset: Int
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst:
            alphaOffset = 0
        default:
            alphaOffset = bytesPerPixel - 1
        }
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            let row = bytes.advanced(by: y * image.bytesPerRow)
            for x in 0..<image.width {
                let alpha = row[x * bytesPerPixel + alphaOffset]
                guard alpha > 8 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func gradientColors(for hex: String) -> (CGColor, CGColor) {
        let base = NSColor(hex: hex) ?? NSColor.systemOrange
        let light = base.blended(withFraction: 0.26, of: .white) ?? base
        let dark = base.blended(withFraction: 0.16, of: .black) ?? base
        return (light.cgColor, dark.cgColor)
    }

    /// 生成 macOS 全套 icns
    static func icns(fromPNG pngData: Data, to url: URL) -> Bool {
        guard let image = NSImage(data: pngData) else { return false }
        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
        ]
        let iconset = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".iconset")
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for (px, name) in sizes {
            let target = iconset.appendingPathComponent(name)
            guard let data = resizePNG(image: image, to: CGFloat(px)) else { continue }
            try? data.write(to: target)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            try? FileManager.default.removeItem(at: iconset)
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 用位图重绘缩放，返回 PNG 数据（不依赖 lockFocus）
    static func resizePNG(image: NSImage, to px: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = Int(px)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        ctx.cgContext.interpolationQuality = .high
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        ctx.flushGraphics()
        NSGraphicsContext.current = prev
        return rep.representation(using: .png, properties: [:])
    }

    static func resize(image: NSImage, to px: CGFloat) -> NSImage? {
        guard let data = resizePNG(image: image, to: px) else { return nil }
        return NSImage(data: data)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}
