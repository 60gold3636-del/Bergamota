#!/usr/bin/env swift
// Renders the Bergamota boot-branding assets (transparent PNGs) used by
//   tools/mksplash.py          (power-on / fastboot images of the `logo` partition)
//   tools/mkbootlogo.py         (boot screen logo embedded in Enxerto)
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


// Fastboot screen illustration (tools/mkfbart.py -> enxerto/fbart.h): a laptop with a USB cable plugged in from below,
// the "connect to computer" picture. y-up, 2x of the 640x800 px Enxerto shows.
func scene(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let u = w / 640
    let pale = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1)
    let lime = NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.35, alpha: 1)
    let bg = NSColor(calibratedRed: 0x1a / 255.0, green: 0x59 / 255.0, blue: 0x33 / 255.0, alpha: 1)
    var lap = CGRect.zero
    let cfg = NSImage.SymbolConfiguration(pointSize: 400 * u, weight: .light).applying(.init(paletteColors: [pale]))
    if let img = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = img.size
        let k = 600 * u / s.width
        lap = CGRect(x: (w - s.width * k) / 2, y: h - 20 * u - s.height * k, width: s.width * k, height: s.height * k)
        img.draw(in: lap)
    }
    let lc = NSImage.SymbolConfiguration(pointSize: 120 * u, weight: .heavy).applying(.init(paletteColors: [lime]))
    if let leaf = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?.withSymbolConfiguration(lc) {
        let ls = leaf.size
        leaf.draw(in: CGRect(x: lap.midX - ls.width / 2, y: lap.midY + lap.height * 0.06 - ls.height / 2, width: ls.width, height: ls.height))
    }
    let x0 = lap.midX + lap.width * 0.28, y0 = lap.minY + lap.height * 0.12
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: y0))
    path.addCurve(to: CGPoint(x: w / 2, y: 120 * u), control1: CGPoint(x: x0 + 40 * u, y: y0 - 150 * u),
                  control2: CGPoint(x: w / 2, y: 330 * u))
    ctx.setLineCap(.round)
    ctx.addPath(path); ctx.setStrokeColor(bg.cgColor); ctx.setLineWidth(40 * u); ctx.strokePath()
    ctx.addPath(path); ctx.setStrokeColor(lime.cgColor); ctx.setLineWidth(18 * u); ctx.strokePath()
    let body = CGRect(x: w / 2 - 34 * u, y: 40 * u, width: 68 * u, height: 90 * u)
    ctx.setFillColor(bg.cgColor)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: -8 * u, dy: -8 * u), cornerWidth: 20 * u, cornerHeight: 20 * u, transform: nil)); ctx.fillPath()
    ctx.setFillColor(pale.cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil)); ctx.fillPath()
    let tip = CGRect(x: w / 2 - 26 * u, y: 8 * u, width: 52 * u, height: 40 * u)
    ctx.setFillColor(lime.cgColor)
    ctx.addPath(CGPath(roundedRect: tip, cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil)); ctx.fillPath()
    ctx.setFillColor(bg.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: w / 2 - 16 * u, y: 20 * u, width: 32 * u, height: 12 * u), cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)); ctx.fillPath()
}

// ABL fastboot (flash) illustration for tools/mksplash.py: computer -- cable --> memory chip with a write arrow.
// Transparent PNG, y-up, 1800x1200 (2x of 900x600).
func flashScene(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let u = w / 900
    let pale = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1)
    let lime = NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.35, alpha: 1)
    let dark = NSColor(calibratedRed: 0x0a / 255.0, green: 0x3d / 255.0, blue: 0x38 / 255.0, alpha: 1)
    func sym(_ name: String, _ pt: CGFloat, _ wt: NSFont.Weight, _ col: NSColor, _ width: CGFloat, cx: CGFloat, cy: CGFloat) -> CGRect {
        let cfg = NSImage.SymbolConfiguration(pointSize: pt * u, weight: wt).applying(.init(paletteColors: [col]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return .zero }
        let k = width * u / img.size.width
        let r = CGRect(x: cx * u - img.size.width * k / 2, y: cy * u - img.size.height * k / 2, width: img.size.width * k, height: img.size.height * k)
        img.draw(in: r)
        return r
    }
    let lap = sym("laptopcomputer", 400, .light, pale, 500, cx: 215, cy: 300)
    let chip = sym("memorychip.fill", 300, .regular, pale, 300, cx: 745, cy: 300)
    _ = sym("bolt.fill", 120, .heavy, lime, 90, cx: 745, cy: 300)
    _ = sym("arrow.down", 160, .heavy, lime, 140, cx: 745, cy: 510)
    // cable: out of the laptop's base, across to the chip's left pins
    let x0 = lap.maxX - 75 * u, y0 = lap.minY + lap.height * 0.20
    let x1 = chip.minX + 6 * u, y1 = chip.midY
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: y0))
    path.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: x0 + 90 * u, y: y0 - 50 * u), control2: CGPoint(x: x1 - 90 * u, y: y1))
    ctx.setLineCap(.round)
    ctx.addPath(path); ctx.setStrokeColor(dark.cgColor); ctx.setLineWidth(38 * u); ctx.strokePath()
    ctx.addPath(path); ctx.setStrokeColor(lime.cgColor); ctx.setLineWidth(18 * u); ctx.strokePath()
    // USB-C plug pointing right into the chip
    let body = CGRect(x: x1 - 8 * u, y: y1 - 34 * u, width: 80 * u, height: 68 * u)
    ctx.setFillColor(dark.cgColor)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: -8 * u, dy: -8 * u), cornerWidth: 20 * u, cornerHeight: 20 * u, transform: nil)); ctx.fillPath()
    ctx.setFillColor(lime.cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil)); ctx.fillPath()
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/assets"
png(bitmap(1024, 1024) { c, s, h in logo(c, s, h) }, "\(dir)/bergamota-logo.png")
png(text("Bergamota Project", 120, .semibold, NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1), kern: 4),
    "\(dir)/bergamota-wordmark.png")
png(text("FASTBOOT", 150, .heavy, NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.35, alpha: 1), kern: 8),
    "\(dir)/bergamota-fastboot.png")
png(bitmap(1280, 1600) { c, w, h in scene(c, w, h) }, "\(dir)/bergamota-fastboot-scene.png")
png(bitmap(1800, 1200) { c, w, h in flashScene(c, w, h) }, "\(dir)/bergamota-flash-scene.png")
png(text("BERGAMOTA", 150, .heavy, NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.55, alpha: 1), kern: 14), "\(dir)/bergamota-title.png")
png(text("Qualcomm bootloader \u{00B7} flash", 90, .medium, NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.85, alpha: 1), kern: 3), "\(dir)/bergamota-abl-sub.png")
print("assets written to \(dir)")
