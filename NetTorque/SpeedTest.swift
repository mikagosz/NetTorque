import CryptoKit
import Foundation

/// Copies data over the system `ssh` to a server and back, timing each direction.
/// Runs on a background queue; callbacks arrive on the main queue.
final class SpeedTest {
    enum Phase { case prepare, upload, download }

    enum Mode: Equatable {
        /// Generated data → discarded on the server, and back. Disks take no part.
        case memory
        /// A file with random data, from the Mac's disk to `remoteDir` on the server's disk and back.
        case disk(remoteDir: String)
        /// A network folder mounted in Finder (SMB, NFS, AFP): a file written there and read back, no SSH.
        /// `fromDisk`: the data comes from and goes to a file on the Mac, as in disk to disk.
        case folder(path: String, fromDisk: Bool)
        /// Another Mac running NetTorque with "Receive tests" on, found by its Bonjour name; `code` is its 6 digits.
        case peer(service: String, code: String)
    }

    struct Outcome {
        let server: String
        let bytes: Int64
        let mode: Mode
        let uploadMBps: Double
        let downloadMBps: Double
        let finished: Date
        /// The card the data went through (BSD name), nil when it could not be told.
        var via: String? = nil
    }

    /// A card chosen for the test: its BSD name and the IPv4 address the connection starts from.
    struct Card: Equatable {
        let bsd: String
        let address: String
    }

    enum Failure: Error {
        case ssh(String)
        case incomplete(expected: Int64, got: Int64)
        case noSpace(where: String)
        case local(String)
        case cancelled
    }

