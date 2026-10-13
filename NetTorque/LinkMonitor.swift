import CoreWLAN
import Foundation
import SystemConfiguration

/// Watches one interface: reacts to the system's link notifications and re-reads every 5 s as a backstop.
final class LinkMonitor {
    struct State: Equatable {
        var speed: LinkSpeed
        var ipv4: String?
    }

    let bsdName: String
    private(set) var state = State(speed: .none, ipv4: nil)
    private(set) var details = LinkDetails()
    var onChange: ((State) -> Void)?
    /// Supported media, duplex, MTU, errors — reported before `onChange` of the same reading.
    var onDetails: ((LinkDetails) -> Void)?

    private var store: SCDynamicStore?
    /// Wi‑Fi rates of the last minute: an idle radio drops its rate (measured 2401 → 286 Mb/s within minutes),
    /// so the icon shows the best of the last minute instead of blinking between colours.
    private var wifiRates = WiFiRates()
    private var timer: Timer?

    init(bsdName: String) { self.bsdName = bsdName }

    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "NetTorque" as CFString, { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<LinkMonitor>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }, &context)
        if let store {
            let keys = ["State:/Network/Interface/\(bsdName)/Link", "State:/Network/Interface/\(bsdName)/IPv4"]
            SCDynamicStoreSetNotificationKeys(store, keys as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1   // all day in the menu bar: lets the system bundle the wake-ups (audit W-P3-01)
        refresh(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        onChange = nil
        onDetails = nil
    }

    /// First launch: the fastest wired interface that has a link, else Wi‑Fi when it has one, else the first wired one.
    static func preferredWiredInterface() -> String {
        let wired = wiredInterfaces().map(\.bsd)
        let rank: (LinkSpeed) -> Int = { [.none, .other(megabits: nil), .g1, .g2_5, .g5, .g10].firstIndex(of: $0) ?? 1 }
        let linked = wired.map { ($0, readSpeed($0)) }.filter { $0.1 != .none }
        if let best = linked.max(by: { rank($0.1) < rank($1.1) })?.0 { return best }
        if let wifi = wifiInterfaces().first(where: { readSpeed($0.bsd) != .none }) { return wifi.bsd }
        return wired.first ?? "en0"
    }

    /// Wi‑Fi interfaces, as (BSD name, display name).
    static func wifiInterfaces() -> [(bsd: String, name: String)] {
        (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { i in
            guard SCNetworkInterfaceGetInterfaceType(i) as String? == kSCNetworkInterfaceTypeIEEE80211 as String,
                  let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { return nil }
            return (bsd, SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd)
        }
    }

    /// Wired first, then Wi‑Fi — the cards the settings offer.
    static func watchableInterfaces() -> [(bsd: String, name: String)] { wiredInterfaces() + wifiInterfaces() }

    static func isWiFi(_ name: String) -> Bool { CWWiFiClient.shared().interface(withName: name) != nil }

    /// Cards a test can be sent through: wired and Wi‑Fi ones that have an IPv4 address now.
    static func routeChoices() -> [(bsd: String, name: String)] { watchableInterfaces().filter { readIPv4($0.bsd) != nil } }

    /// "Wi‑Fi" or "Ethernet" — for the result line and the history table.
    static func routeKind(_ bsd: String) -> String { isWiFi(bsd) ? "Wi‑Fi" : "Ethernet" }

    /// "Wi‑Fi (en0)" or "Ethernet (en5)" — for the card picker.
    static func routeName(_ bsd: String) -> String { "\(routeKind(bsd)) (\(bsd))" }

    /// "5 GHz · 160 MHz · −29 dBm" for a Wi‑Fi interface with a link, nil otherwise. The network name needs
    /// location access, so it is left out.
    static func wifiSummary(_ name: String) -> String? {
        guard let i = CWWiFiClient.shared().interface(withName: name), i.transmitRate() > 0 else { return nil }
        var parts: [String] = []
        switch i.wlanChannel()?.channelBand {
        case .band2GHz?: parts.append("2.4 GHz")
        case .band5GHz?: parts.append("5 GHz")
        case .band6GHz?: parts.append("6 GHz")
        default: break
        }
        switch i.wlanChannel()?.channelWidth {
        case .width20MHz?: parts.append("20 MHz")
        case .width40MHz?: parts.append("40 MHz")
        case .width80MHz?: parts.append("80 MHz")
        case .width160MHz?: parts.append("160 MHz")
        default: break
        }
        parts.append("\(i.rssiValue()) dBm")
        return parts.joined(separator: " · ")
    }

    /// Wired interfaces the system knows, as (BSD name, display name).
    static func wiredInterfaces() -> [(bsd: String, name: String)] {
        (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { i in
            guard SCNetworkInterfaceGetInterfaceType(i) as String? == kSCNetworkInterfaceTypeEthernet as String,
                  let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { return nil }
            return (bsd, SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd)
        }
    }

    func refresh(force: Bool = false) {
        let newDetails = Self.readDetails(bsdName)
        if force || newDetails != details {
            details = newDetails
            onDetails?(newDetails)
        }
        var speed = Self.readSpeed(bsdName)
        if case .wifi(let mb) = speed { speed = .wifi(megabits: wifiRates.add(mb, at: Date())) } else { wifiRates = WiFiRates() }
        let new = State(speed: speed, ipv4: Self.readIPv4(bsdName))
        guard force || new != state else { return }
        state = new
        onChange?(new)
    }

    /// Wi‑Fi: CoreWLAN's transmit rate (0 = not joined). Wired: SIOCGIFXMEDIA, as `ifconfig` uses — SIOCGIFMEDIA
    /// hides the extended media words.
    static func readSpeed(_ name: String) -> LinkSpeed {
        if let wifi = CWWiFiClient.shared().interface(withName: name) {
            let rate = Int(wifi.transmitRate().rounded())
            return rate > 0 ? .wifi(megabits: rate) : .none
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .none }
        defer { close(fd) }
        var req = ifmediareq()
        withUnsafeMutableBytes(of: &req.ifm_name) { buf in
            name.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        // _IOWR('i', 72, struct ifmediareq)
        let size = UInt(MemoryLayout<ifmediareq>.size) & 0x1fff
        let request = 0xC000_0000 | (size << 16) | (UInt(UInt8(ascii: "i")) << 8) | 72
        guard ioctl(fd, request, &req) == 0 else { return .none }
        return LinkSpeed(media: req.ifm_active, status: req.ifm_status)
    }

    /// Supported media, duplex and flow control (SIOCGIFXMEDIA with a list), MTU and error counters (if_data).
    static func readDetails(_ name: String) -> LinkDetails {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return LinkDetails() }
        defer { close(fd) }
        var req = ifmediareq()
        withUnsafeMutableBytes(of: &req.ifm_name) { buf in
            name.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        let size = UInt(MemoryLayout<ifmediareq>.size) & 0x1fff
        let request = 0xC000_0000 | (size << 16) | (UInt(UInt8(ascii: "i")) << 8) | 72
        guard ioctl(fd, request, &req) == 0 else { return LinkDetails() }
        // The first call gives the count; the second fills the list.
        var supported = [Int32](repeating: 0, count: Int(max(req.ifm_count, 0)))
        if !supported.isEmpty {
            let filled = supported.withUnsafeMutableBufferPointer { list -> Bool in
                req.ifm_ulist = list.baseAddress
                defer { req.ifm_ulist = nil }
                return ioctl(fd, request, &req) == 0
            }
            if !filled { supported = [] }
        }
        let (mtu, errors) = readCounters(name)
        return LinkDetails(active: req.ifm_active, supported: supported, mtu: mtu, errors: errors)
    }

    /// MTU and input + output errors + collisions from the AF_LINK entry of getifaddrs.
    static func readCounters(_ name: String) -> (mtu: Int?, errors: UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (nil, 0) }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK), let raw = ifa.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return (Int(data.ifi_mtu), UInt64(data.ifi_ierrors) + UInt64(data.ifi_oerrors) + UInt64(data.ifi_collisions))
        }
        return (nil, 0)
    }

    /// The card's address: the one in the router's subnet when the default route goes through this card,
    /// otherwise the first. A card can carry a second address from another subnet, listed first even by the
    /// system (measured 2026-10-11: Wi‑Fi with an address from another subnet next to the real one).
    static func readIPv4(_ name: String) -> String? {
        sourceAddress(among: readIPv4Addresses(name), toward: router(of: name))
    }

    /// Every IPv4 address of the card with its subnet mask, in the system's order.
    static func readIPv4Addresses(_ name: String) -> [(address: String, mask: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        func text(_ addr: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let addr, addr.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { p in
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name) == name, let address = text(ifa.ifa_addr) else { return nil }
            return (address, text(ifa.ifa_netmask) ?? "255.255.255.255")
        }
    }

    /// The address from `list` in the same subnet as `target` (an IPv4 address), else the first one.
    static func sourceAddress(among list: [(address: String, mask: String)], toward target: String?) -> String? {
        if let t = target.flatMap(ipv4) {
            for entry in list {
                if let a = ipv4(entry.address), let m = ipv4(entry.mask), a & m == t & m { return entry.address }
            }
        }
        return list.first?.address
    }

    /// "192.0.2.10" as a number, nil for anything else.
    static func ipv4(_ text: String) -> UInt32? {
        var a = in_addr()
        return inet_pton(AF_INET, text, &a) == 1 ? UInt32(bigEndian: a.s_addr) : nil
    }

    /// The router of the default route when that route goes through this card.
    static func router(of name: String) -> String? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              global["PrimaryInterface"] as? String == name else { return nil }
        return global["Router"] as? String
    }

    /// Name the system shows for the interface, e.g. "USB 10/100/1G/2.5G/5G LAN".
    static func displayName(_ name: String) -> String {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = all.first { SCNetworkInterfaceGetBSDName($0) as String? == name }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name
    }
}

/// The highest Wi‑Fi rate within a minute.
struct WiFiRates {
    static let window: TimeInterval = 60
    private(set) var samples: [(date: Date, mb: Int)] = []

    /// Adds a reading and returns the best of the last minute.
    mutating func add(_ mb: Int, at now: Date) -> Int {
        samples = samples.filter { now.timeIntervalSince($0.date) < Self.window } + [(now, mb)]
        return samples.map(\.mb).max() ?? mb
    }
}
