// Makes NetTorque/MenuBar/wifi-*.png from the port icons: the same frame and colours, a Wi‑Fi sign inside.
// Run from the project folder: swift tools/wifi-icons.swift
import AppKit

let folder = "NetTorque/MenuBar/"
let tiers = ["1g", "2_5g", "5g", "10g", "other"]

func load(_ name: String) -> NSBitmapImageRep {
    NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: folder + name + ".png")))!
}

/// Pixel coordinates measured on the port icons (256 px, y from the top): frame 3…24, white gap 24…38,
/// inner shape 38…216 across and 52…204 down.
func make(base: String, out: String, slash: Bool) {
    let src = load(base)
    let colour = src.colorAt(x: 10, y: 128)!   // the frame
    let size = NSSize(width: 256, height: 256)
    let image = NSImage(size: size, flipped: true) { _ in
        src.draw(in: NSRect(origin: .zero, size: size))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 25, y: 37, width: 206, height: 180), xRadius: 10, yRadius: 10).fill()
        colour.setFill()
        NSBezierPath(roundedRect: NSRect(x: 38, y: 52, width: 178, height: 152), xRadius: 12, yRadius: 12).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .bold).applying(.init(paletteColors: [.white]))
        if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let r = NSRect(x: 127 - wifi.size.width / 2, y: 128 - wifi.size.height / 2, width: wifi.size.width, height: wifi.size.height)
            wifi.draw(in: r)
        }
        if slash {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 14, y: 22)); line.line(to: NSPoint(x: 242, y: 232))
            line.lineCapStyle = .round
            NSColor.white.setStroke(); line.lineWidth = 34; line.stroke()
            NSColor(srgbRed: 0xED / 255, green: 0x44 / 255, blue: 0x33 / 255, alpha: 1).setStroke(); line.lineWidth = 22; line.stroke()
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + out + ".png"))
    print(out)
}

_ = NSApplication.shared
for t in tiers { make(base: "port-" + t, out: "wifi-" + t, slash: false) }
make(base: "port-other", out: "wifi-none", slash: true)
