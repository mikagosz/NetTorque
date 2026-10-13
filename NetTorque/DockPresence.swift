import AppKit

/// NetTorque lives in the menu bar and shows in the Dock exactly while one of its own windows is open
/// (minimised counts, so it can be brought back). The only place that sets the activation policy.
/// A list of its own windows on purpose: the status item and open menus are windows too and must not count.
enum DockPresence {
    private static var windows: [NSWindow] = []

    /// Puts a window under the rule; call once, when the window is made.
    static func track(_ window: NSWindow) {
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            DispatchQueue.main.async { sync() }   // the window still counts as visible during willClose
        }
    }

    /// Brings NetTorque into the Dock and the window to the front.
    ///
    /// The plain `activate()` of macOS 14 only asks; right after the switch from menu bar only to the Dock the
    /// system turned it down and the window opened behind the others (reported 2026-10-10). So the
    /// window is put in front unconditionally, and the app is activated again on the next turn of the run loop,
    /// once the new activation policy has taken effect.
    static func show(_ window: NSWindow) {
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard wasAccessory else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func sync() {
        let open = windows.contains { $0.isVisible || $0.isMiniaturized }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }
}
