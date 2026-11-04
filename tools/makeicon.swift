import AppKit
import Foundation

// 生成 WebHub 主图标：渐变底 + 四宫格
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let inset = size * 0.098
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(path)
ctx.clip()

let c1 = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.96, alpha: 1).cgColor
let c2 = NSColor(srgbRed: 0.62, green: 0.29, blue: 0.87, alpha: 1).cgColor
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [c1, c2] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
}

// 四宫格白块
let pad = rect.width * 0.20
let cellGap = rect.width * 0.065
let cellSize = (rect.width - pad * 2 - cellGap) / 2
let corner = cellSize * 0.28

let positions: [(CGFloat, CGFloat)] = [
    (rect.minX + pad, rect.midY + cellGap / 2),
    (rect.midX + cellGap / 2, rect.midY + cellGap / 2),
    (rect.minX + pad, rect.minY + pad),
    (rect.midX + cellGap / 2, rect.minY + pad)
]

for (i, p) in positions.enumerated() {
    let alpha: CGFloat = i == 0 ? 1.0 : 0.82
    ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    let cell = CGRect(x: p.0, y: p.1, width: cellSize, height: cellSize)
    let cp = CGPath(roundedRect: cell, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(cp)
    ctx.fillPath()
}
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/webhub-icon.png")
try png.write(to: out)
print("wrote \(out.path)")
