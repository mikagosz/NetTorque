// What the card reports beside its speed, and what that says about the link.

/// Media word options from <net/if_media.h> (IFM_GMASK).
enum MediaOption {
    static let fullDuplex: Int32 = 0x0010_0000    // IFM_FDX
    static let halfDuplex: Int32 = 0x0020_0000    // IFM_HDX
    static let flowControl: Int32 = 0x0040_0000   // IFM_FLOW
    static let energyEfficient: Int32 = 0x0080_0000   // IFM_EEE
    /// IFM_TMASK: the low bits plus the extended sub-type bits, so an extended type never passes for an old one.
    static let subtypeMask: Int32 = 0x000f_001f
}

struct LinkDetails: Equatable {
    /// The fastest speed among the card's supported media (nil when the card lists none we know).
    var maxSpeed: LinkSpeed?
    var fullDuplex = false
    var halfDuplex = false
    var flowControl = false
    var energyEfficient = false
    var mtu: Int?
    /// Input + output errors and collisions since the card came up (if_data).
    var errors: UInt64 = 0

    /// From SIOCGIFXMEDIA: the active word (options) and the supported list (`ifm_ulist`).
    init(active: Int32, supported: [Int32], mtu: Int?, errors: UInt64) {
        let speeds = supported
            .filter { $0 & 0xe0 == 0x20 }   // Ethernet only, as in LinkSpeed
            .map { LinkSpeed(subtype: $0 & MediaOption.subtypeMask, active: true) }
            .filter { $0.megabitsPerSecond > 0 }
        maxSpeed = speeds.max { $0.megabitsPerSecond < $1.megabitsPerSecond }
        fullDuplex = active & MediaOption.fullDuplex != 0
        halfDuplex = active & MediaOption.halfDuplex != 0
        flowControl = active & MediaOption.flowControl != 0
        energyEfficient = active & MediaOption.energyEfficient != 0
        self.mtu = mtu
        self.errors = errors
    }

    init() {}

    /// Apple's generic USB class drivers (NCM, ECM) list every speed up to 10G whatever the chip can do
    /// (measured 2026-10-14: RTL8157 5G card on macOS 27.2 bound to `com.apple.driver.usb.cdc.ncm`
    /// instead of Realtek's driver). Their supported list says nothing about the card.
    static func trustsSupportedList(driver bundleID: String?) -> Bool {
        !(bundleID?.hasPrefix("com.apple.driver.usb.cdc") ?? false)
    }
}

/// A problem worth a line under the speed. Only while there is a link.
enum LinkHint: Equatable {
    /// The card can go faster than the link runs: the far end or the cable holds it back.
    case slowerThanCard(card: LinkSpeed, link: LinkSpeed)
    /// The two ends negotiated half duplex.
    case halfDuplex
    /// Errors grew since this link came up.
    case errors(count: UInt64)

    /// `errorsBefore`: the count when this link came up (nil = not known yet).
    static func check(speed: LinkSpeed, details: LinkDetails, errorsBefore: UInt64?) -> [LinkHint] {
        guard speed != .none else { return [] }
        if case .wifi = speed { return [] }   // cable advice means nothing on Wi‑Fi
        var hints: [LinkHint] = []
        if let max = details.maxSpeed, speed.megabitsPerSecond > 0, speed.isBelow(max) {
            hints.append(.slowerThanCard(card: max, link: speed))
        }
        if details.halfDuplex { hints.append(.halfDuplex) }
        if let before = errorsBefore, details.errors > before {
            hints.append(.errors(count: details.errors - before))
        }
        return hints
    }

    /// Next to the speed in the window.
    var shortText: String {
        switch self {
        case let .slowerThanCard(card, _): return String(localized: "Card supports \(card.label)")
        case .halfDuplex: return String(localized: "Half duplex")
        case let .errors(count): return String(localized: "\(count) errors")
        }
    }

    /// One line in the status menu.
    var menuText: String { String(localized: "⚠ \(shortText) — check the cable") }

    var text: String {
        switch self {
        case let .slowerThanCard(card, link):
            let cable = card.megabitsPerSecond > LinkSpeed.g5.megabitsPerSecond ? "Cat 6a" : "Cat 5e"
            return String(localized: "The card supports \(card.label), but the link runs at \(link.label). Check that the cable goes to a fast switch port, not a slower router, and that it is \(cable) or better.")
        case .halfDuplex:
            return String(localized: "The link runs half duplex — the two ends negotiated badly. Replug the cable or set the switch port to Auto.")
        case let .errors(count):
            return String(localized: "Since the link came up the card counted \(count) transmission errors — usually a damaged cable or plug.")
        }
    }
}
