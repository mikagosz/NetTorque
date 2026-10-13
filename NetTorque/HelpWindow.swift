import AppKit
import SwiftUI

// The Help window: a big title, then sections with a picture of the app on one
// side and the steps on the other, sides taking turns. Numbered points on a picture match the numbered steps.
//
// The pictures are drawn by NetTorque itself, on sample data (server "NAS" at 192.0.2.10, "Mac", en5): the icons
// by PortIcon, the test, history and settings windows rendered off screen from the very same SwiftUI views,
// fed by a sample TestController with its own throwaway settings store. Nothing of the user's servers, names
// or history gets in, and every picture follows the app's language.

final class HelpWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = String(localized: "NetTorque Help")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView(pictures: HelpPictures.make()))
            // A fixed height: an `idealHeight` alone gave the window 432 pt (measured in DeskMount 0.1.50).
            w.setContentSize(NSSize(width: HelpView.width, height: HelpView.height))
            w.center()
            DockPresence.track(w)
            window = w
        }
        if let window { DockPresence.show(window) }
    }
}

/// A text of the Help window in the app's language (Localizable.xcstrings; the key is the English text).
private func L(_ english: String) -> String { Bundle.main.localizedString(forKey: english, value: english, table: nil) }

// MARK: - Sample data

enum HelpSample {
    static let suite = "com.mikagosz.NetTorque.help-sample"
    static let card = "Ethernet Adapter (en5)"
    static let address = "192.0.2.20"

    static var servers: [TestController.Server] {
        [TestController.Server(name: "NAS", host: "192.0.2.10", user: "admin", folder: "/srv/data"),
         TestController.Server(name: String(localized: "Backup"), host: "192.0.2.11", user: "", folder: "/tmp")]
    }

    static func outcome(_ up: Double = 405, _ down: Double = 464, date: Date = Date()) -> SpeedTest.Outcome {
        SpeedTest.Outcome(server: "NAS", bytes: 2_000_000_000, mode: .memory, uploadMBps: up, downloadMBps: down,
                          finished: date, via: "en5")
    }

    /// A controller on a separate, emptied settings store: it never starts, so it neither watches the card,
    /// posts notifications nor touches the user's settings.
    static func controller(link: LinkSpeed = .g5, outcome: SpeedTest.Outcome? = nil,
                           details: LinkDetails = LinkDetails()) -> TestController {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let list = servers
        d.set(try? JSONEncoder().encode(list), forKey: "servers")
        d.set(list[0].id.uuidString, forKey: "serverID")
        d.set("Mac", forKey: "macName")
        d.set("en5", forKey: "interface")
        d.set("memory", forKey: "testMode")
        d.set(2, forKey: "testSizeGB")
        d.set(true, forKey: "notify")
        d.set("peer-code-unused", forKey: "peerCode")
        let c = TestController(defaults: d)
        c.preview(link: LinkMonitor.State(speed: link, ipv4: address), outcome: outcome, note: nil,
                  details: details, cardName: card)
        return c
    }

    static var slowDetails: LinkDetails {
        var d = LinkDetails()
        d.maxSpeed = .g5
        d.fullDuplex = true
        d.mtu = 1500
        return d
    }

    /// Two weeks of tests to two servers, from memory and disk to disk.
    static var history: HistoryStore {
        let store = HistoryStore(file: nil)
        let now = Date()
        let ups: [Double] = [398, 404, 391, 407, 402, 395, 410, 388, 405, 399, 403, 409, 396, 405]
        let downs: [Double] = [461, 464, 458, 463, 465, 452, 466, 455, 464, 460, 463, 466, 459, 464]
        for i in 0..<ups.count {
            let disk = i % 4 == 3
            store.append(HistoryEntry(date: now.addingTimeInterval(Double(i - ups.count + 1) * 86_400), mode: disk ? "disk" : "memory",
                                      server: i % 5 == 2 ? String(localized: "Backup") : "NAS", bytes: 2_000_000_000,
                                      uploadMBps: disk ? ups[i] - 40 : ups[i], downloadMBps: disk ? downs[i] - 6 : downs[i],
                                      linkMbps: 5000, latencyMs: nil, via: "en5"))
        }
        return store
    }
}

/// Bitmaps of the app's own windows on sample data, made before the Help window opens.
struct HelpPictures {
    let test: NSImage
    let result: NSImage
    let slow: NSImage
    let details: NSImage
    let history: NSImage
    let settings: NSImage

