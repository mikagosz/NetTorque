import AppKit
import SwiftUI

/// The test window opened by a left click on the status icon.
final class TestWindow {
    private var window: NSWindow?
    private let controller: TestController
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let openHelp: () -> Void

    init(controller: TestController, openSettings: @escaping () -> Void, openHistory: @escaping () -> Void,
         openHelp: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.openHelp = openHelp
    }

    func show() {
        controller.refreshRoutes()
        if window == nil {
            // Fixed width; the height follows what the window shows (0.1.37), the position is remembered.
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "NetTorque"
            w.isReleasedWhenClosed = false
            let view = TestView(controller: controller, openSettings: openSettings, openHistory: openHistory, openHelp: openHelp) { [weak w] height in
                guard let w else { return }
                Self.fit(w, height: height)
            }
            let hosting = NSHostingView(rootView: view)
            w.contentView = hosting
            w.setContentSize(NSSize(width: TestView.width, height: hosting.fittingSize.height))
            w.center()
            w.setFrameAutosaveName("NetTorque.Okno")               // remembers where the window was
            Self.fit(w, height: hosting.fittingSize.height)        // after the saved frame, which may hold an old height
            DockPresence.track(w)
            window = w
        }
        if let window { DockPresence.show(window) }
    }

    /// Content height to `height`, keeping the top edge where it is, so the window grows and shrinks downwards.
    private static func fit(_ w: NSWindow, height: CGFloat) {
        let content = w.contentRect(forFrameRect: w.frame)
        guard height > 0, abs(content.height - height) > 0.5 || content.width != TestView.width else { return }
        let top = w.frame.maxY
        var frame = w.frameRect(forContentRect: NSRect(x: content.minX, y: content.minY, width: TestView.width, height: height))
        frame.origin.y = top - frame.height
        w.setFrame(frame, display: true, animate: false)
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TestView: View {
    @ObservedObject var controller: TestController
    var openSettings: () -> Void = {}
    var openHistory: () -> Void = {}
    var openHelp: () -> Void = {}
    /// Called with the height the content needs, so the window can follow it.
    var onHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var showHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: PortIcon.image(for: controller.link.speed, size: 56, wifi: controller.isWiFi))
                    .id(scheme)   // the port frame follows light/dark
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(controller.link.speed.label).font(.title2.bold())
                        if let hint = controller.hints.first {
                            Button { showHint.toggle() } label: {
                                Label(hint.shortText, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            .help(hint.text)
                            .popover(isPresented: $showHint, arrowEdge: .bottom) {
                                LinkDetailsView(hints: controller.hints, details: controller.linkDetails,
                                                errors: controller.errorsAtLinkUp.map { controller.linkDetails.errors &- $0 })
                            }
                        }
                    }
                    Text("\(controller.interfaceName) · \(controller.link.ipv4 ?? "—")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button(action: openSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Settings")
                    Button(action: openHistory) { Image(systemName: "clock.arrow.circlepath") }
                        .buttonStyle(.borderless)
                        .help("History")
                    Button(action: openHelp) { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .help("NetTorque Help")
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Above the form, across the whole window (0.1.31; three segments did not fit in the form's column).
            Picker("Mode", selection: $controller.testMode) {
                Text("From Memory").tag(TestController.TestMode.memory)
                Text("Disk to Disk").tag(TestController.TestMode.disk)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.running)

            Form {
                Picker("Server", selection: $controller.serverID) {
                    ForEach(controller.servers) { Text($0.name).tag($0.id) }
                }
                Picker("Size", selection: $controller.sizeGB) {
                    ForEach(TestController.sizes, id: \.self) { Text("\($0) GB").tag($0) }
                }
                // A mounted share takes the system's way whatever is chosen, so it shows Automatically, greyed out.
                Picker("Through", selection: Binding(get: { controller.chosenRoute ?? "" }, set: { controller.route = $0 })) {
                    Text("Automatically").tag("")
                    ForEach(controller.routeChoices, id: \.bsd) { Text(verbatim: LinkMonitor.routeName($0.bsd)).tag($0.bsd) }
                    if let r = controller.chosenRoute, !controller.routeChoices.contains(where: { $0.bsd == r }) {
                        Text(verbatim: LinkMonitor.routeName(r)).tag(r)   // chosen earlier, no address now
                    }
                }
                .disabled(controller.server.isFolder)
                .help(controller.server.isFolder ? String(localized: "A network folder goes the way the system sends it.") : "")
            }
            .disabled(controller.running)

            HStack {
                if controller.running {
                    Button("Stop") { controller.cancelTest() }
                        .controlSize(.large)
                    ProgressView(value: controller.progress) { Text(controller.status).font(.callout) }
                } else {
                    Button("Test") { controller.startTest() }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!controller.canTest)
                    // Empties the window after a test; the result stays in the history.
                    if controller.lastOutcome != nil || controller.lastNote != nil {
                        Spacer(minLength: 0)
                        Button("Clear") { controller.clearResult() }
                            .controlSize(.large)
                            .help("Clear the result from the window — it stays in the history")
                    }
                }
            }

            if !controller.server.isFolder, controller.server.host.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Enter the server address in the settings (the gear in the corner).").foregroundStyle(.secondary)
            }
            if let o = controller.lastOutcome {
                HStack(alignment: .top, spacing: 28) {
                    result(o.uploadMBps, arrow: "arrow.up", color: Self.macColor,
                           caption: Self.route(from: (controller.macName, Self.macColor), to: (o.server, Self.serverColor)))
                    result(o.downloadMBps, arrow: "arrow.down", color: Self.serverColor,
                           caption: Self.route(from: (o.server, Self.serverColor), to: (controller.macName, Self.macColor)))
                }
                HStack(spacing: 10) {
                    Text(TestController.details(o)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { ResultCard.copy(controller.card(o)) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy as Image")
                    Button { ResultCard.save(controller.card(o)) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .help("Save Image…")
                }
            }
            if let note = controller.lastNote {
                Text(note).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
        .onPreferenceChange(ContentHeight.self) { onHeight($0) }
    }

    /// Fixed; the height follows the content (a long error wraps instead of being cut at the bottom).
    static let width: CGFloat = 380

    /// Each device has its colour; a speed takes the colour of the device that sends.
    static let macColor = Color(nsColor: .systemBlue)
    static let serverColor = Color(nsColor: .systemGreen)

    /// "Mac → nas" with each name in its device colour.
    static func route(from: (String, Color), to: (String, Color)) -> Text {
        Text("\(Text(from.0).foregroundStyle(from.1))\(Text(" → ").foregroundStyle(.secondary))\(Text(to.0).foregroundStyle(to.1))")
    }

    private func result(_ mbps: Double, arrow: String, color: Color, caption: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(TestController.mbps(mbps), systemImage: arrow)
                .font(.title.monospacedDigit())
                .foregroundStyle(color)
            caption.font(.callout)
        }
    }
}

/// The popover behind the warning next to the speed: what is wrong, then what the card reports.
struct LinkDetailsView: View {
    let hints: [LinkHint]
    let details: LinkDetails
    /// Errors since the link came up.
    let errors: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(hints.indices, id: \.self) { i in
                Label(hints[i].text, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Card supports", details.maxSpeed?.label ?? "—")
                row("Duplex", details.halfDuplex ? String(localized: "half") : details.fullDuplex ? String(localized: "full") : "—")
                row("Flow control", details.flowControl ? String(localized: "on") : String(localized: "off"))
                row("Energy saving (EEE)", details.energyEfficient ? String(localized: "on") : String(localized: "off"))
                row("MTU", details.mtu.map { "\($0)" } ?? "—")
                row("Errors since link up", errors.map { "\($0)" } ?? "—")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func row(_ name: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(verbatim: value)
        }
    }
}
