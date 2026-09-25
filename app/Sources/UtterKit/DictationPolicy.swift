import Foundation

/// Where a recording was started from; decides how the watchdog treats it.
public enum RecordingSource: Sendable, Equatable {
    /// The CGEventTap saw the shortcut.
    case tap
    /// The Carbon fallback (secure input is on, so the tap is blind).
    case carbon
    /// Start/Stop in the menu (toggle, no key to watch).
    case menu
}

/// Pure rules for the recording watchdog (tested without timers or keys).
public enum WatchdogPolicy {
    /// Returns why a recording should be force-released now, or nil.
    /// `keyUpChecks` counts consecutive "key not down" observations.
    public static func releaseReason(elapsed: TimeInterval, maxSeconds: TimeInterval, source: RecordingSource,
                                     keyDown: Bool, secureInput: Bool, keyUpChecks: inout Int) -> String? {
        if elapsed >= maxSeconds { return "max_length" }
        guard source != .menu else { return nil }
        // Only a tap recording is cut by secure input: the tap can no longer see
        // the key-up. Carbon recordings exist precisely because secure input is on.
        if source == .tap, secureInput { return "secure_input" }
        // Carbon delivers its own key-up, and key state may not be readable under
        // secure input; rely on the release event and the hard cap instead.
        if source == .carbon { return nil }
        if keyDown {
            keyUpChecks = 0
            return nil
        }
        keyUpChecks += 1
        return keyUpChecks >= 2 ? "key_not_down" : nil
    }
}

/// What to do with a transcript that secure input stopped Utter from typing.
public enum SecureInputFallback {
    public struct Action: Equatable, Sendable {
        public var copyToClipboard: Bool
        public var message: String
    }

    public static func action(secureFieldFocused: Bool) -> Action {
        if secureFieldFocused {
            // Never put what was said into a password flow, not even the clipboard.
            return Action(copyToClipboard: false, message: "A password field is focused, so Utter didn't type anything.")
        }
        return Action(copyToClipboard: true,
                      message: "Secure input is on (a password field or Secure Keyboard Entry elsewhere), so Utter didn't type. Your text replaced the clipboard: paste it with ⌘V.")
    }

    /// Insertion failed for another reason: keep the words rather than lose them.
    public static let failedMessagePrefix = "Utter couldn't type into this app, so your text replaced the clipboard: paste it with ⌘V."
}

public enum TranscriptPolicy {
    /// Noise that passes the level gate can transcribe to nothing (or only
    /// whitespace); such a result is skipped, never inserted.
    public static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}

/// A brief, visible cue on the menu bar icon for a dictation that needs the
/// user's attention (the menu text alone is invisible until opened).
public enum AttentionCue: Equatable, Sendable {
    /// Secure input or a password field stopped the insertion.
    case blocked
    /// Utter can't tell whether the text went in.
    case unconfirmed
}

/// What the controller does after an insertion attempt (pure, so it is tested).
public enum InsertionOutcome {
    public struct Plan: Equatable, Sendable {
        /// Put the transcript on the clipboard (replacing what was there).
        public var copyToClipboard = false
        public var message: String?
        public var cue: AttentionCue?
        /// Non-nil: show as a failure state.
        public var failure: String?
    }

    public static let unconfirmedMessage =
        "Utter couldn't confirm your text went in, so it replaced the clipboard. If it's missing, paste it with ⌘V."
    public static let clipboardUnreadableMessage =
        "Utter could not save your clipboard first, so the transcript was left on it. To keep your clipboard, allow Utter under System Settings → Privacy & Security → Paste from Other Apps."

    public static func plan(for report: InsertReport) -> Plan {
        var plan = Plan()
        switch report.result {
        case .inserted:
            if let paste = report.paste, !paste.clipboardReadable { plan.message = clipboardUnreadableMessage }
        case .unverified(let strategy):
            // The paste path already left the transcript on the clipboard (unless
            // the user copied something newer meanwhile, which must win).
            plan.copyToClipboard = strategy != .paste
            plan.message = unconfirmedMessage
            plan.cue = .unconfirmed
        case .copiedToClipboard, .handledByScript:
            break
        case .blockedBySecureInput:
            let action = SecureInputFallback.action(secureFieldFocused: report.secureFieldFocused)
            plan.copyToClipboard = action.copyToClipboard
            plan.message = action.message
            plan.cue = .blocked
        case .failed(let why):
            plan.copyToClipboard = true
            plan.failure = "\(SecureInputFallback.failedMessagePrefix) (\(why))"
        }
        return plan
    }
}
