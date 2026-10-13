import AppKit
import SwiftUI

/// A result as a picture to share: the speeds, the link, the mode and the date.
/// Device names only when the settings allow it — by default "Mac" and "Server", so a shared picture names nothing private.
struct ResultCard: View {
    let outcome: SpeedTest.Outcome
    let link: LinkSpeed
    let macName: String
    let showNames: Bool

    private var mac: String { showNames ? macName : String(localized: "Mac") }
    private var server: String {
        return showNames ? outcome.server : String(localized: "Server")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "NetTorque").font(.headline)
                    Text(verbatim: "\(TestController.modeName(outcome)) · \(link.label)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(nsImage: PortIcon.image(for: link, size: 30))   // Wi‑Fi rates pick the Wi‑Fi picture themselves
            }
            HStack(alignment: .top, spacing: 28) {
                speed(outcome.uploadMBps, "arrow.up", TestView.macColor,
                      TestView.route(from: (mac, TestView.macColor), to: (server, TestView.serverColor)))
                speed(outcome.downloadMBps, "arrow.down", TestView.serverColor,
                      TestView.route(from: (server, TestView.serverColor), to: (mac, TestView.macColor)))
            }
            Text(outcome.finished, format: .dateTime.day().month().year().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func speed(_ mbps: Double, _ arrow: String, _ color: Color, _ caption: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(TestController.mbps(mbps), systemImage: arrow).font(.title.monospacedDigit()).foregroundStyle(color)
            caption.font(.callout)
        }
    }

    /// PNG at twice the size, in the light look whatever the system uses (pictures travel to other screens).
    @MainActor static func png(_ card: ResultCard) -> Data? {
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor static func copy(_ card: ResultCard) {
        guard let data = png(card) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }

    @MainActor static func save(_ card: ResultCard) {
        guard let data = png(card) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetTorque result.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()   // a full disk or a folder without write access said nothing (audit S-P3-02)
        }
    }
}

extension TestController {
    /// The picture of a result, as shared from the window.
    func card(_ o: SpeedTest.Outcome) -> ResultCard {
        ResultCard(outcome: o, link: link.speed, macName: macName, showNames: shareNames)
    }
}
