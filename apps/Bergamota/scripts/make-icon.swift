#!/usr/bin/env swift
// Generates Bergamota/Assets.xcassets/AppIcon.appiconset PNGs (citrus-green bergamot).
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // squircle tile
    let inset = s * 0.06
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.2, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()
    path.addClip()
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.35, alpha: 1),
                                 NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.30, alpha: 1)])!
    bg.draw(in: tile, angle: -60)
    // fruit
    let d = s * 0.50
    let fruit = CGRect(x: s * 0.5 - d / 2, y: s * 0.5 - d / 2 - s * 0.05, width: d, height: d * 0.96)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let fp = NSBezierPath(ovalIn: fruit)
    NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1),
                        NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.20, alpha: 1)])!
        .draw(in: fp, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
    ctx.restoreGState()
    // highlight
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: CGRect(x: fruit.minX + d * 0.17, y: fruit.midY + d * 0.12, width: d * 0.28, height: d * 0.18)).fill()
    // leaf (SF Symbol)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.30, weight: .bold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.20, alpha: 1)]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let ls = leaf.size
        leaf.draw(in: CGRect(x: s * 0.5 - ls.width * 0.05, y: fruit.maxY - ls.height * 0.35, width: ls.width, height: ls.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Bergamota/Assets.xcassets/AppIcon.appiconset"
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try! render(base * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(dir)/Contents.json"))
print("icon written to \(dir)")
