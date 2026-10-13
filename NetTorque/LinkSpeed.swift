// Link speed of a wired interface, read from its active media word.

/// Media subtypes from <net/if_media.h> (IFM_ETHER family).
enum MediaSubtype {
    static let t10: Int32 = 3        // IFM_10_T
    static let tx100: Int32 = 6      // IFM_100_TX
    static let t1000: Int32 = 16     // IFM_1000_T
    static let t10G: Int32 = 21      // IFM_10G_T
    static let t2500: Int32 = 22     // IFM_2500_T
    static let t5000: Int32 = 23     // IFM_5000_T
}

enum LinkSpeed: Equatable {
    case none
    case g1
    case g2_5
    case g5
    case g10
    /// Linked, but at a speed without its own colour (e.g. 100 Mb/s).
    case other(megabits: Int?)
    /// Wi‑Fi: the radio's current transmit rate, which changes all the time.
    case wifi(megabits: Int)

    /// From SIOCGIFXMEDIA: `ifm_active` and `ifm_status`. Only Ethernet counts — Wi‑Fi media words
    /// (IFM_IEEE80211) use the same subtype numbers for other things.
    init(media: Int32, status: Int32) {
        let ethernet = media & 0xe0 == 0x20           // IFM_NMASK == IFM_ETHER
        self.init(subtype: media & 0x1f, active: ethernet && status & 0x2 != 0)   // IFM_TMASK_COMPAT, IFM_ACTIVE
    }

    /// `active` is IFM_ACTIVE from ifm_status; `subtype` is IFM_SUBTYPE(ifm_active).
    init(subtype: Int32, active: Bool) {
        guard active else { self = .none; return }
        switch subtype {
        case MediaSubtype.t1000: self = .g1
        case MediaSubtype.t2500: self = .g2_5
        case MediaSubtype.t5000: self = .g5
        case MediaSubtype.t10G: self = .g10
        case MediaSubtype.tx100: self = .other(megabits: 100)
        case MediaSubtype.t10: self = .other(megabits: 10)
        default: self = .other(megabits: nil)
        }
    }

    /// For the menu bar: "1G", "2.5G", "5G", "10G", "100M", "—".
    var shortLabel: String {
        switch self {
        case .none: return "—"
        case .g1: return "1G"
        case .g2_5: return String(localized: "2.5G")
        case .g5: return "5G"
        case .g10: return "10G"
        case .other(let mb?): return "\(mb)M"
        case .other(nil): return "?"
        case .wifi(let mb): return mb >= 1000 ? String(format: "%.1fG", locale: .current, Double(mb) / 1000) : "\(mb)M"
        }
    }

    /// Wi‑Fi rates in the wired colours, by the wired class they stand beside: 600 Mb/s and more blue (1G),
    /// 2000 green (2.5G), 4000 orange (5G), 8000 purple (10G); below 600 grey.
    var colourName: String {
        switch self {
        case .none: return "none"
        case .g1: return "1g"
        case .g2_5: return "2_5g"
        case .g5: return "5g"
        case .g10: return "10g"
        case .other: return "other"
        case .wifi(let mb):
            switch mb {
            case 8000...: return "10g"
            case 4000...: return "5g"
            case 2000...: return "2_5g"
            case 600...: return "1g"
            default: return "other"
            }
        }
    }

    var label: String {
        switch self {
        case .none: return String(localized: "no connection")
        case .g1: return "1 Gb/s"
        case .g2_5: return String(localized: "2.5 Gb/s")
        case .g5: return "5 Gb/s"
        case .g10: return "10 Gb/s"
        case .other(let mb?): return "\(mb) Mb/s"
        case .other(nil): return String(localized: "other speed")
        // String(mb), not the number itself: a localized number gets a thousands separator, and with English next to
        // a Polish region "2.401 Mb/s" read as 2.4 (2026-10-11).
        case .wifi(let mb): return String(localized: "Wi‑Fi \(String(mb)) Mb/s")
        }
    }
}
