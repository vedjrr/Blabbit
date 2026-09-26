// Test-only helper (not shipped): hosts a real NSTextView (and an NSSecureTextField)
// so tests can exercise Accessibility insertion against genuine AppKit controls.
// Prints "READY <pid>" once the text view is first responder.
import AppKit

// Never outlive the test process: an orphaned host would keep the test
// runner's inherited file descriptors open and hang `swift test`.
let parent = getppid()
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    if getppid() != parent { exit(0) }
}

let app = NSApplication.shared
// Regular policy so the host can become frontmost for system-wide focus tests.
app.setActivationPolicy(CommandLine.arguments.contains("--frontmost") ? .regular : .accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let secure = CommandLine.arguments.contains("--secure")
if secure {
    let field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
    window.contentView?.addSubview(field)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(field)
} else {
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let textView = scroll.documentView as! NSTextView
    textView.string = "Hello world"
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    window.contentView?.addSubview(scroll)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
}
app.activate(ignoringOtherApps: true)
print("READY \(ProcessInfo.processInfo.processIdentifier)")
fflush(stdout)
app.run()