    let server: String
    let host: String
    let bytes: Int64
    let mode: Mode
    /// nil: the system picks the way, as for any other connection.
    let card: Card?
    var onProgress: ((Phase, Double) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var connection: BlockingConnection?
    private var cancelled = false
    /// The card a connection to another Mac actually used, read once it is up.
    private var peerInterface: String?
    /// The address ssh starts from when a card is chosen: the card's address in the server's subnet (set in `run`).
    private var bindAddress: String?
    private let id = UUID().uuidString.prefix(8).lowercased()

    init(server: String, host: String, bytes: Int64, mode: Mode, card: Card? = nil) {
        self.server = server
        self.host = host
        self.bytes = bytes
        self.mode = mode
        self.card = card
    }

    // MARK: Pure helpers (covered by Tests/main.swift)

    /// Never asks for a password: BatchMode makes a failed key login end with an error instead.
    /// `--` keeps an address starting with "-" from being read as an option. `bind`: the connection starts from
    /// this address, so it leaves through the card that has it (measured: also with two cards in one subnet).
    static func sshArguments(host: String, command: String, bind: String? = nil) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "Compression=no"]
            + (bind.map { ["-b", $0] } ?? []) + ["--", host, command]
    }

    /// "en5" from the output of `route -n get <host>`.
    static func interface(fromRoute output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface", !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    /// The address an alias from ~/.ssh/config stands for, from the output of `ssh -G <host>`.
    static func hostName(fromSSHConfig output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("hostname ") {
            let name = line.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// 1 MB = 10^6 bytes, as Finder counts.
    static func megabytesPerSecond(bytes: Int64, seconds: Double) -> Double {
        seconds > 0 ? Double(bytes) / seconds / 1_000_000 : 0
    }

    /// Single-quotes a path for the remote shell.
    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func remoteFile(dir: String, id: some StringProtocol) -> String {
        (dir.hasSuffix("/") ? dir : dir + "/") + "nettorque-\(id).bin"
    }

    /// The server prints "R" once the session is up (the login is not timed), then reports how much arrived.
    static func uploadCommand(_ mode: Mode, file: String?) -> String {
        switch mode {
        case .memory, .folder, .peer: return "echo R; exec wc -c"   // only .memory and .disk use ssh
        case .disk: return "echo R; cat > \(quoted(file!)) && sync \(quoted(file!)) && wc -c < \(quoted(file!))"
        }
    }

    /// "R" first as well, so anything a login shell prints before it is not counted as data.
    static func downloadCommand(_ mode: Mode, bytes: Int64, file: String?) -> String {
        switch mode {
        case .memory, .folder, .peer: return "echo R; head -c \(bytes) /dev/zero"
        case .disk: return "echo R; cat \(quoted(file!))"
        }
    }

    static func freeSpaceCommand(dir: String) -> String { "df -Pk \(quoted(dir)) | awk 'NR==2{print $4}'" }

    /// Test files older than an hour in the server folder — left by a test whose app was killed or lost power.
    /// The hour spares a test another Mac may be running into the same folder right now.
    static func leftoversCommand(dir: String) -> String {
        "find \(quoted(dir)) -maxdepth 1 -type f \\( -name 'nettorque-????????.bin' -o -name '\(Migration.oldFilePrefix)????????.bin' \\) -mmin +60 -exec rm -- {} \\;"
    }

    /// What follows the line "R"; nil until that line has arrived. Lines before it are skipped.
    static func afterReady(_ data: Data) -> Data? {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if data[start..<newline].elementsEqual("R".utf8) { return Data(data[(newline + 1)...]) }
            start = newline + 1
        }
        return nil
    }

    /// The last non-empty line as a number, e.g. the count from `wc -c`.
    static func lastNumber(_ data: Data) -> Int64? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last { !$0.allSatisfy(\.isWhitespace) }
            .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Running

    func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.run() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = process; let c = connection; lock.unlock()
        p?.terminate()
        c?.close()
    }

    private func run() throws -> Outcome {
        switch mode {
        case .memory, .disk:
            // The card's address facing the server, not just its first one: bound to an address from another subnet,
            // ssh waits for answers that never come (measured 2026-10-11).
            if let card {
                bindAddress = LinkMonitor.sourceAddress(among: LinkMonitor.readIPv4Addresses(card.bsd), toward: serverIPv4()) ?? card.address
            }
        case .folder, .peer:
            break   // no ssh
        }
        var outcome = try runTest()
        outcome.via = card?.bsd ?? peerInterface ?? systemRoute()
        return outcome
    }

    /// The card the system sends this test's traffic through; a network folder always goes this way.
    private func systemRoute() -> String? {
        let target: String
        switch mode {
        case .peer: return nil
        case .folder(let path, _):
            var s = statfs()
            guard statfs(path, &s) == 0 else { return nil }
            let from = withUnsafeBytes(of: s.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            target = ServiceBrowser.host(fromMount: from)
        case .memory, .disk:
            let destination = host.split(separator: "@").last.map(String.init) ?? host
            target = Self.hostName(fromSSHConfig: Self.output("/usr/bin/ssh", ["-G", "--", destination])) ?? destination
        }
        guard !target.isEmpty, !target.hasPrefix("-") else { return nil }
        return Self.interface(fromRoute: Self.output("/sbin/route", ["-n", "get", target]))
    }

    /// The server's IPv4 address: an alias from ~/.ssh/config through `ssh -G`, a name through the system.
    private func serverIPv4() -> String? {
        let destination = host.split(separator: "@").last.map(String.init) ?? host
        let name = Self.hostName(fromSSHConfig: Self.output("/usr/bin/ssh", ["-G", "--", destination])) ?? destination
        guard !name.isEmpty, !name.hasPrefix("-") else { return nil }
        if LinkMonitor.ipv4(name) != nil { return name }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &found) == 0, let first = found else { return nil }
        defer { freeaddrinfo(found) }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: text)
    }

    /// Standard output of a short command; empty when it cannot run.
    private static func output(_ tool: String, _ arguments: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func runTest() throws -> Outcome {
        if case .folder(let path, let fromDisk) = mode { return try folder(path: path, fromDisk: fromDisk) }
        if case .peer(let service, let code) = mode { return try peer(service: service, code: code) }
        guard case .disk(let dir) = mode else {
            let up = try upload(file: nil, source: nil)
            let down = try download(file: nil, sink: nil)
            return Outcome(server: server, bytes: bytes, mode: mode, uploadMBps: up, downloadMBps: down, finished: Date())
        }
        let remote = Self.remoteFile(dir: dir, id: id)
        let folder = try localFolder()
        let source = folder.appendingPathComponent("nettorque-\(id)-out.bin")
        let target = folder.appendingPathComponent("nettorque-\(id)-in.bin")
        // Always, also after an error or Stop: no test file is left on either side.
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
            runQuietly("rm -f \(Self.quoted(remote))")
        }
        Self.removeLocalLeftovers()
        runQuietly(Self.leftoversCommand(dir: dir))
        try checkSpace(remoteDir: dir, localFolder: folder)
        try writeRandomFile(source)
        let up = try upload(file: remote, source: source)
        try? FileManager.default.removeItem(at: source)
        let down = try download(file: remote, sink: target)
        return Outcome(server: server, bytes: bytes, mode: mode, uploadMBps: up, downloadMBps: down, finished: Date())
    }

    // MARK: Directions

    private func upload(file: String?, source: URL?) throws -> Double {
        let (p, input, output, errors) = try launch(Self.uploadCommand(mode, file: file))
        let early = try waitForReady(output, errors: errors, process: p)
        let reader = try source.map { try FileHandle(forReadingFrom: $0) }
        defer { try? reader?.close() }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        var sent: Int64 = 0
        var lastReport = Date.distantPast
        let start = DispatchTime.now()
        let fd = input.fileHandleForWriting.fileDescriptor
        while sent < bytes {
            var n = Int(min(Int64(chunk.count), bytes - sent))
            if let reader {
                n = chunk.withUnsafeMutableBytes { read(reader.fileDescriptor, $0.baseAddress, n) }
                if n <= 0 { break }
            }
            let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, n) }
            if written <= 0 { break }
            sent += Int64(written)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(.upload, sent) }
        }
        try? input.fileHandleForWriting.close()
        let reply = early + output.fileHandleForReading.readDataToEndOfFile()
        let seconds = elapsed(since: start)
        p.waitUntilExit()
        try checkFinished(p, errors: errors)
        let got = Self.lastNumber(reply) ?? 0
        guard got == bytes else { throw Failure.incomplete(expected: bytes, got: got) }
        return Self.megabytesPerSecond(bytes: got, seconds: seconds)
    }

    /// Timed from the first byte received; in disk mode until the file is flushed to the Mac's disk.
    private func download(file: String?, sink: URL?) throws -> Double {
        var out: Int32 = -1
        if let sink {
            out = open(sink.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard out >= 0 else { throw Failure.local(String(localized: "cannot write \(sink.path)")) }
        }
        defer { if out >= 0 { close(out) } }
        let (p, input, output, errors) = try launch(Self.downloadCommand(mode, bytes: bytes, file: file))
        try? input.fileHandleForWriting.close()
        var got: Int64 = 0
        var start: DispatchTime?
        var lastReport = Date.distantPast
        func take(_ chunk: UnsafeRawBufferPointer) throws {
            if start == nil { start = DispatchTime.now() }
            if out >= 0 {
                let w = write(out, chunk.baseAddress, chunk.count)
                guard w == chunk.count else { throw Failure.local(String(localized: "writing to the Mac's disk was interrupted")) }
            }
            got += Int64(chunk.count)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(.download, got) }
        }
        let early = try waitForReady(output, errors: errors, process: p)
        if !early.isEmpty { try early.withUnsafeBytes { try take($0) } }
        let fd = output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            try buffer.withUnsafeBytes { try take(UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
        }
        if out >= 0 { _ = fcntl(out, F_FULLFSYNC) }
        let seconds = start.map(elapsed(since:)) ?? 0
        p.waitUntilExit()
        try checkFinished(p, errors: errors)
        guard got == bytes else { throw Failure.incomplete(expected: bytes, got: got) }
        return Self.megabytesPerSecond(bytes: got, seconds: seconds)
    }

    // MARK: Disk mode helpers

    private func localFolder() throws -> URL { try Self.localFolder() }

    static func localFolder() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = caches.appendingPathComponent("com.mikagosz.NetTorque", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Test files on the Mac left by a test that never finished (the app was killed or the Mac lost power).
    /// Called only while no test runs.
    static func removeLocalLeftovers() {
        let fm = FileManager.default
        guard let folder = try? localFolder() else { return }
        // Also the folder of the old name (SpeedLan), for a test cut short before the update.
        let old = folder.deletingLastPathComponent().appendingPathComponent(Migration.oldCacheFolder, isDirectory: true)
        for (dir, prefix) in [(folder, "nettorque-"), (old, Migration.oldFilePrefix)] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".bin") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private func checkSpace(remoteDir: String, localFolder: URL) throws {
        let need = bytes + bytes / 20
        let local = try localFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = local.volumeAvailableCapacityForImportantUsage, free < need { throw Failure.noSpace(where: String(localized: "on the Mac")) }
        let (p, input, output, errors) = try launch(Self.freeSpaceCommand(dir: remoteDir))
        try? input.fileHandleForWriting.close()
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try checkFinished(p, errors: errors)
        guard let kb = Self.lastNumber(reply) else {
            throw Failure.ssh(String(localized: "there is no folder \(remoteDir) on the server"))
        }
        if kb * 1024 < need { throw Failure.noSpace(where: String(localized: "on the server in \(remoteDir)")) }
    }

    private func writeRandomFile(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw Failure.local(String(localized: "cannot create the test file")) }
        defer { try? handle.close() }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        var done: Int64 = 0
        var lastReport = Date.distantPast
        while done < bytes {
            if isCancelled { throw Failure.cancelled }
            let n = Int(min(Int64(chunk.count), bytes - done))
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, n) }
            try handle.write(contentsOf: chunk[0..<n])
            done += Int64(n)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(.prepare, done) }
        }
    }

    /// Clean-up on the server; not gated by Stop — it is what cleans up after it. The result does not matter.
    private func runQuietly(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Self.sshArguments(host: host, command: command, bind: bindAddress)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Network folder

    /// File systems that live on another machine, as statfs names them.
    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav"]

    /// The file system of the volume holding `path` ("smbfs", "apfs" …), nil when it cannot be read.
    static func fileSystem(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func isNetworkFolder(_ path: String) -> Bool { fileSystem(of: path).map(networkFileSystems.contains) ?? false }

    /// Write `bytes` into the folder and read them back. F_NOCACHE on both: without it the read comes from the
    /// Mac's own memory and the result is far too high. The write is timed until F_FULLFSYNC has returned.
    private func folder(path: String, fromDisk: Bool) throws -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.local(String(localized: "the folder \(path) is not there — is the share mounted?"))
        }
        let remote = URL(fileURLWithPath: Self.remoteFile(dir: path, id: id))
        let local = try localFolder()
        let source = local.appendingPathComponent("nettorque-\(id)-out.bin")
        let target = local.appendingPathComponent("nettorque-\(id)-in.bin")
        defer {
            try? fm.removeItem(at: remote)
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: target)
        }
        Self.removeFolderLeftovers(path)
        let free = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        if let free, Int64(free) < bytes + bytes / 20 { throw Failure.noSpace(where: String(localized: "in the folder")) }
        if fromDisk { try writeRandomFile(source) }
        let up = try copy(from: fromDisk ? source : nil, to: remote, phase: .upload)
        try? fm.removeItem(at: source)
        let down = try copy(from: remote, to: fromDisk ? target : nil, phase: .download)
        return Outcome(server: server, bytes: bytes, mode: mode, uploadMBps: up, downloadMBps: down, finished: Date())
    }

    /// nil source: random data from memory; nil target: read and dropped. Returns MB/s.
    private func copy(from source: URL?, to target: URL?, phase: Phase) throws -> Double {
        var input: Int32 = -1, output: Int32 = -1
        if let source {
            input = open(source.path, O_RDONLY)
            guard input >= 0 else { throw Failure.local(String(localized: "cannot read \(source.path)")) }
            _ = fcntl(input, F_NOCACHE, 1)
        }
        defer { if input >= 0 { close(input) } }
        if let target {
            output = open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard output >= 0 else { throw Failure.local(String(localized: "cannot write \(target.path)")) }
            _ = fcntl(output, F_NOCACHE, 1)
        }
        defer { if output >= 0 { close(output) } }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        if source == nil { chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) } }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let start = DispatchTime.now()
        while done < bytes {
            if isCancelled { throw Failure.cancelled }
            var n = Int(min(Int64(chunk.count), bytes - done))
            if input >= 0 {
                n = chunk.withUnsafeMutableBytes { read(input, $0.baseAddress, n) }
                if n < 0 { throw Failure.local(String(localized: "reading was interrupted")) }
                if n == 0 { break }
            }
            if output >= 0 {
                let w = chunk.withUnsafeBytes { write(output, $0.baseAddress, n) }
                guard w == n else { throw Failure.local(String(localized: "writing was interrupted")) }
            }
            done += Int64(n)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(phase, done) }
        }
        if output >= 0, fcntl(output, F_FULLFSYNC) != 0 { _ = fsync(output) }   // network file systems may refuse F_FULLFSYNC
        let seconds = elapsed(since: start)
        guard done == bytes else { throw Failure.incomplete(expected: bytes, got: done) }
        return Self.megabytesPerSecond(bytes: done, seconds: seconds)
    }

    /// Test files older than an hour in the folder, as on a server.
    static func removeFolderLeftovers(_ path: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        let hourAgo = Date().addingTimeInterval(-3600)
        for name in names where isTestFileName(name) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < hourAgo {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// "nettorque-ab12cd34.bin" or the old "speedlan-ab12cd34.bin" — exactly what the leftovers command matches.
    static func isTestFileName(_ name: String) -> Bool {
        for prefix in ["nettorque-", Migration.oldFilePrefix] where name.hasPrefix(prefix) && name.hasSuffix(".bin") {
            return name.count == prefix.count + 8 + 4
        }
        return false
    }

    // MARK: Another Mac

    private func peer(service: String, code: String) throws -> Outcome {
        let key = PeerProtocol.key(code: code)
        let up = try peerDirection(service: service, key: key, command: .upload)
        let down = try peerDirection(service: service, key: key, command: .download)
        return Outcome(server: server, bytes: bytes, mode: mode, uploadMBps: up, downloadMBps: down, finished: Date())
    }

    private func peerDirection(service: String, key: SymmetricKey, command: PeerProtocol.Command) throws -> Double {
        let c = BlockingConnection(service: service, card: card?.bsd)
        lock.lock()
        if cancelled { lock.unlock(); throw Failure.cancelled }
        connection = c
        lock.unlock()
        defer { c.close(); lock.lock(); connection = nil; lock.unlock() }
        do {
            try c.open()
            if peerInterface == nil { peerInterface = c.connection.currentPath?.availableInterfaces.first?.name }
            let hello = try c.receive(exactly: PeerProtocol.magic.count + PeerProtocol.challengeSize, timeout: 10)
            guard hello.prefix(PeerProtocol.magic.count) == PeerProtocol.magic else {
                throw Failure.local(String(localized: "the other Mac does not respond like NetTorque"))
            }
            let challenge = hello.dropFirst(PeerProtocol.magic.count)
            try c.send(PeerProtocol.header(key: key, challenge: Data(challenge), command: command, size: UInt64(bytes)))
            let reply = try c.receive(exactly: 1, timeout: 10)
            switch PeerProtocol.Reply(rawValue: reply[reply.startIndex]) {
            case .ok?: break
            case .badCode?: throw Failure.local(String(localized: "the other Mac did not accept the code — pair it again"))
            case .lockedOut?: throw Failure.local(String(localized: "the other Mac refuses tests for ten minutes after wrong codes"))
            case .busy?: throw Failure.local(String(localized: "the other Mac is already running a test"))
            case .tooLarge?: throw Failure.local(String(localized: "the other Mac does not take a test this large"))
            case nil: throw Failure.local(String(localized: "the other Mac does not respond like NetTorque"))
            }
            var chunk = Data(count: 1 << 20)
            var done: Int64 = 0
            var lastReport = Date.distantPast
            var start = DispatchTime.now()
            switch command {
            case .upload:
                chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
                while done < bytes {
                    if isCancelled { throw Failure.cancelled }
                    let n = Int(min(Int64(chunk.count), bytes - done))
                    try c.send(n == chunk.count ? chunk : chunk.prefix(n))
                    done += Int64(n)
                    if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(.upload, done) }
                }
                let count = PeerProtocol.uint64(try c.receive(exactly: 8, timeout: 60))   // the other side has it all
                let seconds = elapsed(since: start)
                guard Int64(count) == bytes else { throw Failure.incomplete(expected: bytes, got: Int64(count)) }
                return Self.megabytesPerSecond(bytes: bytes, seconds: seconds)
            case .download:
                var first = true
                while done < bytes {
                    if isCancelled { throw Failure.cancelled }
                    let part = try c.receive(upTo: Int(min(Int64(1 << 20), bytes - done)))
                    if part.isEmpty { break }
                    if first { start = DispatchTime.now(); first = false }
                    done += Int64(part.count)
                    if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(.download, done) }
                }
                let seconds = elapsed(since: start)
                guard done == bytes else { throw Failure.incomplete(expected: bytes, got: done) }
                return Self.megabytesPerSecond(bytes: bytes, seconds: seconds)
            }
        } catch let e as BlockingConnection.Failure {
            if isCancelled { throw Failure.cancelled }
            switch e {
            case .timeout: throw Failure.local(String(localized: "the other Mac did not answer — is it on, with receiving turned on?"))
            case .closed: throw Failure.local(String(localized: "the other Mac closed the connection"))
            case .failed(let text): throw Failure.local(text)
            }
        }
    }

    // MARK: Processes

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func launch(_ command: String) throws -> (Process, Pipe, Pipe, Pipe) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw Failure.cancelled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Self.sshArguments(host: host, command: command, bind: bindAddress)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        process = p
        return (p, input, output, errors)
    }

    /// Waits for the line "R" and returns what already came after it.
    private func waitForReady(_ output: Pipe, errors: Pipe, process p: Process) throws -> Data {
        var seen = Data()
        while true {
            if let rest = Self.afterReady(seen) { return rest }
            let more = output.fileHandleForReading.availableData
            if more.isEmpty {
                p.waitUntilExit()
                try checkFinished(p, errors: errors)
                throw Failure.ssh(String(localized: "the server closed the connection before the start"))
            }
            seen.append(more)
        }
    }

    private func checkFinished(_ p: Process, errors: Pipe) throws {
        if isCancelled { throw Failure.cancelled }
        guard p.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.ssh(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func progress(_ phase: Phase, _ done: Int64) {
        let fraction = Double(done) / Double(bytes)
        DispatchQueue.main.async { self.onProgress?(phase, fraction) }
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
