// Pastes NetTorque windows onto a laptop mockup picture for the website (2000×1300, as the other program mockups).
import AppKit
let args = CommandLine.arguments
let base = NSImage(contentsOfFile: args[1])!
let out = args[2]
let shots = URL(fileURLWithPath: args[3])
let menuIcon = NSImage(contentsOfFile: args[4])!
let W = 2000, H = 1300
// The mockup's screen: 1610 px across for a 1470 pt wide display → 1.095 px per point; the window pictures are at 2×.
let scale: CGFloat = 1.095 / 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
base.draw(in: NSRect(x: 0, y: 0, width: W, height: H), from: .zero, operation: .copy, fraction: 1)

func paste(_ file: String, x: CGFloat, y: CGFloat) {
    let img = NSImage(contentsOf: shots.appendingPathComponent(file))!
    let px = img.representations[0]
    let w = CGFloat(px.pixelsWide) * scale, h = CGFloat(px.pixelsHigh) * scale
    let r = NSRect(x: x, y: CGFloat(H) - y - h, width: w, height: h)   // `y` counted from the top, AppKit from the bottom
    let path = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = 34; shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set(); NSColor.black.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    // Traffic lights in colour: a picture of a window off screen draws them grey (inactive).
    let lights = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1), NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                  NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
    for (i, colour) in lights.enumerated() {
        let cx = x + (33 + CGFloat(i) * 45.5) * scale, cy = CGFloat(H) - (y + 33 * scale), rad = 12.5 * scale
        colour.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)).fill()
    }
    NSColor.white.withAlphaComponent(0.12).setStroke(); path.lineWidth = 1.5; path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
paste("okno-historia.png", x: 860, y: 150)
paste("okno-test.png", x: 360, y: 205)
// NetTorque in the menu bar, left of the clock icon already there (x 1471, bar centred on y 95).
let s: CGFloat = 22
menuIcon.draw(in: NSRect(x: 1428 - s / 2, y: CGFloat(H) - 95 - s / 2, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)
// Optional fifth argument: the app icon as the system draws it (512 px, the rounded square is 80.5 % of it), put on
// the first empty tile of the mockup's Dock (48 px tiles, centre x 920, y 1083 from the top).
if args.count > 5, let dockIcon = NSImage(contentsOfFile: args[5]) {
    let d: CGFloat = 48 / 0.805
    dockIcon.draw(in: NSRect(x: 920 - d / 2, y: CGFloat(H) - 1083 - d / 2, width: d, height: d), from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
