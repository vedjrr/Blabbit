import AppKit
import ApplicationServices
import Testing
@testable import UtterKit

/// True while the login session's screen is locked. The window server then
/// exposes no window contents to Accessibility, so these tests can't run.
func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// Real Accessibility writes against real AppKit controls in a helper process.
/// Needs an unlocked screen and an Accessibility-trusted test runner; otherwise skipped (reported as skipped).
@Suite(.serialized,
       .enabled(if: AXIsProcessTrusted(), "test runner is not trusted for Accessibility"),
       .enabled(if: !screenIsLocked(), "screen is locked; the window server exposes no window contents"))
struct AXIntegrationTests {
    static let hostURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/arm64-apple-macosx/release/UtterAXHost")

    /// Launches the host and waits for "READY <pid>".
    func launchHost(_ args: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = Self.hostURL
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        try #require(line.hasPrefix("READY"), "host did not start: \(line)")
        return process
    }

    /// Depth-first search of the host's AX tree for a text control. (With the
    /// host inactive, e.g. on a locked screen, the app's "focused element" is the
    /// app itself, so find the control structurally instead.)
    func firstTextElement(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, ["AXTextArea", "AXTextField"].contains(role) { return element }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = firstTextElement(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    func focused(in process: Process) async throws -> AXFocusedElement {
        let app = AXUIElementCreateApplication(process.processIdentifier)
        for _ in 0..<50 {
            if let found = firstTextElement(in: app) { return AXFocusedElement(element: found) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    @Test func insertsIntoRealTextViewAtCaret() async throws {
        let host = try launchHost()
        defer { host.terminate() }
        let element = try await focused(in: host)
        #expect(element.role == "AXTextArea")
        #expect(element.value == "Hello world")
        let result = AccessibilityInserter.insert(", dictated", into: element)
        #expect(result == .inserted)
        #expect(element.value == "Hello, dictated world")
    }

    @Test func detectsRealSecureTextField() async throws {
        let host = try launchHost(["--secure"])
        defer { host.terminate() }
        let element = try await focused(in: host)
        #expect(AccessibilityInserter.isSecure(element), "role=\(element.role ?? "nil") subrole=\(element.subrole ?? "nil")")
        #expect(AccessibilityInserter.insert("hunter2", into: element) == .secureField)
    }
}
