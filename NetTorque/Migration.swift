import Foundation

/// Until 0.1.20 the app was called SpeedLan (bundle ID com.mikagosz.SpeedLan). The first launch under the
/// new name copies its settings, so servers, the card, the language and the best speeds carry over.
enum Migration {
    static let oldDomain = "com.mikagosz.SpeedLan"
    static let oldCacheFolder = "com.mikagosz.SpeedLan"
    /// Test files of the old name, on the Mac and on servers.
    static let oldFilePrefix = "speedlan-"

    /// Before anything reads UserDefaults. Keys already set under the new name win.
    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "migratedFromSpeedLan") else { return }
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in Self.carried(old) where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromSpeedLan")
    }

    /// The old app's own keys, without the system's window frames (their names changed with the app).
    static func carried(_ old: [String: Any]) -> [String: Any] {
        old.filter { !$0.key.hasPrefix("NSWindow Frame ") && !$0.key.hasPrefix("NSStatusItem ") }
    }
}
