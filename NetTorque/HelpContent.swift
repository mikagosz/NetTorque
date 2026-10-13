import Foundation

/// What the Help window says: each section is a picture of the app with numbered
/// points and the same numbers in the steps next to it. English source; the Polish text is in Localizable.xcstrings
/// (Tests/main.swift checks every string has its translation).
enum HelpContent {
    /// Which picture stands next to the section; drawn by the app itself in HelpWindow.swift.
    enum Picture { case icon, menu, test, result, slowLink, history, servers, settings }

    struct Section {
        let title: String
        let lead: String
        /// Numbered like the points on the picture: the first step is point 1.
        let steps: [String]
        /// The longer description, folded under "More".
        let more: String?
        let picture: Picture
    }

    struct Card {
        let symbol: String
        let title: String
        let text: String
    }

    static let title = "Getting started with NetTorque"
    static let intro = "See your wired link speed at a glance, and measure it in one click. The icon in the menu bar shows how fast the cable link is; the window copies data to a server and back and tells you how fast it really goes."

    static let sections: [Section] = [
        Section(title: "The icon in the menu bar",
                lead: "The icon is a network port in the colour of the link speed, so you see at once when the cable or the switch slows things down.",
                steps: ["Blue 1 Gb/s, green 2.5 Gb/s, orange 5 Gb/s, purple 10 Gb/s.",
                        "Grey: another speed, such as 100 Mb/s. Grey with a red slash: no cable link.",
                        "With the Wi‑Fi card chosen in the settings, the icon becomes a Wi‑Fi sign in the same colours."],
                more: "Wi‑Fi colours follow the radio's transmit rate: 600 Mb/s and more blue, 2000 green, 4000 orange, 8000 purple, below that grey. An idle radio slows down, so the icon shows the best rate of the last minute. The icon pulses while a test runs. In the settings, In the Menu Bar can put the link speed (\"5G\") or the last result (\"↑405 ↓464\") next to it.",
                picture: .icon),
        Section(title: "Left click and right click",
                lead: "Left click the icon for the test window. Right click (or Control-click) for the menu.",
                steps: ["The watched card, its link speed and its address.",
                        "Test runs a quick test with the last settings; the last result is shown under it.",
                        "Open the window, the history or the settings."],
                more: "Double-click NetTorque in Finder to open the window. At login it starts quietly in the menu bar. NetTorque shows in the Dock only while one of its windows is open.",
                picture: .menu),
        Section(title: "Measure the link",
                lead: "In the window pick how to test, where to and how much data, then press Test.",
                steps: ["The link of the watched card, its name and address.",
                        "From Memory sends generated data, so disks take no part. Disk to Disk copies a file from the Mac's disk to the server's disk and back.",
                        "The server, the size (1, 2, 5 or 10 GB) and Through — the card the test goes over.",
                        "Test starts it, Stop ends it at any moment. The test file is always removed on both sides."],
                more: "Through: Automatically lets the system choose the way; a particular Ethernet or Wi‑Fi card with an address forces the test over that card. A network folder always goes the system's way. 1 MB = 10⁶ bytes. SSH encryption takes its share: on a 5 GbE link expect about 400–460 MB/s rather than the line's ~590 MB/s.",
                picture: .test),
        Section(title: "Reading the result",
                lead: "Each direction gets its own number, in the colour of the device that sends.",
                steps: ["↑ Upload, from the Mac to the server, in the Mac's colour (blue).",
                        "↓ Download, from the server to the Mac, in the server's colour (green).",
                        "Size, mode and card of the test. The two buttons copy the result as a picture or save it as PNG."],
                more: "Clear empties the window; the result stays in the history. The shared picture says \"Mac\" and \"Server\" unless Show the Mac and server names on the result picture is on in the settings.",
                picture: .result),
        Section(title: "When the link is slower",
                lead: "When the link runs slower than the card can, at half duplex, or with errors, an orange warning appears next to the speed.",
                steps: ["The warning. Click it for the details.",
                        "What is wrong and what to check — usually the cable or the switch port.",
                        "What the card reports: its top speed, duplex, flow control, energy saving (EEE), MTU and errors."],
                more: nil,
                picture: .slowLink),
        Section(title: "History",
                lead: "Every finished test is kept, so you can see whether the link holds its speed over time.",
                steps: ["Show one server or all of them.",
                        "Upload and download over time.",
                        "Each test: when, where to, the mode, the speeds and the card it went through.",
                        "Export CSV… saves the table for a spreadsheet; Clear History… empties it."],
                more: "Open it with the clock under the gear in the window, or from the menu. NetTorque keeps the last 500 tests in ~/Library/Application Support/com.mikagosz.NetTorque/history.json.",
                picture: .history),
        Section(title: "Servers",
                lead: "A server is any computer you can reach with SSH — a NAS, a Linux box or another Mac. NetTorque logs in with your SSH key and never asks for a password.",
                steps: ["The server the test goes to, and its name in the results.",
                        "SSH server, network folder (SMB, NFS) or another Mac running NetTorque.",
                        "Address (IP, host name or an ~/.ssh/config alias) and SSH user.",
                        "Folder for the test file in Disk to Disk."],
                more: "Check first that ssh <address> in Terminal logs in without a password. If not, ssh-copy-id <address> puts your key on the server. Servers found on the network are listed under the list, with Add next to them.",
                picture: .servers),
        Section(title: "Settings",
                lead: "Open them with the gear in the window or Settings… in the menu.",
                steps: ["This Mac: the name used in results. Detect brings back the system's name.",
                        "Language: System, Polski or English; Restart NetTorque applies it.",
                        "Watched Card: which card the icon watches, wired or Wi‑Fi.",
                        "A notification when the link is lost or slows down, and Open NetTorque at Login."],
                more: "Slower Than sets what counts as slowing down: the best speed this card has had on this Mac (the default; Reset forgets it, e.g. after moving to another switch) or a fixed 1, 2.5, 5 or 10 Gb/s. A speed has to hold for 3 s before it counts.",
                picture: .settings),
    ]

    static let goodToKnow = "Good to know"
    static let cards: [Card] = [
        Card(symbol: "display.2", title: "Another Mac as the server",
             text: "Turn on Receive tests from other Macs on the second Mac. It shows a 6-digit code; pair it on the first Mac from the servers found on the network. No SSH needed."),
        Card(symbol: "folder.badge.gearshape", title: "A network folder",
             text: "A share mounted in Finder (SMB, NFS) can be the target too. The test writes a file there and reads it back, the way the system sends it."),
        Card(symbol: "lock", title: "Why not the full line speed",
             text: "Data goes through SSH and gets encrypted. On a 5 GbE link expect about 400–460 MB/s rather than the line's ~590 MB/s. From Memory shows the link; Disk to Disk adds both disks."),
        Card(symbol: "hand.raised", title: "What stays private",
             text: "The result picture names no device unless you allow it in the settings. The history stays on this Mac. Updates are checked once a month, only while that is turned on in the settings."),
    ]

    static let more = "More"
    /// The line under the Fractal 8 Dev signature — the same as under the title on fractal8.eu.
    static let signatureLine = "Native macOS software, built to a single pattern."
    static let less = "Less"

    /// Every string of the window, for the translation check.
    static var allStrings: [String] {
        var all = [title, intro, goodToKnow, more, less, signatureLine]
        for s in sections { all += [s.title, s.lead] + s.steps + (s.more.map { [$0] } ?? []) }
        for c in cards { all += [c.title, c.text] }
        return all
    }
}