    static func make() -> HelpPictures {
        defer { UserDefaults.standard.removePersistentDomain(forName: HelpSample.suite) }
        let test = Render.window(TestView(controller: HelpSample.controller()))
        let result = Render.window(TestView(controller: HelpSample.controller(outcome: HelpSample.outcome())))
        let slowController = HelpSample.controller(link: .g1, details: HelpSample.slowDetails)
        let slow = Render.window(TestView(controller: slowController))
        let details = Render.window(LinkDetailsView(hints: slowController.hints, details: slowController.linkDetails, errors: 0))
        let history = Render.window(HistoryView(history: HelpSample.history), size: NSSize(width: 710, height: 480))
        let settings = Render.window(SettingsView(controller: HelpSample.controller()), size: NSSize(width: 520, height: 1500))
        return HelpPictures(test: test, result: result, slow: slow, details: details, history: history, settings: settings)
    }
}

enum Render {
    /// A view drawn into a bitmap at twice its size, so it stays sharp on a Retina screen.
    static func bitmap(_ v: NSView) -> NSImage {
        let b = v.bounds
        guard b.width >= 1, b.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = b.size
        v.cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }

    /// A window's content rendered off screen: the same controls and texts the user sees.
    /// NSHostingView, not ImageRenderer — ImageRenderer draws segmented pickers as a yellow "no" sign.
    static func window<V: View>(_ view: V, size: NSSize? = nil) -> NSImage {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: s.width, height: s.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSApp.effectiveAppearance
        // In a plain view with the window's own background, so no strip of the form is left transparent.
        let back = NSView(frame: NSRect(origin: .zero, size: s))
        back.wantsLayer = true
        host.frame = back.bounds
        back.addSubview(host)
        w.contentView = back
        back.layoutSubtreeIfNeeded()
        var image = NSImage()
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            back.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            image = bitmap(back)
        }
        w.contentView = nil
        return image
    }
}

