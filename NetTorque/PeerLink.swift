import CryptoKit
import Foundation
import Network

/// Mac to Mac without SSH: one Mac receives (off by default), another tests against it.
///
/// Every connection proves it knows the receiver's 6-digit code: the receiver sends a random challenge, the
/// sender answers with an HMAC over it, the direction and the size. A wrong answer closes the connection, and wrong
/// answers lock out first the address they came from, then everyone but known Macs (`PeerLockout`) — six digits
/// cannot be guessed online. Plain TCP, no encryption: test data is random and nothing is stored (lesson from
/// MultiWork, whose pairing was checked once and then never again).
///
/// Accepted on purpose (audit 2026-10-11, B-P3-01): one overheard handshake lets anyone on the network try all
/// million codes offline in seconds. The code guards nothing but the right to run a speed test against this Mac —
/// no files, no commands, no data — so a longer code or a key agreement (PAKE) is not worth the harder pairing.
enum PeerProtocol {
    static let serviceType = "_nettorque._tcp"
    static let magic = Data("NTQ1".utf8)
    static let challengeSize = 32
    /// The largest test a receiver accepts (the window offers up to 10 GB).
    static let maxBytes: UInt64 = 10_000_000_000

    enum Command: UInt8 { case upload = 0x55, download = 0x44 }   // "U": sender → receiver, "D": receiver → sender
    enum Reply: UInt8 { case ok = 0, badCode = 1, tooLarge = 2, busy = 3, lockedOut = 4 }

    static func key(code: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("NetTorque pairing \(code)".utf8)))
    }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// Six digits, nothing else.
    static func isValidCode(_ code: String) -> Bool { code.count == 6 && code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber) }

    /// command (1) + size (8, big endian) + HMAC-SHA256 over challenge + command + size (32).
    static func header(key: SymmetricKey, challenge: Data, command: Command, size: UInt64) -> Data {
        var body = Data([command.rawValue])
        withUnsafeBytes(of: size.bigEndian) { body.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: challenge + body, using: key)
        return body + Data(mac)
    }

    static let headerSize = 1 + 8 + 32

    /// The command and size when the HMAC matches, nil otherwise.
    static func check(header: Data, key: SymmetricKey, challenge: Data) -> (Command, UInt64)? {
        guard header.count == headerSize, let command = Command(rawValue: header[header.startIndex]) else { return nil }
        let body = header.prefix(9)
        let mac = header.suffix(32)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: challenge + body, using: key) else { return nil }
        let size = body.dropFirst().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (command, size)
    }

    static func uint64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint64(_ data: Data) -> UInt64 { data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
}

/// Wrong codes within ten minutes: five from one address turn that address away for ten minutes; thirty from all
/// addresses together turn everyone away — except addresses that once got in. Until 0.1.42 five wrong codes from
/// anyone locked out everyone, so a stranger on the network could switch receiving off at will (audit B-P2-01).
struct PeerLockout {
    static let window: TimeInterval = 600
    static let perAddress = 5
    static let overall = 30

    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var all: [Date] = []
    private var allLockedUntil: Date?
    /// Senders that have shown the right code since the app started.
    private(set) var trusted: Set<String> = []

    func isLocked(_ address: String, at now: Date) -> Bool {
        if let until = lockedUntil[address], now < until { return true }
        if let until = allLockedUntil, now < until, !trusted.contains(address) { return true }
        return false
    }

    mutating func fail(_ address: String, at now: Date) {
        let fresh = { (date: Date) in now.timeIntervalSince(date) < Self.window }
        failures = failures.compactMapValues { list in
            let kept = list.filter(fresh)
            return kept.isEmpty ? nil : kept
        }
        lockedUntil = lockedUntil.filter { now < $0.value }
        var mine = failures[address, default: []] + [now]
        if mine.count >= Self.perAddress { lockedUntil[address] = now.addingTimeInterval(Self.window); mine = [] }
        failures[address] = mine.isEmpty ? nil : mine
        all = all.filter(fresh) + [now]
        if all.count >= Self.overall { allLockedUntil = now.addingTimeInterval(Self.window); all = [] }
    }

