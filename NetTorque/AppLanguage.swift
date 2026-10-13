import AppKit

/// Interface language chosen in the settings: "" follows the system, otherwise "pl" or "en".
/// Stored as AppleLanguages in NetTorque's own preferences; the system reads it at launch, so a change needs a restart.
enum AppLanguage {
    private static let key = "AppleLanguages"

    static var chosen: String {
        get {
            // Only NetTorque's own domain: UserDefaults.standard would also answer with the system-wide list.
            let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            return (own?[key] as? [String])?.first ?? ""
        }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set([newValue], forKey: key) }
        }
    }

    /// The choice the running copy started with.
    static let atLaunch = chosen

    /// Starts a new copy once this one has quit (a test in progress is stopped and cleaned up first).
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
