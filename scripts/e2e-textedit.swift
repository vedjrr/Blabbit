// End-to-end dry run of the dictation path without a human voice:
// holds the Blabbit shortcut (synthetic ⌥Space), plays a fixture through the
// speakers so the real microphone hears it, releases, then reads what landed in
// TextEdit via Accessibility and checks the clipboard is unchanged.
// Requires: Blabbit running with permissions; this process Accessibility-trusted.
// Usage: swift scripts/e2e-textedit.swift <scratch.txt> <clip.wav>...
import AppKit
import ApplicationServices

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

func focusedText(of pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}

func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2, AXIsProcessTrusted() else {
    print("usage: e2e-textedit <scratch.txt> <clip.wav>... (needs Accessibility)")
    exit(2)
}
if let front = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first,
   let pid = { () -> pid_t? in
       var app: CFTypeRef?
       guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success else { return nil }
       var pid: pid_t = 0
       return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
   }(), pid == front.processIdentifier {
    print("The screen is locked; unlock it and run again.")
    exit(1)
}
let scratch = URL(fileURLWithPath: args.first!)
try? "".write(to: scratch, atomically: true, encoding: .utf8)
let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-a", "TextEdit", scratch.path]
try open.run(); open.waitUntilExit()
/// Frontmost app via Accessibility (NSWorkspace needs a run loop to update).
func focusedAppPID() -> pid_t? {
    var app: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success else { return nil }
    var pid: pid_t = 0
    return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
}
var textEditPID: pid_t?
for _ in 0..<50 {
    Thread.sleep(forTimeInterval: 0.1)
    if let pid = focusedAppPID(), NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.TextEdit" {
        textEditPID = pid
        break
    }
}
guard let pid = textEditPID else {
    print("TextEdit did not become frontmost; aborting")
    exit(1)
}
struct Target { let processIdentifier: pid_t }
let textEdit = Target(processIdentifier: pid)
Thread.sleep(forTimeInterval: 0.5)
let clipboardBefore = clipboardText()
var previous = focusedText(of: textEdit.processIdentifier) ?? ""

for clip in args.dropFirst() {
    let reference = (try? String(contentsOfFile: clip.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    post(49, down: true, flags: .maskAlternate)         // hold ⌥Space
    Thread.sleep(forTimeInterval: 0.15)
    let play = Process()
    play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    play.arguments = [clip]
    try play.run(); play.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.25)
    post(49, down: false, flags: .maskAlternate)        // release
    let released = Date()
    var inserted = ""
    while Date().timeIntervalSince(released) < 6 {
        let now = focusedText(of: textEdit.processIdentifier) ?? ""
        if now.count > previous.count { inserted = String(now.dropFirst(previous.count)); Thread.sleep(forTimeInterval: 0.3); break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let now = focusedText(of: textEdit.processIdentifier) ?? ""
    inserted = String(now.dropFirst(previous.count))
    previous = now
    print("clip=\(clip)\nreference=\(reference)\ninserted=\(inserted)\nobserved_release_to_text_ms≈\(Int(Date().timeIntervalSince(released) * 1000)) (upper bound, polling)")
    post(36, down: true, flags: []); post(36, down: false, flags: []) // newline between clips
    previous += "\n"
    Thread.sleep(forTimeInterval: 2.5) // let Blabbit finish restoring the clipboard
}
let clipboardAfter = clipboardText()
print("clipboard_unchanged=\(clipboardBefore == clipboardAfter)")
// Save and close the scratch document.
post(1, down: true, flags: .maskCommand); post(1, down: false, flags: .maskCommand)   // ⌘S
Thread.sleep(forTimeInterval: 0.5)
post(13, down: true, flags: .maskCommand); post(13, down: false, flags: .maskCommand)  // ⌘W