    mutating func succeed(_ address: String) {
        trusted.insert(address)
        failures[address] = nil
    }
}

/// An NWConnection used from a background thread, one call at a time, waiting for each.
final class BlockingConnection {
    enum Failure: Error { case closed, timeout, failed(String) }

    let connection: NWConnection
    private let queue = DispatchQueue(label: "NetTorque.peer")

    init(_ connection: NWConnection) { self.connection = connection }

    /// `card` (BSD name): only through this card. Not by local address — with a Bonjour name the system picked
    /// the other Mac's address on another card and the connection never came up (measured 2026-10-10).
    convenience init(service name: String, card: String? = nil) {
        let endpoint = NWEndpoint.service(name: name, type: PeerProtocol.serviceType, domain: "local.", interface: nil)
        let params = NWParameters.tcp
        if let card, let interface = Self.interface(named: card) { params.requiredInterface = interface }
        self.init(NWConnection(to: endpoint, using: params))
    }

    /// The system's handle for a card, read from the current network path (nil when the card is not up).
    static func interface(named name: String) -> NWInterface? {
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        var found: NWInterface?
        monitor.pathUpdateHandler = { path in
            found = path.availableInterfaces.first { $0.name == name }
            ready.signal()
        }
        monitor.start(queue: DispatchQueue(label: "NetTorque.interface"))
        _ = ready.wait(timeout: .now() + 2)
        monitor.cancel()
        return found
    }

    func open(timeout: Double = 8) throws {
        let ready = DispatchSemaphore(value: 0)
        var error: Failure?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): error = .failed(e.localizedDescription); ready.signal()
            case .waiting(let e): error = .failed(e.localizedDescription); ready.signal()
            case .cancelled: error = .closed; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else { connection.cancel(); throw Failure.timeout }
        if let error { connection.cancel(); throw error }
        connection.stateUpdateHandler = nil
    }

    func send(_ data: Data) throws {
        let done = DispatchSemaphore(value: 0)
        var error: NWError?
        connection.send(content: data, completion: .contentProcessed { error = $0; done.signal() })
        done.wait()
        if let error { throw Failure.failed(error.localizedDescription) }
    }

    /// Exactly `count` bytes, or Failure.closed when the other side ends first.
    func receive(exactly count: Int, timeout: Double = 30) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let part = try receive(upTo: count - buffer.count, timeout: timeout)
            if part.isEmpty { throw Failure.closed }
            buffer += part
        }
        return buffer
    }

    /// Up to `max` bytes; empty only when the other side has closed. A delivery with no data and no end of
    /// stream is waited past — counting it as the end cut a Wi‑Fi test at 11.7 MB of 1 GB (2026-10-10).
    func receive(upTo max: Int, timeout: Double = 30) throws -> Data {
        let deadline = DispatchTime.now() + timeout
        while true {
            let done = DispatchSemaphore(value: 0)
            var result = Data(), closed = false, failure: NWError?
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, error in
                result = data ?? Data(); closed = complete; failure = error
                done.signal()
            }
            guard done.wait(timeout: deadline) == .success else { throw Failure.timeout }
            if let failure { throw Failure.failed(failure.localizedDescription) }
            if !result.isEmpty { return result }
            if closed { return Data() }
        }
    }

    /// Ends the sending side cleanly (FIN after the data), waiting until it is out.
    func finish() {
        let done = DispatchSemaphore(value: 0)
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in done.signal() })
        _ = done.wait(timeout: .now() + 10)
    }

    func close() { connection.cancel() }
}

/// Accepts tests from other Macs while "Receive tests from other Macs" is on.
final class PeerReceiver {
    /// Connections that have not shown the code yet, from one address and from all together; more are closed at
    /// once, so nobody on the network can tie up the app's threads — or the free places, by holding them all from
    /// one address — with connections that never answer (audit B-P2-01).
    static let maxUnprovenPerAddress = 2
    static let maxUnproven = 16

