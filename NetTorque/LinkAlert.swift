/// When the link is worth a notification: it was lost, or it fell below the chosen floor.
struct LinkAlert: Equatable {
    let title: String
    let body: String

    /// - `lastLinked`: the last speed seen while connected, before `current` (nil right after launch).
    /// - `floor`: a speed below this is a fall (nil = no floor known yet, only a loss alerts).
    /// - A return after a loss at a lower speed counts as a fall, measured against `lastLinked`.
    static func check(lastLinked: LinkSpeed?, previous: LinkSpeed, current: LinkSpeed,
                      floor: LinkSpeed?, card: String, wifi: Bool = false) -> LinkAlert? {
        if current == .none, previous != .none {
            return LinkAlert(title: wifi ? String(localized: "Wi‑Fi connection lost") : String(localized: "Wired connection lost"),
                             body: String(localized: "\(card) lost its connection."))
        }
        if let floor, current.isBelow(floor), let before = lastLinked, !before.isBelow(floor) {
            return LinkAlert(title: String(localized: "Link slowed to \(current.label)"),
                             body: String(localized: "\(card): was \(before.label), now \(current.label)."))
        }
        return nil
    }
}

/// Which speed counts as a fall. Stored under the key `dropFloor`.
enum DropFloor: String, CaseIterable {
    /// The best speed this card has had on this Mac (learned, can be reset in the settings).
    case best
    case g1, g2_5, g5, g10

    /// The floor for a card whose best speed so far is `best`.
    func speed(best: LinkSpeed?) -> LinkSpeed? {
        switch self {
        case .best: return best
        case .g1: return .g1
        case .g2_5: return .g2_5
        case .g5: return .g5
        case .g10: return .g10
        }
    }
}

extension LinkSpeed {
    /// For comparing speeds; 0 when not linked or the speed is unknown.
    var megabitsPerSecond: Int {
        switch self {
        case .none: return 0
        case .g1: return 1_000
        case .g2_5: return 2_500
        case .g5: return 5_000
        case .g10: return 10_000
        case .other(let mb): return mb ?? 0
        case .wifi(let mb): return mb
        }
    }

    /// Linked, but slower than `floor`.
    func isBelow(_ floor: LinkSpeed) -> Bool {
        self != .none && megabitsPerSecond < floor.megabitsPerSecond
    }

    /// The inverse of `megabitsPerSecond` for the stored best speed.
    init?(megabitsPerSecond mb: Int) {
        switch mb {
        case 1_000: self = .g1
        case 2_500: self = .g2_5
        case 5_000: self = .g5
        case 10_000: self = .g10
        case 1...: self = .other(megabits: mb)
        default: return nil
        }
    }
}
