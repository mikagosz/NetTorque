import AppKit

// A test writes into ssh's input; if ssh dies, the write must fail with EPIPE instead of killing the app.
signal(SIGPIPE, SIG_IGN)

// `--export-help <folder>`: the Help page as PNG files, without the app's normal start (HelpWindow.swift).
if let export = HelpExport.fromArguments() {
    let app = NSApplication.shared
    app.delegate = export
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

Migration.run()   // settings of the old name, before anything reads them

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