extension NSImage {
    /// A piece of the picture, in points from its top-left corner — like a cut-out screenshot.
    func cutOut(_ r: CGRect) -> NSImage {
        NSImage(size: r.size, flipped: false) { _ in
            self.draw(in: NSRect(x: -r.minX, y: r.maxY - self.size.height, width: self.size.width, height: self.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - The window

struct HelpView: View {
    static let width: CGFloat = 960
    static var height: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 900) - 80) }

    let pictures: HelpPictures
    /// For the bitmap of the whole page (`--export-help`): no scrolling, every section unfolded.
    var wholePage = false

    var body: some View {
        if wholePage {
            content.frame(width: Self.width).background(Color(nsColor: .windowBackgroundColor))
        } else {
            // Opens at the title: without the anchor the window came up scrolled a little way down.
            ScrollView { content }
                .defaultScrollAnchor(.top)
                .frame(width: Self.width, height: Self.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(HelpContent.sections.enumerated()), id: \.offset) { i, s in
                Divider().padding(.horizontal, 60)
                HelpSection(section: s, pictureLeft: i % 2 == 0, pictures: pictures, expanded: wholePage)
            }
            Divider().padding(.horizontal, 60)
            goodToKnow
            FractalSignature()
        }
        .padding(.bottom, 40)
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text(verbatim: L(HelpContent.title)).font(.system(size: 40, weight: .semibold))
            Text(verbatim: L(HelpContent.intro))
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            HeaderPicture().padding(.top, 8)
        }
        .padding(.top, 44).padding(.bottom, 48).padding(.horizontal, 60)
    }

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: L(HelpContent.goodToKnow)).font(.system(size: 30, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                      spacing: 20) {
                ForEach(HelpContent.cards, id: \.title) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: c.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        Text(verbatim: L(c.title)).font(.headline)
                        Text(verbatim: L(c.text)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.top, 40).padding(.horizontal, 60)
    }
}

private struct HelpSection: View {
    let section: HelpContent.Section
    let pictureLeft: Bool
    let pictures: HelpPictures
    @State var expanded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 44) {
            if pictureLeft { picture }
            text
            if !pictureLeft { picture }
        }
        .padding(.vertical, 44).padding(.horizontal, 60)
    }

    private var picture: some View {
        Group {
            switch section.picture {
            case .icon: IconPicture()
            case .menu: MenuPicture()
            case .test: WindowPicture(image: pictures.test, crop: Crop.test)
            case .result: WindowPicture(image: pictures.result, crop: Crop.result)
            case .slowLink: SlowLinkPicture(window: pictures.slow, details: pictures.details)
            case .history: WindowPicture(image: pictures.history, crop: Crop.history)
            case .servers: WindowPicture(image: pictures.settings, crop: Crop.servers)
            case .settings: WindowPicture(image: pictures.settings, crop: Crop.settings)
            }
        }
        .frame(width: 440)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L(section.title)).font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: L(section.lead)).font(.system(size: 15)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Marker(number: i + 1, small: true)
                        Text(verbatim: L(step)).font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let more = section.more {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(L(expanded ? HelpContent.less : HelpContent.more), systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                if expanded {
                    Text(verbatim: L(more)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Fractal 8 Dev signature at the end of Help, set like the hero of fractal8.eu: the logo large behind,
/// under the same veil as the site's video (darker at the edges and towards the bottom), and the text over
/// its lower part — "ENDLESS RECURSION" spaced 0.42 em in the accent (#7ee8f2 dark, #0a8796 light), then
/// "Fractal 8 Dev" in SF Pro Bold drawn together by −0.045 em with the site's gradient, then the site's line.
private struct FractalSignature: View {
    @Environment(\.colorScheme) private var scheme
    private static let logo: NSImage? = Bundle.main.url(forResource: "studio-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let dark = scheme == .dark
        let back = Color(nsColor: .windowBackgroundColor)
        let accent = dark ? Color(red: 126 / 255, green: 232 / 255, blue: 242 / 255) : Color(red: 10 / 255, green: 135 / 255, blue: 150 / 255)
        let gradient = LinearGradient(stops: [
            .init(color: dark ? .white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.4),
            .init(color: dark ? Color(red: 159 / 255, green: 163 / 255, blue: 171 / 255) : Color(red: 91 / 255, green: 95 / 255, blue: 102 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 560, height: 560)
                    .opacity(dark ? 0.75 : 0.55)
                    .frame(height: 440, alignment: .top)
                    .clipped()
                    // The site's veil (styles.css, .hero-sticky::after): edges and the bottom sink into the background.
                    .overlay(RadialGradient(stops: [.init(color: .clear, location: 0.35), .init(color: back.opacity(0.75), location: 1)],
                                            center: .center, startRadius: 0, endRadius: 300))
                    .overlay(LinearGradient(stops: [.init(color: back.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                                    .init(color: back.opacity(0.55), location: 0.62), .init(color: back, location: 0.92)],
                                            startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 0) {
                Text(verbatim: "ENDLESS RECURSION")
                    .font(.system(size: 12)).tracking(12 * 0.42).foregroundStyle(accent)
                    .padding(.bottom, 16)
                Text(verbatim: "Fractal 8 Dev")
                    .font(.system(size: 76, weight: .bold)).tracking(-76 * 0.045)
                    .foregroundStyle(gradient)
                Text(verbatim: L(HelpContent.signatureLine))
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(.top, 40)
    }
}

/// The numbered point on a picture, and the same number in front of a step.
private struct Marker: View {
    let number: Int
    var small = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: small ? 11 : 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: small ? 20 : 26, height: small ? 20 : 26)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: small ? 0 : 2))
            .shadow(color: .black.opacity(small ? 0 : 0.35), radius: 3, y: 1)
    }
}

/// Rounded card with a soft shadow — the frame every picture sits in.
private struct Frame<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// A calm desktop background for pictures of the menu bar.
private struct Desktop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.30, blue: 0.52),
                                Color(red: 0.78, green: 0.52, blue: 0.48)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The top of the screen: a strip of menu bar with NetTorque's icon among the system's.
private struct MenuBarStrip: View {
    var text: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            HStack(spacing: 4) {
                Image(nsImage: PortIcon.image(for: .g5))
                if let text { Text(verbatim: text).font(.system(size: 13, weight: .medium)).monospacedDigit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Image(systemName: "switch.2").font(.system(size: 13))
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.black.opacity(0.28))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Pictures

/// The title picture: the menu bar with the speed next to the icon, and the result as NetTorque shares it.
private struct HeaderPicture: View {
    var body: some View {
        let o = HelpSample.outcome()
        Frame {
            ZStack(alignment: .top) {
                Desktop()
                MenuBarStrip(text: TestController.menuBarTitle(.result, link: .g5, outcome: o))
                ResultCard(outcome: o, link: .g5, macName: "Mac", showNames: false)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .padding(.top, 62)
            }
            .frame(width: 660, height: 290)
        }
    }
}

/// Every look of the icon: the four link colours, another speed, no link, and the Wi‑Fi sign.
private struct IconPicture: View {
    private let colours: [(LinkSpeed, String)] = [(.g1, "1 Gb/s"), (.g2_5, "2.5 Gb/s"), (.g5, "5 Gb/s"), (.g10, "10 Gb/s")]

    var body: some View {
        Frame {
            ZStack(alignment: .top) {
                Desktop()
                VStack(spacing: 0) {
                    MenuBarStrip()
                    VStack(spacing: 22) {
                        HStack(spacing: 26) {
                            ForEach(colours, id: \.1) { c in tile(PortIcon.image(for: c.0, size: 44), c.0.label) }
                        }
                        .overlay(alignment: .topLeading) { Marker(number: 1).offset(x: -18, y: -14) }
                        HStack(spacing: 26) {
                            tile(PortIcon.image(for: .other(megabits: 100), size: 44), LinkSpeed.other(megabits: 100).label)
                                .overlay(alignment: .topLeading) { Marker(number: 2).offset(x: -18, y: -14) }
                            tile(PortIcon.image(for: .none, size: 44), LinkSpeed.none.label)
                            tile(PortIcon.image(for: .wifi(megabits: 2400), size: 44, wifi: true), "Wi‑Fi")
                                .overlay(alignment: .topLeading) { Marker(number: 3).offset(x: -18, y: -14) }
                        }
                    }
                    .padding(.top, 26)
                }
            }
            .frame(width: 440, height: 262)
        }
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ image: NSImage, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
            Text(verbatim: label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: 76)
    }
}

/// The right-click menu, with the same lines the app puts in it.
private struct MenuPicture: View {
    var body: some View {
        let o = HelpSample.outcome()
        Frame {
            ZStack(alignment: .topTrailing) {
                Desktop()
                MenuBarStrip()
                menu(o).frame(width: 330).padding(.top, 30).padding(.trailing, 70)
            }
            .frame(width: 440, height: 340)
        }
    }

    private func menu(_ o: SpeedTest.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(String(localized: "Card: \(HelpSample.card)"), dim: true).overlay(alignment: .leading) { Marker(number: 1).offset(x: -40) }
            row(String(localized: "Link speed: \(LinkSpeed.g5.label)"), dim: true)
            row(String(localized: "Address: \(HelpSample.address)"), dim: true)
            Divider().padding(.vertical, 4)
            row(String(localized: "Test: \("NAS")"), key: "⌘T").overlay(alignment: .leading) { Marker(number: 2).offset(x: -40) }
            row(TestController.summary(o), dim: true)
            Divider().padding(.vertical, 4)
            row(String(localized: "Open NetTorque Window…"), key: "⌘O").overlay(alignment: .leading) { Marker(number: 3).offset(x: -40) }
            row(String(localized: "History…"), key: "⌘Y")
            row(String(localized: "Settings…"), key: "⌘,")
            row(String(localized: "NetTorque Help…"))
            row(String(localized: "Quit NetTorque"), key: "⌘Q")
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private func row(_ title: String, key: String? = nil, dim: Bool = false) -> some View {
        HStack {
            Text(verbatim: title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let key { Text(verbatim: key).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(dim ? Color.secondary : Color.primary)
        .padding(.horizontal, 12).frame(height: 22)
    }
}

/// Where to cut a window picture and where its points go, in points of the rendered window
/// (measured on the PNG files from `--export-help`).
struct Crop {
    let rect: CGRect
    /// Points: a height alone sits in a margin left of the window (never over its text); with x, on the picture itself.
    let points: [CGPoint]
    var margin: CGFloat = 36
    /// rect.minY counted up from the window's bottom edge, for parts that move down when texts take more lines.
    var fromBottom = false

    func rect(in size: NSSize) -> CGRect {
        guard fromBottom else { return rect }
        return CGRect(x: rect.minX, y: size.height - rect.minY, width: rect.width, height: rect.height)
    }

    static let test = Crop(rect: CGRect(x: 0, y: 0, width: 380, height: 290),
                           points: [.init(x: -1, y: 50), .init(x: -1, y: 115), .init(x: -1, y: 187), .init(x: -1, y: 261)])
    static let result = Crop(rect: CGRect(x: 0, y: 276, width: 380, height: 112),
                             points: [.init(x: -1, y: 28), .init(x: 250, y: 51), .init(x: -1, y: 83)])   // 2: right of "NAS → Mac"
    static let history = Crop(rect: CGRect(x: 0, y: 0, width: 710, height: 480),
                              points: [.init(x: -1, y: 28), .init(x: -1, y: 130), .init(x: -1, y: 300), .init(x: 405, y: 28)])   // 4: left of Export CSV…
    // Ends above "Mounted in Finder": that list shows the user's own shares.
    static let servers = Crop(rect: CGRect(x: 0, y: 590, width: 520, height: 295),
                              points: [.init(x: -1, y: 58), .init(x: -1, y: 125), .init(x: -1, y: 171), .init(x: -1, y: 236)])
    static let settings = Crop(rect: CGRect(x: 0, y: 0, width: 520, height: 575),
                               points: [.init(x: -1, y: 68), .init(x: -1, y: 164), .init(x: -1, y: 257), .init(x: -1, y: 350)])
}

/// A cut-out of a real window, scaled to the picture column, with its points.
private struct WindowPicture: View {
    let image: NSImage
    let crop: Crop

    var body: some View {
        let width = min(440 - crop.margin, crop.rect.width)
        let scale = width / crop.rect.width
        let height = crop.rect.height * scale
        Frame {
            HStack(spacing: 0) {
                Color.clear.frame(width: crop.margin, height: height)
                Image(nsImage: image.cutOut(crop.rect(in: image.size))).resizable().interpolation(.high)
                    .frame(width: width, height: height)
                Spacer(minLength: 0)
            }
            .frame(width: 440, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(crop.points.enumerated()), id: \.offset) { i, p in
                        Marker(number: i + 1)
                            .position(x: p.x < 0 ? crop.margin / 2 + 2 : crop.margin + p.x * scale, y: p.y * scale)
                    }
                }
                .frame(width: 440, height: height, alignment: .topLeading)
            }
        }
    }
}

/// The warning next to the speed, and the popover it opens.
private struct SlowLinkPicture: View {
    let window: NSImage
    let details: NSImage

    var body: some View {
        let header = window.cutOut(CGRect(x: 0, y: 0, width: 380, height: 100))
        Frame {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: header).frame(width: 380, height: 100)
                Image(nsImage: details)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                    .padding(.leading, 40).padding(.top, -10).padding(.bottom, 20)
            }
            .padding(.leading, 30)
            .frame(width: 440, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                // Header 100 pt, the popover from 90 pt: its warning text at about +55, its table at about +175.
                ZStack(alignment: .topLeading) {
                    Marker(number: 1).position(x: 354, y: 46)
                    Marker(number: 2).position(x: 24, y: 145)
                    Marker(number: 3).position(x: 24, y: 265)
                }
                .frame(width: 440, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Bitmap of the Help page, for checking it without opening a window

/// `NetTorque --export-help <folder>` (language from `-AppleLanguages (pl)`): draws the Help page and the
/// window pictures into PNG files and quits. The app's normal start never runs: no menu bar icon, no
/// watching, no notifications, the user's settings untouched.
final class HelpExport: NSObject, NSApplicationDelegate {
    let folder: URL

    init(folder: URL) { self.folder = folder }

    static func fromArguments() -> HelpExport? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--export-help"), i + 1 < a.count else { return nil }
        return HelpExport(folder: URL(fileURLWithPath: a[i + 1], isDirectory: true))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let p = HelpPictures.make()
        for (name, image) in [("test", p.test), ("result", p.result), ("slow", p.slow), ("details", p.details),
                              ("history", p.history), ("settings", p.settings)] {
            save(image, "window-\(name)-\(lang).png")
        }
        let host = NSHostingView(rootView: HelpView(pictures: p, wholePage: true))
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: HelpView.width, height: 100),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        save(Render.bitmap(host), "help-\(lang).png")
        NSApp.terminate(nil)
    }

    private func save(_ image: NSImage, _ name: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent(name))
        print(folder.appendingPathComponent(name).path, Int(image.size.width), Int(image.size.height))
    }
}
