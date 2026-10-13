import Foundation

/// Every finished test, newest last, in Application Support (not UserDefaults: it grows).
struct HistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    let date: Date
    /// "memory" or "disk", as TestController.TestMode; "internet" in results from 0.1.22–0.1.33.
    let mode: String
    let server: String
    let bytes: Int64
    let uploadMBps: Double
    let downloadMBps: Double
    /// Link speed of the watched card when the test ended, in Mb/s (0 = no link).
    let linkMbps: Int
    var latencyMs: Double?
    /// The card the test went through (BSD name); nil in results from before 0.1.35.
    var via: String?
}

final class HistoryStore: ObservableObject {
    static let limit = 500

    @Published private(set) var entries: [HistoryEntry]
    private let file: URL?

    /// `file` nil keeps the history in memory only (tests).
    init(file: URL? = HistoryStore.defaultFile) {
        self.file = file
        entries = file.map(Self.load) ?? []
    }

    /// The saved history. A file that cannot be read is moved aside as `history.json.broken` instead of being
    /// overwritten by the next result (audit S-P3-01); a missing file is simply an empty history.
    static func load(_ file: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let entries = try? decoder.decode([HistoryEntry].self, from: data) { return entries }
        let aside = file.appendingPathExtension("broken")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        return []
    }

    static var defaultFile: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("com.mikagosz.NetTorque", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    func append(_ entry: HistoryEntry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let file, let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // MARK: CSV

    /// Dot as the decimal separator whatever the system language, so spreadsheets everywhere read it the same.
    static func csv(_ entries: [HistoryEntry]) -> String {
        var lines = ["date,mode,server,size_gb,upload_mb_s,download_mb_s,link_mb_s,latency_ms,via"]
        let iso = ISO8601DateFormatter()
        for e in entries {
            let size = e.mode == "internet" ? "" : String(e.bytes / 1_000_000_000)
            lines.append([iso.string(from: e.date), e.mode, quoted(e.server), size,
                          number(e.uploadMBps), number(e.downloadMBps), String(e.linkMbps),
                          e.latencyMs.map(number) ?? "", e.via ?? ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func number(_ v: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) }

    /// RFC 4180: quotes only when needed, inner quotes doubled. A name starting with = + - @ gets a leading
    /// apostrophe, so a spreadsheet shows it as text instead of running it as a formula — server names can come
    /// from the network (audit B-P3-03).
    static func quoted(_ s: String) -> String {
        let s = s.first.map { "=+-@".contains($0) } == true ? "'" + s : s
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