    private var listener: NWListener?
    private let lock = NSLock()   // guards everything below
    private var busy = false
    private var lockout = PeerLockout()
    private var key = PeerProtocol.key(code: "")
    private var unproven = 0
    private var unprovenFrom: [String: Int] = [:]
    /// Every connection being served, so turning receiving off ends the ones in progress too.
    private var active: [ObjectIdentifier: BlockingConnection] = [:]
    var onStateChange: ((String?) -> Void)?   // nil = listening, text = why not

    var isRunning: Bool { listener != nil }

    func start(name: String, code: String) {
        stop()
        lock.lock(); key = PeerProtocol.key(code: code); lock.unlock()
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: name, type: PeerProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report(nil)
                case .failed(let e): self?.report(e.localizedDescription)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in
                guard let self else { c.cancel(); return }
                let address = Self.address(of: c)
                self.lock.lock()
                let room = self.unproven < Self.maxUnproven && self.unprovenFrom[address, default: 0] < Self.maxUnprovenPerAddress
                if room { self.unproven += 1; self.unprovenFrom[address, default: 0] += 1 }
                self.lock.unlock()
                guard room else { c.cancel(); return }
                DispatchQueue.global(qos: .userInitiated).async { self.serve(BlockingConnection(c), from: address) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Stops listening and ends the tests in progress.
    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); let open = Array(active.values); lock.unlock()
        open.forEach { $0.close() }
    }

    /// The sender's IP address, without the interface suffix.
    static func address(of c: NWConnection) -> String {
        if case let .hostPort(host, _) = c.endpoint { return ServiceBrowser.address(host) }
        return "\(c.endpoint)"
    }

    /// One connection fewer waiting for its code; called under `lock`.
    private func proven(_ address: String) {
        unproven -= 1
        let left = unprovenFrom[address, default: 1] - 1
        unprovenFrom[address] = left > 0 ? left : nil
    }

    private func report(_ text: String?) { DispatchQueue.main.async { self.onStateChange?(text) } }

    private func serve(_ c: BlockingConnection, from address: String) {
        let id = ObjectIdentifier(c)
        lock.lock(); active[id] = c; lock.unlock()
        var counted = true   // still in `unproven`
        defer {
            c.close()
            lock.lock(); active[id] = nil; if counted { proven(address) }; lock.unlock()
        }
        do {
            try c.open(timeout: 5)
            var challenge = Data(count: PeerProtocol.challengeSize)
            challenge.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try c.send(PeerProtocol.magic + challenge)
            let header = try c.receive(exactly: PeerProtocol.headerSize, timeout: 5)
            lock.lock()
            proven(address)
            counted = false
            let now = Date()
            if lockout.isLocked(address, at: now) { lock.unlock(); try c.send(Data([PeerProtocol.Reply.lockedOut.rawValue])); return }
            guard let (command, size) = PeerProtocol.check(header: header, key: key, challenge: challenge) else {
                lockout.fail(address, at: now)
                lock.unlock()
                try c.send(Data([PeerProtocol.Reply.badCode.rawValue]))
                return
            }
            lockout.succeed(address)
            if size > PeerProtocol.maxBytes { lock.unlock(); try c.send(Data([PeerProtocol.Reply.tooLarge.rawValue])); return }
            if busy { lock.unlock(); try c.send(Data([PeerProtocol.Reply.busy.rawValue])); return }
            busy = true
            lock.unlock()
            defer { lock.lock(); busy = false; lock.unlock() }
            try c.send(Data([PeerProtocol.Reply.ok.rawValue]))
            switch command {
            case .upload:
                var got: UInt64 = 0
                while got < size {
                    let part = try c.receive(upTo: 1 << 20)
                    if part.isEmpty { break }
                    got += UInt64(part.count)
                }
                try c.send(PeerProtocol.uint64(got))
                c.finish()
            case .download:
                var chunk = Data(count: 1 << 20)
                chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
                var sent: UInt64 = 0
                while sent < size {
                    let n = Int(min(UInt64(chunk.count), size - sent))
                    try c.send(n == chunk.count ? chunk : chunk.prefix(n))
                    sent += UInt64(n)
                }
                c.finish()
            }
        } catch {
            // The sender reports its own error; nothing to show here.
        }
    }
}
