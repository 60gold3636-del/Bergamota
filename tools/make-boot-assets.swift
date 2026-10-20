#!/usr/bin/env swift
// Renders the Bergamota boot-branding assets (transparent PNGs) used by
//   tools/mksplash.py          (power-on / fastboot images of the `logo` partition)
//   shim/gen_bootlogo.py       (boot screen logo embedded in the shim)
// Same fruit + leaf motif as apps/Bergamota/scripts/make-icon.swift, without the tile,
// with a brighter leaf so it reads on the dark bergamot green background.
// Usage: swift tools/make-boot-assets.swift tools/assets
import AppKit

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, CGFloat(w), CGFloat(h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func logo(_ ctx: CGContext, _ s: CGFloat, _: CGFloat) {
    let d = s * 0.62
    let fruit = CGRect(x: s * 0.5 - d / 2, y: s * 0.5 - d / 2 - s * 0.06, width: d, height: d * 0.96)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05,
                  color: NSColor.black.withAlphaComponent(0.4).cgColor)
    let fp = NSBezierPath(ovalIn: fruit)
    NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1),
                        NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.20, alpha: 1)])!
        .draw(in: fp, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: CGRect(x: fruit.minX + d * 0.17, y: fruit.midY + d * 0.12, width: d * 0.28, height: d * 0.18)).fill()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .bold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.55, green: 0.86, blue: 0.30, alpha: 1)]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let ls = leaf.size
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        leaf.draw(in: CGRect(x: s * 0.5 - ls.width * 0.05, y: fruit.maxY - ls.height * 0.42, width: ls.width, height: ls.height))
        ctx.restoreGState()
    }
}

func text(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat) -> NSBitmapImageRep {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    let a = NSAttributedString(string: str, attributes: attrs)
    let sz = a.size()
    let w = Int(ceil(sz.width)) + 8, h = Int(ceil(sz.height)) + 8
    return bitmap(w, h) { _, _, _ in a.draw(at: NSPoint(x: 4, y: 4)) }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/assets"
png(bitmap(1024, 1024) { c, s, h in logo(c, s, h) }, "\(dir)/bergamota-logo.png")
png(text("Bergamota Project", 120, .semibold, NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1), kern: 4),
    "\(dir)/bergamota-wordmark.png")
png(text("FASTBOOT", 150, .heavy, NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.35, alpha: 1), kern: 8),
    "\(dir)/bergamota-fastboot.png")
print("assets written to \(dir)")
