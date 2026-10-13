import AppKit

// A test writes into ssh's input; if ssh dies, the write must fail with EPIPE instead of killing the app.
signal(SIGPIPE, SIG_IGN)

Migration.run()   // settings of the old name, before anything reads them

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
