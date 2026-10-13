import AppKit
import Charts
import SwiftUI

/// Past results: a chart over time and a table, filtered by target; CSV export.
final class HistoryWindow {
    private var window: NSWindow?
    private let controller: TestController

    init(controller: TestController) { self.controller = controller }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = String(localized: "NetTorque History")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView(history: controller.history))
            w.setContentSize(NSSize(width: 710, height: 520))   // default, first opening only
            w.center()
            w.setFrameAutosaveName("NetTorque.Historia")         // last, so the saved size and place win
            DockPresence.track(w)
            window = w
        }
        if let window { DockPresence.show(window) }
    }
}

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    /// nil = every target.
    @State private var target: String?
    @State private var confirmClear = false

    private var targets: [String] { Array(Set(history.entries.map(\.server))).sorted() }
    private var shown: [HistoryEntry] { history.entries.filter { target == nil || $0.server == target } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Show", selection: $target) {
                    Text("All").tag(String?.none)
                    ForEach(targets, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button("Export CSV…") { export() }.disabled(shown.isEmpty)
                Button("Clear History…", role: .destructive) { confirmClear = true }.disabled(history.entries.isEmpty)
            }
            if shown.isEmpty {
                Text("No results yet — every finished test lands here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(shown) { e in
                        LineMark(x: .value("Time", e.date), y: .value("MB/s", e.uploadMBps), series: .value("Direction", "up"))
                            .foregroundStyle(TestView.macColor)
                        PointMark(x: .value("Time", e.date), y: .value("MB/s", e.uploadMBps))
                            .foregroundStyle(TestView.macColor)
                        LineMark(x: .value("Time", e.date), y: .value("MB/s", e.downloadMBps), series: .value("Direction", "down"))
                            .foregroundStyle(TestView.serverColor)
                        PointMark(x: .value("Time", e.date), y: .value("MB/s", e.downloadMBps))
                            .foregroundStyle(TestView.serverColor)
                    }
                }
                .chartYAxisLabel("MB/s")
                .frame(minHeight: 160)
                HStack(spacing: 16) {
                    Label("Upload", systemImage: "arrow.up").foregroundStyle(TestView.macColor)
                    Label("Download", systemImage: "arrow.down").foregroundStyle(TestView.serverColor)
                }
                .font(.callout)
                Table(shown.reversed()) {
                    TableColumn("When") { Text($0.date, format: .dateTime.day().month().hour().minute()) }
                        .width(min: 90, ideal: 95, max: 140)
                    TableColumn("Target") { Text(verbatim: $0.server) }
                        .width(min: 50, ideal: 60, max: 160)
                    TableColumn("Mode") { Text(Self.modeName($0.mode)) }
                        .width(min: 80, ideal: 100, max: 150)
                    TableColumn(Text(verbatim: "↑")) { Text(verbatim: TestController.mbps($0.uploadMBps)).foregroundStyle(TestView.macColor) }
                        .width(min: 55, ideal: 60, max: 100)
                    TableColumn(Text(verbatim: "↓")) { Text(verbatim: TestController.mbps($0.downloadMBps)).foregroundStyle(TestView.serverColor) }
                        .width(min: 55, ideal: 60, max: 100)
                    TableColumn("Link") { e in Text(verbatim: LinkSpeed(megabitsPerSecond: e.linkMbps)?.label ?? "—") }
                        .width(min: 60, ideal: 68, max: 100)
                    // Seven columns: the ideals plus the room SwiftUI adds to each (measured about 22 pt) must fit the
                    // default 680 pt window. 2026-10-11: "2401 Mb/s" and "z dysku na dysk" were cut at 55 and 90;
                    // widening only those two made the table scroll sideways.
                    // 2026-10-12: with more rows than fit, the vertical scroller takes about 15 pt and cut "405 MB/s" in
                    // English — ↑/↓ at 60 and the window at 710 leave room for it.
                    TableColumn("Through") { e in Text(verbatim: e.via.map(LinkMonitor.routeKind) ?? "—") }
                        .width(min: 50, ideal: 55, max: 120)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 710, minHeight: 420)   // 710 (the default) since 0.1.45: narrower cuts the seventh column or the speeds
        .confirmationDialog("Clear the whole history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        }
    }

    static func modeName(_ mode: String) -> String {
        switch mode {
        case "disk": return String(localized: "disk to disk")
        case "internet": return String(localized: "Internet")
        default: return String(localized: "from memory")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetTorque history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryStore.csv(shown).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()   // a full disk or a folder without write access said nothing (audit S-P3-02)
        }
    }
}
