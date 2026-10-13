import Foundation
import Combine
import ServiceManagement

/// One state shared by the status menu and the window: the link, the chosen test and its result.
final class TestController: ObservableObject {
    struct Server: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        /// IP address, host name or an alias from ~/.ssh/config.
        var host: String
        /// Empty: ~/.ssh/config (or the Mac user name) decides.
        var user: String
        /// Where the disk-to-disk test file goes on the server; for a network folder, its path on the Mac.
        var folder: String
        /// A folder mounted in Finder (SMB, NFS …) instead of an SSH server; nil in settings from before 0.1.26.
        var isNetworkFolder: Bool?
        /// Another Mac running NetTorque: `host` is its Bonjour name, this its 6-digit code. Nil for other servers.
        var peerCode: String?

        var isFolder: Bool { isNetworkFolder == true && !isPeer }
        var isPeer: Bool { peerCode != nil }

        var sshDestination: String { user.trimmingCharacters(in: .whitespaces).isEmpty ? host : "\(user)@\(host)" }
    }

    static let sizes: [Int] = [1, 2, 5, 10]   // GB, 1 GB = 10^9 B
    /// "0.1.16", shown in the status menu and the settings.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    /// First launch: one empty entry to fill in the settings.
    static let defaultServers = [Server(name: String(localized: "Server"), host: "", user: "", folder: "/tmp")]

    @Published private(set) var link = LinkMonitor.State(speed: .none, ipv4: nil)
    @Published private(set) var linkDetails = LinkDetails()
    /// Error count when the current link came up; nil while there is no link.
    @Published private(set) var errorsAtLinkUp: UInt64?
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var lastOutcome: SpeedTest.Outcome?
    @Published private(set) var lastNote: String?

    @Published var servers: [Server] { didSet { save(servers, "servers") } }
    @Published var serverID: UUID { didSet { defaults.set(serverID.uuidString, forKey: "serverID") } }
    /// "internet" (0.1.22–0.1.33) is gone — removed 2026-10-10; a stored "internet" reads as memory.
    enum TestMode: String, CaseIterable { case memory, disk }
    /// Stored under `testMode` as "memory" or "disk".
    @Published var testMode: TestMode { didSet { defaults.set(testMode.rawValue, forKey: "testMode") } }
    @Published var sizeGB: Int { didSet { defaults.set(sizeGB, forKey: "testSizeGB") } }
    /// The card a test goes through (BSD name, key `testRoute`); empty: the system decides. Not for a network
    /// folder — a mounted share always takes the system's way.
    @Published var route: String { didSet { defaults.set(route, forKey: "testRoute") } }
    /// Cards with an address, refreshed when the window opens and before a test.
    @Published private(set) var routeChoices: [(bsd: String, name: String)] = []
    /// Detected on first launch, editable in the settings.
    @Published var macName: String { didSet { defaults.set(macName, forKey: "macName") } }
    /// "Receive tests from other Macs" (key `receiveTests`, default off) and this Mac's code (`peerCode`).
    @Published var receiveTests: Bool {
        didSet { defaults.set(receiveTests, forKey: "receiveTests"); updateReceiver() }
    }
    @Published private(set) var ownPeerCode: String
    /// nil while listening (or off); otherwise why receiving does not work.
    @Published private(set) var receiverProblem: String?
    private let receiver = PeerReceiver()

    func newPeerCode() {
        ownPeerCode = PeerProtocol.newCode()
        defaults.set(ownPeerCode, forKey: "peerCode")
        updateReceiver()
    }

    private func updateReceiver() {
        if receiveTests {
            receiver.onStateChange = { [weak self] problem in self?.receiverProblem = problem }
            receiver.start(name: macName, code: ownPeerCode)
        } else {
            receiver.stop()
            receiverProblem = nil
        }
    }

    /// Another Mac found on the network, with the code shown in its settings.
    /// Pairing the same Mac again updates its code instead of adding a second entry.
    func addPeer(name: String, code: String) {
        if let i = servers.firstIndex(where: { $0.isPeer && $0.host == name }) {
            servers[i].peerCode = code
            serverID = servers[i].id
            return
        }
        var s = Server(name: name, host: name, user: "", folder: "")
        s.peerCode = code
        servers.append(s)
        serverID = s.id
    }

    enum MenuBarText: String, CaseIterable { case none, link, result }
    /// Next to the icon in the menu bar: nothing (default), the link speed, or the last result. Key `menuBarText`.
    @Published var menuBarText: MenuBarText { didSet { defaults.set(menuBarText.rawValue, forKey: "menuBarText") } }
    /// Shared result pictures name the Mac and the server (default off: "Mac" and "Server").
    @Published var shareNames: Bool { didSet { defaults.set(shareNames, forKey: "shareNames") } }
    @Published var notifyOnDrop: Bool {
        didSet { defaults.set(notifyOnDrop, forKey: "notify"); if notifyOnDrop { askForNotifications() } }
    }
    /// Which speed counts as a fall (default: the best this card has had).
    @Published var dropFloor: DropFloor { didSet { defaults.set(dropFloor.rawValue, forKey: "dropFloor") } }
    /// Best settled speed per card, in Mb/s, under `bestSpeeds` — the floor for `DropFloor.best`.
    @Published private(set) var bestSpeeds: [String: Int]
    /// Notifications are turned off for NetTorque in System Settings; the settings window says so.
    @Published private(set) var notificationsDenied = false
    /// Mirrors SMAppService; changed only through setAutostart(_:).
    @Published private(set) var autostart = SMAppService.mainApp.status
    @Published var interfaceBSD: String {
        didSet { defaults.set(interfaceBSD, forKey: "interface"); if interfaceBSD != oldValue { watch(interfaceBSD) } }
    }

    private(set) var monitor: LinkMonitor
    /// Every finished test (Application Support/com.mikagosz.NetTorque/history.json).
    lazy var history = HistoryStore()
    private let defaults: UserDefaults
    private var test: SpeedTest?
    /// Made on first use (start): a controller that never starts — the Help window's sample — must not take over
    /// the notification centre's delegate from the app's own controller.
    private lazy var notifier = Notifier()
    private var lastLinked: LinkSpeed?        // last settled speed while connected
    private var settled: LinkSpeed = .none    // last speed that held for 3 s
    private var pending: DispatchWorkItem?
    private var afterFinish: (() -> Void)?

    /// `defaults`: the app's own settings; the Help window passes a separate, throwaway store with sample servers,
    /// so nothing it draws can touch the user's settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let list = (defaults.data(forKey: "servers")).flatMap { try? JSONDecoder().decode([Server].self, from: $0) }
        let merged = Self.withoutDuplicates((list?.isEmpty == false) ? list! : Self.defaultServers,
                                            selected: defaults.string(forKey: "serverID").flatMap(UUID.init(uuidString:)))
        let loaded = merged.servers
        servers = loaded
        serverID = loaded.first { $0.id == merged.selected }?.id ?? loaded[0].id
        testMode = defaults.string(forKey: "testMode").flatMap(TestMode.init(rawValue:)) ?? .memory
        let size = defaults.integer(forKey: "testSizeGB")
        sizeGB = Self.sizes.contains(size) ? size : 2
        route = defaults.string(forKey: "testRoute") ?? ""
        macName = defaults.string(forKey: "macName") ?? Self.detectedMacName
        shareNames = defaults.bool(forKey: "shareNames")
        menuBarText = defaults.string(forKey: "menuBarText").flatMap(MenuBarText.init(rawValue:)) ?? .none
        receiveTests = defaults.bool(forKey: "receiveTests")
        ownPeerCode = defaults.string(forKey: "peerCode").flatMap { PeerProtocol.isValidCode($0) ? $0 : nil } ?? PeerProtocol.newCode()
        notifyOnDrop = defaults.object(forKey: "notify") as? Bool ?? true
        dropFloor = defaults.string(forKey: "dropFloor").flatMap(DropFloor.init(rawValue:)) ?? .best
        bestSpeeds = defaults.dictionary(forKey: "bestSpeeds") as? [String: Int] ?? [:]
        let bsd = defaults.string(forKey: "interface") ?? LinkMonitor.preferredWiredInterface()
        interfaceBSD = bsd
        monitor = LinkMonitor(bsdName: bsd)
        monitor.onChange = { [weak self] state in self?.linkChanged(state) }
        monitor.onDetails = { [weak self] details in self?.detailsChanged(details) }
        if defaults.data(forKey: "servers") == nil || (list.map { $0.count != loaded.count } ?? false) { save(servers, "servers") }
        defaults.set(serverID.uuidString, forKey: "serverID")
        if defaults.string(forKey: "peerCode") != ownPeerCode { defaults.set(ownPeerCode, forKey: "peerCode") }
        if defaults.string(forKey: "macName") == nil { defaults.set(macName, forKey: "macName") }
        if defaults.string(forKey: "interface") == nil { defaults.set(bsd, forKey: "interface") }
        defaults.removeObject(forKey: "server")   // 0.1.3–0.1.5 kept the server by name
    }

    /// "Mac" from a computer name such as "Mac (name)".
    static var detectedMacName: String {
        let name = Host.current().localizedName ?? "Mac"
        return name.components(separatedBy: " (").first ?? name
    }

    var server: Server { servers.first { $0.id == serverID } ?? servers[0] }

    /// "Ethernet Adapter (en5)" — the BSD name is added only when the system name lacks it.
    var interfaceName: String {
        if let sampleCardName { return sampleCardName }
        let name = LinkMonitor.displayName(monitor.bsdName)
        return name.contains(monitor.bsdName) ? name : "\(name) (\(monitor.bsdName))"
    }

    /// From a server found on the network: an SSH server at `host`, or a network folder still to be chosen.
    /// A server already on the list is selected instead of being added again (0.1.39: each Add made a copy).
    func addFound(name: String, host: String, folder: Bool, path: String = "") {
        if let same = Self.existing(in: servers, name: name, host: host, folder: folder, path: path) {
            serverID = same.id
            return
        }
        var s = Server(name: name, host: folder ? "" : host, user: "", folder: folder ? path : "/tmp")
        if folder { s.isNetworkFolder = true }
        servers.append(s)
        serverID = s.id
    }

    /// The entry a found server or share would duplicate: the same folder, or an SSH server at the same address
    /// or under the same found name — a Mac with two cards answers at a different address each time (0.1.40).
    static func existing(in list: [Server], name: String = "", host: String, folder: Bool, path: String) -> Server? {
        list.first { s in
            folder ? s.isFolder && s.folder == path
                   : !s.isFolder && !s.isPeer && s.user.trimmingCharacters(in: .whitespaces).isEmpty
                     && ((!host.isEmpty && s.host == host) || (!name.isEmpty && s.name == name))
        }
    }

    /// An SSH entry with no address yet: the first-launch "Server" or an untouched "New Server".
    static func isBlank(_ s: Server) -> Bool {
        !s.isFolder && !s.isPeer && s.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Entries identical in everything but their id merged into the first one; `selected` follows its twin.
    /// Cleans up the copies that repeated Add and Pair clicks made before 0.1.39.
    static func withoutDuplicates(_ list: [Server], selected: UUID?) -> (servers: [Server], selected: UUID?) {
        var kept: [Server] = []
        var choice = selected
        for s in list {
            if let twin = kept.first(where: { $0.name == s.name && $0.host == s.host && $0.user == s.user && $0.folder == s.folder
                                              && $0.isNetworkFolder == s.isNetworkFolder && $0.peerCode == s.peerCode }) {
                if choice == s.id { choice = twin.id }
            } else {
                kept.append(s)
            }
        }
        // Entries with no address are dropped once something real is on the list (the first-launch "Server" stayed
        // forever next to the servers added later, 0.1.40); the list never ends up empty.
        if kept.contains(where: { !isBlank($0) }) {
            let blanks = Set(kept.filter(isBlank).map(\.id))
            kept.removeAll { blanks.contains($0.id) }
            if let c = choice, blanks.contains(c) { choice = kept.first?.id }
        }
        return (kept, choice)
    }

    /// Add Server while an entry still has no address selects that one instead of adding another (0.1.40:
    /// every click made one more "New Server").
    func addServer() {
        if let blank = servers.first(where: Self.isBlank) {
            serverID = blank.id
            return
        }
        let s = Server(name: String(localized: "New Server"), host: "", user: "", folder: "/tmp")
        servers.append(s)
        serverID = s.id
    }

    func removeServer(_ id: UUID) {
        guard servers.count > 1 else { return }
        servers.removeAll { $0.id == id }
        if !servers.contains(where: { $0.id == serverID }) { serverID = servers[0].id }
    }

    /// The watched card is Wi‑Fi (checked once per card).
    private(set) lazy var isWiFi = LinkMonitor.isWiFi(monitor.bsdName)

    /// The best speed the watched card has had (nil until it has held a link for 3 s).
    var bestSpeed: LinkSpeed? { bestSpeeds[monitor.bsdName].flatMap { LinkSpeed(megabitsPerSecond: $0) } }

    func resetBestSpeed() {
        bestSpeeds[monitor.bsdName] = nil
        defaults.set(bestSpeeds, forKey: "bestSpeeds")
    }

    private func watch(_ bsd: String) {
        monitor.stop()
        pending?.cancel()
        lastLinked = nil
        settled = .none
        errorsAtLinkUp = nil
        isWiFi = LinkMonitor.isWiFi(bsd)
        monitor = LinkMonitor(bsdName: bsd)
        monitor.onChange = { [weak self] state in self?.linkChanged(state) }
        monitor.onDetails = { [weak self] details in self?.detailsChanged(details) }
        monitor.start()
    }

    private func save(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func refreshRoutes() {
        let list = LinkMonitor.routeChoices()
        if list.map(\.bsd) != routeChoices.map(\.bsd) || list.map(\.name) != routeChoices.map(\.name) { routeChoices = list }
    }

    /// The chosen card, or nil for the system's way (always for a network folder).
    var chosenRoute: String? { route.isEmpty || server.isFolder ? nil : route }

    var canTest: Bool {
        if server.isFolder { return !running && !server.folder.trimmingCharacters(in: .whitespaces).isEmpty }
        if server.isPeer { return !running && PeerProtocol.isValidCode(server.peerCode ?? "") }
        if chosenRoute != nil { return !running && !server.host.trimmingCharacters(in: .whitespaces).isEmpty }
        return !running && link.speed != .none && !server.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the next test measures against.
    var testTargetName: String { server.name }

    func start() {
        SpeedTest.removeLocalLeftovers()   // from a test cut short by a kill or a power loss
        updateReceiver()
        if notifyOnDrop { askForNotifications() }
        monitor.start()
    }

    private func askForNotifications() {
        notifier.requestPermission { [weak self] in self?.refreshNotifications() }
    }

    func refreshNotifications() {
        notifier.checkDenied { [weak self] denied in self?.notificationsDenied = denied }
    }

    // MARK: Alerts

    /// A speed has to hold for 3 s before it counts, so a renegotiation blink does not alert.
    private func linkChanged(_ state: LinkMonitor.State) {
        link = state
        refreshRoutes()
        if state.speed == .none { errorsAtLinkUp = nil } else if errorsAtLinkUp == nil { errorsAtLinkUp = linkDetails.errors }
        pending?.cancel()
        let speed = state.speed
        let work = DispatchWorkItem { [weak self] in self?.settle(speed) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func settle(_ speed: LinkSpeed) {
        // Wi‑Fi changes its rate all the time: only a lost connection alerts, and no best speed is kept.
        let floor = isWiFi ? nil : dropFloor.speed(best: bestSpeed)   // before this speed can raise the best
        defer {
            settled = speed
            if speed != .none { lastLinked = speed }
            if !isWiFi, speed.megabitsPerSecond > (bestSpeed?.megabitsPerSecond ?? 0) {
                bestSpeeds[monitor.bsdName] = speed.megabitsPerSecond
                defaults.set(bestSpeeds, forKey: "bestSpeeds")
            }
        }
        guard notifyOnDrop, speed != settled,
              let alert = LinkAlert.check(lastLinked: lastLinked, previous: settled, current: speed,
                                          floor: floor, card: interfaceName, wifi: isWiFi)
        else { return }
        notifier.post(alert)
    }

    // MARK: Link details

    /// Problems worth a line under the speed (empty when the link looks right).
    var hints: [LinkHint] { LinkHint.check(speed: link.speed, details: linkDetails, errorsBefore: errorsAtLinkUp) }

    private func detailsChanged(_ details: LinkDetails) {
        linkDetails = details
        if link.speed == .none { errorsAtLinkUp = nil } else if errorsAtLinkUp == nil { errorsAtLinkUp = details.errors }
    }

    // MARK: Autostart

    func setAutostart(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastNote = String(localized: "Open at login: \(error.localizedDescription)")
        }
        autostart = SMAppService.mainApp.status
    }

    func refreshAutostart() { autostart = SMAppService.mainApp.status }

    func startTest() {
        guard canTest else { return }
        let s = server
        var card: SpeedTest.Card?
        if let bsd = chosenRoute {
            guard let address = LinkMonitor.readIPv4(bsd) else {
                lastOutcome = nil
                lastNote = String(localized: "Error: \(LinkMonitor.routeName(bsd)) has no IPv4 address — \(Self.time(Date()))")
                refreshRoutes()
                return
            }
            card = SpeedTest.Card(bsd: bsd, address: address)
        }
        let mode: SpeedTest.Mode
        switch testMode {
        case _ where s.isPeer: mode = .peer(service: s.host, code: s.peerCode ?? "")   // memory only: nothing touches a disk
        case .memory where s.isFolder: mode = .folder(path: s.folder, fromDisk: false)
        case .disk where s.isFolder: mode = .folder(path: s.folder, fromDisk: true)
        case .memory: mode = .memory
        case .disk: mode = .disk(remoteDir: s.folder)
        }
        let t = SpeedTest(server: testTargetName, host: s.sshDestination, bytes: Int64(sizeGB) * 1_000_000_000, mode: mode, card: card)
        test = t
        running = true
        progress = 0
        status = s.isFolder ? String(localized: "Writing to \(s.name)…") : String(localized: "Connecting to \(s.name)…")
        t.onProgress = { [weak self] phase, fraction in
            let what: String
            switch (phase, mode) {
            case (.prepare, _): what = String(localized: "Preparing the file")
            case (.upload, _): what = String(localized: "Uploading")
            case (.download, _): what = String(localized: "Downloading")
            }
            self?.progress = fraction
            self?.status = "\(what) \(Int(fraction * 100))%"
        }
        t.start { [weak self] result in self?.finish(result) }
    }

    /// Empties the window after a test; the history keeps the result.
    func clearResult() {
        lastOutcome = nil
        lastNote = nil
    }

    /// Stops the test; `done` runs once its files are removed on both sides (used when quitting).
    func cancelTest(then done: (() -> Void)? = nil) {
        guard let test else { done?(); return }
        afterFinish = done
        test.cancel()
    }

    private func finish(_ result: Result<SpeedTest.Outcome, Error>) {
        test = nil
        running = false
        status = ""
        let time = Self.time(Date())
        switch result {
        case .success(let o):
            lastOutcome = o
            lastNote = nil
            history.append(HistoryEntry(date: o.finished, mode: Self.modeKey(o.mode), server: o.server, bytes: o.bytes,
                                        uploadMBps: o.uploadMBps, downloadMBps: o.downloadMBps,
                                        linkMbps: link.speed.megabitsPerSecond, via: o.via))
        case .failure(SpeedTest.Failure.cancelled):
            lastNote = String(localized: "Test stopped — \(time)")
        case .failure(SpeedTest.Failure.incomplete(let expected, let got)):
            lastNote = String(localized: "Error: \(got) of \(expected) bytes arrived — \(time)")
        case .failure(SpeedTest.Failure.noSpace(let place)):
            lastNote = String(localized: "Not enough space \(place) — \(time)")
        case .failure(SpeedTest.Failure.local(let message)):
            lastNote = String(localized: "Error: \(message) — \(time)")
        case .failure(SpeedTest.Failure.ssh(let message)):
            if let hint = Self.sshHint(message, host: server.sshDestination) {
                lastNote = String(localized: "SSH error: \(hint) — \(time)")
            } else {
                lastNote = String(localized: "SSH error: \(message.isEmpty ? String(localized: "no description") : message) — \(time)")
            }
        case .failure(let error):
            lastNote = String(localized: "Error: \(error.localizedDescription) — \(time)")
        }
        // A failed or stopped test leaves only its note — an older result next to it read as this test's (the history keeps it).
        if case .failure = result { lastOutcome = nil }
        afterFinish?()
        afterFinish = nil
    }

    /// Sample state for pictures of the window (the Help window, `swiftc -D PREVIEW`); never on the app's own controller.
    func preview(link: LinkMonitor.State, outcome: SpeedTest.Outcome?, note: String?,
                 details: LinkDetails = LinkDetails(), cardName: String? = nil) {
        self.link = link; lastOutcome = outcome; lastNote = note
        linkDetails = details; errorsAtLinkUp = details.errors
        sampleCardName = cardName
    }
    /// The card's name in pictures of the window, instead of the system's name for a BSD name this Mac may not have.
    private var sampleCardName: String?

    /// What to do about the SSH errors a first test usually meets; nil for anything else (shown as ssh says it).
    static func sshHint(_ message: String, host: String) -> String? {
        if message.contains("No route to host") {
            // With NetTorque switched off under Local Network, ssh to a server at home ends exactly so (measured
            // 2026-10-11); a server that is merely off times out instead.
            return String(localized: "the server cannot be reached. If it is on, check that NetTorque may use the local network: System Settings → Privacy & Security → Local Network.")
        }
        if message.contains("Host key verification failed") {
            // Not a bare "answer yes": a stranger on the network can announce a server under a familiar name (audit B-P3-02).
            return String(localized: "this Mac does not know the server's key yet. Connect once in Terminal: ssh \(host), check that the key fingerprint it shows is the server's, and answer yes.")
        }
        if message.contains("Permission denied") {
            return String(localized: "the server did not accept this Mac's SSH key. Add it on the server, e.g. in Terminal: ssh-copy-id \(host).")
        }
        return nil
    }

    /// e.g. "↑ 405 MB/s   ↓ 464 MB/s — nas, 14:05, from memory, 2 GB"
    static func summary(_ o: SpeedTest.Outcome) -> String {
        "↑ \(mbps(o.uploadMBps))   ↓ \(mbps(o.downloadMBps)) — \(details(o))"
    }

    /// The details line, with the card the test went through when it is known.
    static func details(_ o: SpeedTest.Outcome) -> String {
        guard let via = o.via else { return plainDetails(o) }
        return "\(plainDetails(o)) · \(LinkMonitor.routeKind(via))"
    }

    private static func plainDetails(_ o: SpeedTest.Outcome) -> String {
        switch o.mode {
        case .memory, .folder(_, false), .peer: return "\(o.server), \(time(o.finished)), \(String(localized: "from memory")), \(o.bytes / 1_000_000_000) GB"
        case .disk, .folder(_, true): return "\(o.server), \(time(o.finished)), \(String(localized: "disk to disk")), \(o.bytes / 1_000_000_000) GB"
        }
    }

    /// "from memory · 2 GB" or "disk to disk · 2 GB".
    static func modeName(_ o: SpeedTest.Outcome) -> String {
        switch o.mode {
        case .memory, .folder(_, false), .peer: return "\(String(localized: "from memory")) · \(o.bytes / 1_000_000_000) GB"
        case .disk, .folder(_, true): return "\(String(localized: "disk to disk")) · \(o.bytes / 1_000_000_000) GB"
        }
    }

    /// The text beside the menu bar icon, nil for none.
    static func menuBarTitle(_ choice: MenuBarText, link: LinkSpeed, outcome: SpeedTest.Outcome?) -> String? {
        switch choice {
        case .none: return nil
        case .link: return link.shortLabel
        case .result:
            guard let o = outcome else { return "—" }
            return "↑\(Int(o.uploadMBps.rounded())) ↓\(Int(o.downloadMBps.rounded()))"
        }
    }

    static func modeKey(_ mode: SpeedTest.Mode) -> String {
        switch mode {
        case .memory, .folder(_, false), .peer: return TestMode.memory.rawValue
        case .disk, .folder(_, true): return TestMode.disk.rawValue
        }
    }

    static func mbps(_ value: Double) -> String { "\(Int(value.rounded())) MB/s" }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
