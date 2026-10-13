import AppKit

/// The status bar image: the Ethernet port icon in the colour of the link speed
/// (1G blue, 2.5G green, 5G orange, 10G purple; other speeds grey, no link grey and crossed out).
/// Pictures are the PNGs in `MenuBar/`, 256 px, scaled down when drawn.
enum PortIcon {
    /// "port-5g", "wifi-2_5g", "wifi-none" … — Wi‑Fi pictures come from tools/wifi-icons.swift.
    private static func resourceName(for speed: LinkSpeed, wifi: Bool) -> String {
        (wifi ? "wifi-" : "port-") + speed.colourName
    }

    private static var pictures: [String: NSImage] = [:]

    private static func picture(_ name: String) -> NSImage? {
        if let cached = pictures[name] { return cached }
        let loaded = Bundle.main.image(forResource: name)
        pictures[name] = loaded
        return loaded
    }

    /// In the menu bar (24 pt high). Was 18 pt until 0.1.24; larger on request.
    static let menuBarSize: CGFloat = 22

    static func image(for speed: LinkSpeed, size: CGFloat = menuBarSize, wifi: Bool = false) -> NSImage {
        let source = picture(resourceName(for: speed, wifi: wifi || { if case .wifi = speed { return true }; return false }()))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}
