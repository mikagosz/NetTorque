import AppKit
import SwiftUI

/// Settings: this Mac's name, the watched card and the servers to test.
final class SettingsWindow {
    private var window: NSWindow?
    private let controller: TestController

    init(controller: TestController) { self.controller = controller }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = String(localized: "NetTorque Settings")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            w.setContentSize(NSSize(width: 520, height: 600))   // default, first opening only
            w.center()
            w.setFrameAutosaveName("NetTorque.Ustawienia")        // last, so the saved size and place win
            DockPresence.track(w)
            window = w
        }
        controller.refreshNotifications()   // the user may have changed it in System Settings meanwhile
        controller.refreshAutostart()
        if let window {
            DockPresence.show(window)
            // No field takes the keyboard on opening: AppKit would put it in "Name in Results" with the text
            // selected, and the first key pressed replaced the name (2026-10-10: the name became "6").
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: TestController
    @State private var interfaces = LinkMonitor.watchableInterfaces()
    @StateObject private var browser = ServiceBrowser()
    @State private var mountedShares = ServiceBrowser.mountedShares()
    @ObservedObject private var updates = Updates.shared
    @State private var resolving: ServiceBrowser.Found?
    @State private var pairing: ServiceBrowser.Found?
    @State private var pairCode = ""
    @State private var language = AppLanguage.chosen

    var body: some View {
        Form {
            Section("This Mac") {
                HStack {
                    TextField("Name in Results", text: $controller.macName)
                    Button("Detect") { controller.macName = TestController.detectedMacName }
                        .help("Name from the system: \(TestController.detectedMacName)")
                }
            }

            Section("Language") {
                Picker("Language", selection: $language) {
                    Text("System").tag("")
                    Text(verbatim: "Polski").tag("pl")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: language) { _, new in AppLanguage.chosen = new }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("The new language appears after NetTorque restarts.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart NetTorque") { AppLanguage.relaunch() }
                    }
                }
            }

            Section("Network Card") {
                Picker("Watched Card", selection: $controller.interfaceBSD) {
                    ForEach(interfaces, id: \.bsd) { i in
                        Text(i.name.contains(i.bsd) ? i.name : "\(i.name) (\(i.bsd))").tag(i.bsd)
                    }
                    if !interfaces.contains(where: { $0.bsd == controller.interfaceBSD }) {
                        Text("\(controller.interfaceBSD) — not connected now").tag(controller.interfaceBSD)
                    }
                }
            }

            Section("Notifications and Startup") {
                Toggle("Notify when the link is lost or slows down", isOn: $controller.notifyOnDrop)
                // Wi‑Fi changes its rate all the time, so only a lost connection alerts there (TestController.settle).
                if controller.isWiFi {
                    Text("Wi‑Fi changes its speed all the time, so on Wi‑Fi NetTorque only tells you when the connection is lost.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Slower Than", selection: $controller.dropFloor) {
                        Text("The best speed of this card").tag(DropFloor.best)
                        Text(verbatim: LinkSpeed.g1.label).tag(DropFloor.g1)
                        Text(verbatim: LinkSpeed.g2_5.label).tag(DropFloor.g2_5)
                        Text(verbatim: LinkSpeed.g5.label).tag(DropFloor.g5)
                        Text(verbatim: LinkSpeed.g10.label).tag(DropFloor.g10)
                    }
                    .disabled(!controller.notifyOnDrop)
                }
                if !controller.isWiFi && controller.dropFloor == .best {
                    HStack {
                        Text("Best so far: \(controller.bestSpeed?.label ?? String(localized: "not known yet"))")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { controller.resetBestSpeed() }
                            .disabled(controller.bestSpeed == nil)
                    }
                }
                if controller.notifyOnDrop && controller.notificationsDenied {
                    Text("Notifications for NetTorque are turned off in System Settings → Notifications.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Picker("In the Menu Bar", selection: $controller.menuBarText) {
                    Text("Icon only").tag(TestController.MenuBarText.none)
                    Text("Icon and link speed").tag(TestController.MenuBarText.link)
                    Text("Icon and last result").tag(TestController.MenuBarText.result)
                }
                Toggle("Show the Mac and server names on the result picture", isOn: $controller.shareNames)
                Toggle("Open NetTorque at Login", isOn: Binding(
                    get: { controller.autostart == .enabled || controller.autostart == .requiresApproval },
                    set: { controller.setAutostart($0) }))
                if controller.autostart == .requiresApproval {
                    Text("Approve it in System Settings → General → Login Items & Extensions.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Tested Server", selection: $controller.serverID) {
                    ForEach(controller.servers) { Text($0.name.isEmpty ? String(localized: "unnamed") : $0.name).tag($0.id) }
                }
                if let index = controller.servers.firstIndex(where: { $0.id == controller.serverID }) {
                    TextField("Name", text: $controller.servers[index].name, prompt: Text("e.g. nas"))
                    Picker("Type", selection: Binding(get: { controller.servers[index].isFolder },
                                                      set: { controller.servers[index].isNetworkFolder = $0 })) {
                        Text("SSH server").tag(false)
                        Text("Network folder (SMB, NFS)").tag(true)
                    }
                    if controller.servers[index].isFolder {
                        HStack {
                            TextField("Folder on This Mac", text: $controller.servers[index].folder, prompt: Text("e.g. /Volumes/nas"))
                            Button("Choose…") { chooseFolder(index) }
                        }
                        let path = controller.servers[index].folder
                        if !path.isEmpty, !SpeedTest.isNetworkFolder(path) {
                            Text("This folder is not on a network share — the test would measure a disk of this Mac.")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    } else {
                        TextField("Address", text: $controller.servers[index].host, prompt: Text("IP, name or SSH alias"))
                        TextField("SSH User", text: $controller.servers[index].user, prompt: Text("as in ~/.ssh/config"))
                        TextField("Folder for the Test File", text: $controller.servers[index].folder, prompt: Text("e.g. /tmp"))
                    }
                }
                HStack {
                    Button("Add Server") { controller.addServer() }
                        .disabled(controller.servers.contains(where: TestController.isBlank))
                        .help(controller.servers.contains(where: TestController.isBlank)
                              ? String(localized: "First fill in the address of the server you already added") : "")
                    Button("Remove This Server", role: .destructive) { controller.removeServer(controller.serverID) }
                        .disabled(controller.servers.count < 2)
                }
                let mounted = mountedShares.filter { m in !controller.servers.contains { $0.isFolder && $0.folder == m.path } }
                if !mounted.isEmpty {
                    Text("Mounted in Finder").font(.callout).foregroundStyle(.secondary)
                    ForEach(mounted) { m in
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            Text(verbatim: m.name)
                            Text(verbatim: m.host.isEmpty ? m.path : "\(m.host) · \(m.path)").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Add") { controller.addFound(name: m.name, host: "", folder: true, path: m.path) }
                        }
                    }
                }
                if !browser.found.isEmpty {
                    Text("Found on the network").font(.callout).foregroundStyle(.secondary)
                    ForEach(browser.found) { f in
                        HStack {
                            Image(systemName: f.kind == .smb ? "externaldrive.connected.to.line.below" : f.kind == .peer ? "laptopcomputer" : "terminal")
                            Text(verbatim: f.name)
                            Text(f.kind == .smb ? "SMB share" : f.kind == .peer ? "NetTorque" : "SSH").font(.callout).foregroundStyle(.secondary)
                            if let ip = browser.addresses[f.id], !ip.isEmpty {
                                Text(verbatim: "· \(ip)").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if f.kind == .peer {
                                Button("Pair…") { pairing = f; pairCode = "" }
                            } else if isOnList(f) {
                                Button("On the List") {}
                                    .disabled(true)
                            } else {
                                Button(f.kind == .smb && !isMounted(f) ? "Connect in Finder…" : "Add") { add(f) }
                                    .disabled(resolving == f)
                            }
                        }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("NetTorque signs in with an SSH key, like `ssh <address>` in Terminal — it never asks for a password. A network folder is one mounted in Finder; the test writes a file there and reads it back. The test file is always removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Receive tests from other Macs", isOn: $controller.receiveTests)
                if controller.receiveTests {
                    HStack {
                        Text("Code for pairing")
                        Spacer()
                        Text(verbatim: controller.ownPeerCode).font(.title3.monospacedDigit()).textSelection(.enabled)
                        Button("New Code") { controller.newPeerCode() }
                    }
                    if let problem = controller.receiverProblem {
                        Text("Receiving does not work: \(problem)").font(.callout).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Tests from Other Macs")
            } footer: {
                Text("Another Mac with NetTorque finds this one under Servers → Found on the network and pairs with the code. Every connection has to prove it knows the code; after five wrong codes from one address NetTorque turns that address away for ten minutes, and Macs that already showed the right code keep getting in. Test data is random and is never stored. A new code ends every pairing.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: TestController.version)
                Toggle("Check for updates once a month", isOn: Binding(get: { updates.enabled }, set: { updates.enabled = $0 }))
                HStack {
                    if let last = updates.lastCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { Task { await updates.check(manually: true) } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(controller.running)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onDisappear { browser.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            mountedShares = ServiceBrowser.mountedShares()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            mountedShares = ServiceBrowser.mountedShares()
        }
        .sheet(item: $pairing) { f in
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair with \(f.name)").font(.headline)
                Text("Type the 6-digit code shown on that Mac in Settings → Tests from Other Macs.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Code", text: $pairCode).textFieldStyle(.roundedBorder).font(.title3.monospacedDigit())
                HStack {
                    Spacer()
                    Button("Cancel") { pairing = nil }.keyboardShortcut(.cancelAction)
                    Button("Pair") { controller.addPeer(name: f.name, code: pairCode); pairing = nil }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!PeerProtocol.isValidCode(pairCode))
                }
            }
            .padding(20)
            .frame(width: 340)
        }
        .onAppear {
            browser.ownNames.insert(controller.macName)
            browser.start()
            mountedShares = ServiceBrowser.mountedShares()
            interfaces = LinkMonitor.watchableInterfaces()
            controller.refreshAutostart()
        }
    }

    /// A found share whose address is already mounted in Finder.
    private func isMounted(_ f: ServiceBrowser.Found) -> Bool {
        guard let ip = browser.addresses[f.id], !ip.isEmpty else { return false }
        return mountedShares.contains { $0.host == ip }
    }

    /// Already a server: an SSH one under this name or at its address, or the folder of this share mounted in Finder.
    private func isOnList(_ f: ServiceBrowser.Found) -> Bool {
        let ip = browser.addresses[f.id] ?? ""
        switch f.kind {
        case .ssh:
            return TestController.existing(in: controller.servers, name: f.name, host: ip, folder: false, path: "") != nil
        case .smb:
            guard !ip.isEmpty else { return false }
            return mountedShares.contains { m in m.host == ip && controller.servers.contains { $0.isFolder && $0.folder == m.path } }
        case .peer:
            return false
        }
    }

    /// SSH: added with its address. SMB: Finder connects (and asks for the login); the folder is chosen after.
    private func add(_ f: ServiceBrowser.Found) {
        resolving = f
        ServiceBrowser.resolve(f) { host in
            resolving = nil
            guard let host else { return }
            switch f.kind {
            case .ssh:
                controller.addFound(name: f.name, host: host, folder: false)
            case .smb:
                if let m = mountedShares.first(where: { $0.host == host }) {
                    controller.addFound(name: m.name, host: "", folder: true, path: m.path)
                } else if let url = URL(string: "smb://\(host)/") {
                    NSWorkspace.shared.open(url)   // once mounted, it shows under "Mounted in Finder"
                }
            case .peer:
                break   // paired with a code, not added by address
            }
        }
    }

    private func chooseFolder(_ index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.servers[index].folder = url.path
        if controller.servers[index].name.isEmpty || controller.servers[index].name == String(localized: "New Server") {
            controller.servers[index].name = url.lastPathComponent
        }
    }
}
