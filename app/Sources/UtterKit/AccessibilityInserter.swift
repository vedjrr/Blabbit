import ApplicationServices
import Foundation

/// The focused text element, abstracted so insertion logic is testable without a real app.
public protocol FocusedTextElement {
    var role: String? { get }
    var subrole: String? { get }
    /// Whole field value, if the app exposes it.
    var value: String? { get }
    /// UTF-16 selection range, if exposed.
    var selectedRange: NSRange? { get }
    var canSetSelectedText: Bool { get }
    /// Replaces the selection (inserts at the caret). Returns false on AX error.
    func setSelectedText(_ text: String) -> Bool
}

public enum AXInsertResult: Equatable, Sendable {
    /// Inserted and confirmed by reading the field back.
    case inserted
    /// The focused field is a password field: nothing may be inserted.
    case secureField
    /// AX can't be used here (no focus, not a text field, not settable, AX error
    /// before any change). Safe to fall through to the next strategy.
    case notApplicable(String)
    /// AX reported success but the field did not change. Safe to fall through.
    case noEffect
    /// The field changed, but not as expected. Do NOT fall through (the text may
    /// be there already); report it instead of risking a duplicate.
    case unverified
}

public enum AccessibilityInserter {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public static func isSecure(_ element: FocusedTextElement) -> Bool {
        element.subrole == "AXSecureTextField" || element.role == "AXSecureTextField"
    }

    /// Some AX servers (busy native apps, Java/Qt/Electron) apply a write after
    /// the call returns, or after reporting a timeout. Wait this long before
    /// concluding a write had no effect.
    public static let settleDelay: TimeInterval = 0.15

    /// Pure decision + verification logic. `settle` runs between the two
    /// read-backs (a real sleep on the AX queue in production; never main).
    public static func insert(_ text: String, into element: FocusedTextElement?,
                              settle: () -> Void = { Thread.sleep(forTimeInterval: settleDelay) }) -> AXInsertResult {
        guard let element else { return .notApplicable("no focused element") }
        if isSecure(element) { return .secureField }
        guard let role = element.role, textRoles.contains(role) else {
            return .notApplicable("focused element is \(element.role ?? "unknown"), not a text field")
        }
        guard element.canSetSelectedText else { return .notApplicable("selected text is not settable") }
        // Verification needs the value; without it we could not tell a silent
        // no-op from success, so don't use AX at all.
        guard let before = element.value else { return .notApplicable("field value is not readable") }
        let selection = element.selectedRange
        let expectedLength = (before as NSString).length - (selection?.length ?? 0) + (text as NSString).length
        // Even an AX error (e.g. a messaging timeout) may still be applied later,
        // so every path reads back before deciding whether paste may run.
        let writeSucceeded = element.setSelectedText(text)

        /// nil = unchanged so far.
        func judge(_ after: String?) -> AXInsertResult? {
            guard let after else { return .unverified } // can't see the field any more: never retry
            if after == before { return nil }
            if (after as NSString).length == expectedLength, after.contains(text) { return .inserted }
            return .unverified
        }
        if let result = judge(element.value) { return result }
        settle()
        if let result = judge(element.value) { return result }
        // Readable and still unchanged after settling: nothing was applied, so the
        // next strategy may run.
        return writeSucceeded ? .noEffect : .notApplicable("AX write failed and the field did not change")
    }
}

/// Real `FocusedTextElement` backed by an AXUIElement. Use only on the AX queue.
public struct AXFocusedElement: FocusedTextElement {
    let element: AXUIElement
    /// Short timeout so a hung app can't stall insertion (default is ~6 s).
    public static let messagingTimeout: Float = 0.25

    /// The system-wide focused UI element, or nil.
    public static func current() -> AXFocusedElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXFocusedElement(element: element)
    }

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var value: String? { string(kAXValueAttribute) }

    public var selectedRange: NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    public var canSetSelectedText: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
    }

    public func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// PID of the app owning the element.
    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}
