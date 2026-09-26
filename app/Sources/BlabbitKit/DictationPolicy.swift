import Foundation

/// Where a recording was started from; decides how the watchdog treats it.
public enum RecordingSource: Sendable, Equatable {
    /// The CGEventTap saw the shortcut.
    case tap
    /// The Carbon fallback (secure input is on, so the tap is blind).
    case carbon
    /// Start/Stop in the menu (toggle, no key to watch).
    case menu
    /// The shortcut in toggle mode: pressed once to start, again to stop.
    case toggle
}

/// How the dictation shortcut behaves (G1: push-to-talk and toggle).
public enum DictationMode: String, Codable, CaseIterable, Sendable {
    /// Hold to record, release to transcribe.
    case pushToTalk
    /// Press to start, press again to stop.
    case toggle
    /// Hold to talk, or tap to keep recording until the next press; decided by
    /// how long the key was held (`holdThresholdMs`).
    case holdOrToggle

    public static let defaultsKey = "dictation.mode"
    public static let holdThresholdKey = "dictation.holdThresholdMs"
    /// Same default as Handy (`default_hold_threshold_ms`).
    public static let defaultHoldThresholdMs = 300
    public static let holdThresholdRange = 100...1000

    public var title: String {
        switch self {
        case .pushToTalk: "Hold to Talk"
        case .toggle: "Press to Start and Stop"
        case .holdOrToggle: "Hold to Talk, or Tap to Start and Stop"
        }
    }

    /// Word for the menu's "Shortcut: hold ⌥Space" line.
    public var verb: String {
        switch self {
        case .pushToTalk: "hold"
        case .toggle: "press"
        case .holdOrToggle: "hold or tap"
        }
    }

    public static func holdThresholdMs(from defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: holdThresholdKey)
        return saved == 0 ? defaultHoldThresholdMs : min(max(saved, holdThresholdRange.lowerBound), holdThresholdRange.upperBound)
    }

    public static func load(from defaults: UserDefaults = .standard) -> DictationMode {
        defaults.string(forKey: defaultsKey).flatMap(DictationMode.init(rawValue:)) ?? .pushToTalk
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// What a shortcut key event does, given the mode and whether a recording runs.
public enum HotkeyPolicy {
    /// `latch`: a short tap in hold-or-toggle mode; keep recording until the next press.
    public enum Decision: Equatable, Sendable { case start, stop, latch, ignore }

    /// `heldMs`: how long the key was down, for a key-up (hold-or-toggle only).
    public static func decide(keyDown: Bool, mode: DictationMode, recording: Bool,
                              heldMs: Double = 0, thresholdMs: Int = DictationMode.defaultHoldThresholdMs) -> Decision {
        switch (mode, keyDown) {
        case (.pushToTalk, true): return recording ? .ignore : .start
        case (.pushToTalk, false): return recording ? .stop : .ignore
        case (.toggle, true): return recording ? .stop : .start
        case (.toggle, false): return .ignore
        case (.holdOrToggle, true): return recording ? .stop : .start
        case (.holdOrToggle, false):
            guard recording else { return .ignore }
            return heldMs >= Double(thresholdMs) ? .stop : .latch
        }
    }
}

/// Pure rules for the recording watchdog (tested without timers or keys).
public enum WatchdogPolicy {
    /// Returns why a recording should be force-released now, or nil.
    /// `keyUpChecks` counts consecutive "key not down" observations.
    public static func releaseReason(elapsed: TimeInterval, maxSeconds: TimeInterval, source: RecordingSource,
                                     keyDown: Bool, secureInput: Bool, keyUpChecks: inout Int) -> String? {
        if elapsed >= maxSeconds { return "max_length" }
        // Menu and toggle recordings have no key held down to watch.
        guard source != .menu, source != .toggle else { return nil }
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

/// What to do with a transcript that secure input stopped Blabbit from typing.
public enum SecureInputFallback {
    public struct Action: Equatable, Sendable {
        public var copyToClipboard: Bool
        public var message: String
    }

    public static func action(secureFieldFocused: Bool) -> Action {
        if secureFieldFocused {
            // Never put what was said into a password flow, not even the clipboard.
            return Action(copyToClipboard: false, message: "A password field is focused, so Blabbit didn't type anything.")
        }
        return Action(copyToClipboard: true,
                      message: "Secure input is on (a password field or Secure Keyboard Entry elsewhere), so Blabbit didn't type. Your text replaced the clipboard: paste it with ⌘V.")
    }

    /// Insertion failed for another reason: keep the words rather than lose them.
    public static let failedMessagePrefix = "Blabbit couldn't type into this app, so your text replaced the clipboard: paste it with ⌘V."
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
    /// Blabbit can't tell whether the text went in.
    case unconfirmed
    /// The dictation failed (microphone, model, insertion).
    case failed

    public var symbolName: String {
        switch self {
        case .blocked: "lock.fill"
        case .unconfirmed: "exclamationmark.bubble"
        case .failed: "exclamationmark.triangle"
        }
    }
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
        "Blabbit couldn't confirm your text went in, so it replaced the clipboard. If it's missing, paste it with ⌘V."
    public static let clipboardUnreadableMessage =
        "Blabbit could not save your clipboard first, so the transcript was left on it. To keep your clipboard, allow Blabbit under System Settings → Privacy & Security → Paste from Other Apps."

    public static let partialTypingMessage =
        "Secure input turned on while Blabbit was typing, so it stopped partway. The full text replaced the clipboard."
    public static let partialTypingPasswordMessage =
        "A password field took focus while Blabbit was typing, so it stopped partway."

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
        case .copiedToClipboard, .handledByScript, .skipped:
            break
        case .blockedBySecureInput:
            let action = SecureInputFallback.action(secureFieldFocused: report.secureFieldFocused)
            plan.copyToClipboard = action.copyToClipboard
            plan.message = action.message
            if report.partiallyTyped {
                plan.message = action.copyToClipboard ? partialTypingMessage : partialTypingPasswordMessage
            }
            plan.cue = .blocked
        case .failed(let why):
            plan.copyToClipboard = true
            // Two plain sentences: what happened to the words, then why.
            let reason = why.hasSuffix(".") ? why : why + "."
            plan.failure = "\(SecureInputFallback.failedMessagePrefix) \(reason)"
        }
        return plan
    }
}
