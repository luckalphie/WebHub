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
            guard let glyph = glyph, let prepared = squareGlyph(glyph: glyph, box: rect.width * 0.58) else {
                return false
            }
            let gx = rect.midX - prepared.size.width / 2
            let gy = rect.midY - prepared.size.height / 2
            prepared.draw(in: NSRect(x: gx, y: gy, width: prepared.size.width, height: prepared.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        return png(from: rep)
    }

    /// 首字母兜底图标
    static func letterIcon(name: String, accent: String, size: CGFloat = 1024) -> Data? {
        guard let rep = makeBitmap(size: size) else { return nil }
        draw(rep: rep, size: size, accent: accent) { rect in
            let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            let text = letter.isEmpty ? "W" : letter
            let font = NSFont.systemFont(ofSize: rect.width * 0.44, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.96)
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let s = str.size()
            str.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            return true
        }
        return png(from: rep)
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
        let side = min(w, h)
        let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
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
