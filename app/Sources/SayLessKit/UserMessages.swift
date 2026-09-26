import Foundation
import SayLessCore

/// Plain-English messages for app-level failures (BRIEF §16). Core errors
/// (model, inference, download) carry their own text from Rust (`CoreError.userMessage`).
public enum UserMessages {
    public static let microphoneDenied = "Say Less needs microphone access. Allow it in System Settings → Privacy & Security → Microphone."
    public static let microphoneDisconnected =
        "The microphone was disconnected while you were speaking and no other was available; only the part before that was transcribed."
    public static let noFocusedApp = "No app was ready for text, so your words are on the clipboard: paste them with ⌘V."
}

/// Every failure BRIEF §16 names, with the message a user sees for it. The
/// test enumerates this so a new failure can't ship without a readable message.
public enum Failure: String, CaseIterable, Sendable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case modelMissing
    case modelDownloadFailure
    case corruptedModel
    case insufficientMemory
    case unsupportedModel
    case inferenceFailure
    case microphoneDisconnected
    case hotkeyConflict
    case textInsertionFailure
    case unavailableFocusedApplication

    /// The message shown, from the same source the app uses at runtime.
    public var message: String {
        switch self {
        case .microphonePermissionDenied: UserMessages.microphoneDenied
        case .accessibilityPermissionDenied: HotkeyError.tapCreationFailed.userMessage
        case .modelMissing: coreMessage("ModelMissing")
        case .modelDownloadFailure: coreMessage("DownloadFailed")
        case .corruptedModel: coreMessage("ModelCorrupt")
        case .insufficientMemory: coreMessage("InsufficientMemory")
        case .unsupportedModel: coreMessage("ModelUnsupported")
        case .inferenceFailure: coreMessage("InferenceFailed")
        case .microphoneDisconnected: UserMessages.microphoneDisconnected
        case .hotkeyConflict: HotkeyError.shortcutInUse("⌥Space").userMessage
        case .textInsertionFailure: SecureInputFallback.failedMessagePrefix
        case .unavailableFocusedApplication: UserMessages.noFocusedApp
        }
    }

    private func coreMessage(_ kind: String) -> String {
        errorMessages().first { $0.kind == kind }?.message ?? ""
    }
}
