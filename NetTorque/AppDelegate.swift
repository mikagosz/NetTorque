import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = TestController()
    private lazy var settings = SettingsWindow(controller: controller)
    private lazy var history = HistoryWindow(controller: controller)
    private lazy var window = TestWindow(controller: controller,
                                         openSettings: { [weak self] in self?.settings.show() },
                                         openHistory: { [weak self] in self?.history.show() })
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var observers: [AnyCancellable] = []
    private var pulse: Timer?
    private weak var statusLine: NSMenuItem?

    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Read before the launch event is gone: a login launch must not open the window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let flagged = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // SMAppService does not always set the flag; a launch right after boot with autostart on counts too.
        let earlyAutostart = SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 180
        launchedAtLogin = flagged || earlyAutostart
        NSApp.mainMenu = makeMainMenu()
    }

    /// The app menu shown while a window keeps NetTorque in the Dock: quit, close, and copy/paste in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        func entry(_ title: String, _ action: Selector?, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        submenu("NetTorque", [
            entry(String(localized: "Settings…"), #selector(openSettings), ",", target: self),
            entry(String(localized: "Check for Updates…"), #selector(checkForUpdates), "", target: self),
            .separator(),
            entry(String(localized: "Quit NetTorque"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        let redo = entry(String(localized: "Redo"), Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu(String(localized: "Edit"), [
            entry(String(localized: "Undo"), Selector(("undo:")), "z"), redo, .separator(),
            entry(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            entry(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            entry(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            entry(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(String(localized: "Window"), [
            entry(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            entry(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    /// Quitting during a test stops it first, so its files on the server and on the Mac are removed.
    /// Covers the menu, logging out and restarting; a server that does not answer cannot hold it up past 15 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.running else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        controller.cancelTest(then: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: reply)
        return .terminateLater
    }

    /// Double-clicking NetTorque while it runs opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observers = [
            controller.$link.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } },
            controller.$menuBarText.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } },
            controller.$lastOutcome.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } },
            controller.$running.sink { [weak self] running in running ? self?.startPulse() : self?.stopPulse() },
            controller.$status.sink { [weak self] text in self?.statusLine?.title = text },   // live while the menu is open
        ]
        controller.start()
        Updates.shared.isBusy = { [weak self] in self?.controller.running ?? false }
        Updates.shared.start()
        if !launchedAtLogin { window.show() }   // started by a double-click: show the window right away
    }

    private func updateIcon() {
        statusItem.button?.image = PortIcon.image(for: controller.link.speed, wifi: controller.isWiFi)
        if let title = TestController.menuBarTitle(controller.menuBarText, link: controller.link.speed, outcome: controller.lastOutcome) {
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .medium),
            ])
        } else {
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = "NetTorque — \(controller.link.speed.label)"
    }

    /// Left click opens the window, right click (or Control-click) shows the menu.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // so the next left click reaches clicked() again
        } else {
            window.show()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.monitor.refresh()
        menu.removeAllItems()
        menu.addItem(info(String(localized: "Card: \(controller.interfaceName)")))
        menu.addItem(info(String(localized: "Link speed: \(controller.link.speed.label)")))
        for hint in controller.hints { menu.addItem(info(hint.menuText)) }
        if let wifi = LinkMonitor.wifiSummary(controller.monitor.bsdName) { menu.addItem(info(wifi)) }
        menu.addItem(info(String(localized: "Address: \(controller.link.ipv4 ?? "—")")))
        menu.addItem(.separator())
        if controller.running {
            let line = info(controller.status)
            statusLine = line
            menu.addItem(line)
            menu.addItem(item(String(localized: "Stop Test"), #selector(cancelTest), "."))
        } else {
            let test = item(String(localized: "Test: \(controller.testTargetName)"), #selector(startTest), "t")
            test.isEnabled = controller.canTest
            menu.addItem(test)
        }
        if let o = controller.lastOutcome { menu.addItem(info(TestController.summary(o))) }
        if let note = controller.lastNote { menu.addItem(info(note)) }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open NetTorque Window…"), #selector(openWindow), "o"))
        menu.addItem(item(String(localized: "History…"), #selector(openHistory), "y"))
        menu.addItem(item(String(localized: "Settings…"), #selector(openSettings), ","))
        menu.addItem(withTitle: String(localized: "Quit NetTorque"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(.separator())
        menu.addItem(info("NetTorque \(TestController.version)"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func startTest() { controller.startTest() }
    @objc private func cancelTest() { controller.cancelTest() }
    @objc private func openWindow() { window.show() }
    @objc private func openSettings() { settings.show() }
    @objc private func openHistory() { history.show() }
    @objc private func checkForUpdates() { Task { await Updates.shared.check(manually: true) } }

    // MARK: Pulse while testing

    private func startPulse() {
        guard pulse == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            button.alphaValue = button.alphaValue < 1 ? 1 : 0.35
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps pulsing while the menu is open
        pulse = timer
    }

    private func stopPulse() {
        pulse?.invalidate()
        pulse = nil
        statusItem.button?.alphaValue = 1
    }
}
