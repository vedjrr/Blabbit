// Draws Blabbit's original app icon (no third-party assets) and writes
// app/Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// Design: macOS rounded-square tile, deep indigo → teal gradient, a white
// waveform whose bars rise and fall like a spoken word.
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Apple's icon grid: an 824 pt tile centred in 1024, corner radius ~185.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.20, green: 0.16, blue: 0.55, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.07, green: 0.55, blue: 0.64, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    // A gentle highlight across the top.
    let shine = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: shine, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Waveform: 9 rounded bars.
    let heights: [CGFloat] = [120, 230, 360, 470, 540, 430, 300, 200, 110]
    let barWidth: CGFloat = 46, gap: CGFloat = 26
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    for h in heights {
        let bar = CGRect(x: x, y: 512 - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(base * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/icon-1024.png"))
let out = root.appendingPathComponent("app/Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
