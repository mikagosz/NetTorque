import Foundation
import Network

/// Servers that announce themselves on the local network (Bonjour): SSH and SMB.
/// Runs only while the settings window is open. The first use asks for local network access.
final class ServiceBrowser: ObservableObject {
    enum Kind: String { case ssh = "_ssh._tcp", smb = "_smb._tcp", peer = "_nettorque._tcp" }

    struct Found: Hashable, Identifiable {
        let name: String
        let kind: Kind
        var id: String { kind.rawValue + "/" + name }
    }

    @Published private(set) var found: [Found] = []
    /// Addresses of what was found, filled in as they resolve (shown next to the name).
    @Published private(set) var addresses: [String: String] = [:]
    private var browsers: [NWBrowser] = []
    private var results: [Kind: Set<String>] = [:]
    /// This Mac's own names (the system's, and the one its receiver announces), left out of the list.
    var ownNames: Set<String> = [Host.current().localizedName ?? ""]

    func start() {
        guard browsers.isEmpty else { return }
        for kind in [Kind.peer, .ssh, .smb] {
            let browser = NWBrowser(for: .bonjour(type: kind.rawValue, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] all, _ in
                let names = Set(all.compactMap { result -> String? in
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                })
                DispatchQueue.main.async { self?.update(kind, names) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    private func update(_ kind: Kind, _ names: Set<String>) {
        results[kind] = names
        found = Self.list(results, ownNames: ownNames)
        for f in found where addresses[f.id] == nil && f.kind != .peer {
            addresses[f.id] = ""   // asked once; empty until it answers
            Self.resolve(f) { [weak self] host in self?.addresses[f.id] = host ?? "" }
        }
    }

    // MARK: Shares already mounted in Finder

    struct Mounted: Hashable, Identifiable {
        let name: String     // the volume's name, e.g. "Archive"
        let path: String     // /Volumes/Archive
        let host: String     // 192.0.2.10 — from "//user@192.0.2.10/Archive"
        let kind: String     // smbfs, nfs …
        var id: String { path }
    }

    /// Network shares mounted right now (SMB, NFS, AFP, WebDAV).
    static func mountedShares() -> [Mounted] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Mounted? in
            var s = statfs()
            guard statfs(url.path, &s) == 0 else { return nil }
            let type = withUnsafeBytes(of: s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard SpeedTest.networkFileSystems.contains(type) else { return nil }
            let from = withUnsafeBytes(of: s.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return Mounted(name: name, path: url.path, host: host(fromMount: from), kind: type)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "//user@192.0.2.10/Share" (SMB, AFP) or "192.0.2.10:/export" (NFS) → "192.0.2.10".
    static func host(fromMount from: String) -> String {
        let rest = from.hasPrefix("//") ? from.dropFirst(2) : Substring(from)
        let authority = rest[..<(rest.firstIndex(where: { $0 == "/" || $0 == ":" }) ?? rest.endIndex)]   // user@host
        return String(authority.split(separator: "@").last ?? authority)
    }

    /// One entry per name and kind (a service shows once per network card), without this Mac, sorted.
    static func list(_ results: [Kind: Set<String>], ownNames: Set<String>) -> [Found] {
        results.flatMap { kind, names in names.subtracting(ownNames).map { Found(name: $0, kind: kind) } }
            .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// The service's IP address (IPv4 when there is one), by opening a connection and reading where it went.
    static func resolve(_ found: Found, done: @escaping (String?) -> Void) {
        let endpoint = NWEndpoint.service(name: found.name, type: found.kind.rawValue, domain: "local.", interface: nil)
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "NetTorque.resolve")   // one queue for the state and the timeout: no race on `finished`
        var finished = false
        let finish: (String?) -> Void = { host in
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { done(host) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                    finish(Self.address(host))
                } else { finish(nil) }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }

    /// "192.0.2.10" without the "%en5" interface suffix the system adds (measured on IPv4 too).
    static func address(_ host: NWEndpoint.Host) -> String {
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "\(host)"
        }
        return withoutInterface(text)
    }

    static func withoutInterface(_ text: String) -> String { text.components(separatedBy: "%").first ?? text }
}
