import Foundation

/// Control from outside the app (PARITY F14): Handy's CLI flags, forwarded to
/// the running Utter, and `utter://` URLs for Shortcuts, Raycast or a script.
///
///     /Applications/Utter.app/Contents/MacOS/Utter --toggle-transcription
///     open -g utter://toggle
public enum RemoteCommand: String, CaseIterable, Sendable {
    case toggle
    case toggleProcess = "toggle-ai"
    case start
    case stop
    case cancel
    case settings

    /// Handy's flag names, plus our own for start/stop/settings.
    var flag: String {
        switch self {
        case .toggle: "--toggle-transcription"
        case .toggleProcess: "--toggle-post-process"
        case .start: "--start-transcription"
        case .stop: "--stop-transcription"
        case .cancel: "--cancel"
        case .settings: "--settings"
        }
    }

    public init?(arguments: [String]) {
        guard let match = Self.allCases.first(where: { arguments.contains($0.flag) }) else { return nil }
        self = match
    }

    /// `utter://toggle`, `utter://toggle-ai`, `utter://start`, `utter://stop`,
    /// `utter://cancel`, `utter://settings`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "utter", let host = url.host?.lowercased(), let command = Self(rawValue: host) else { return nil }
        self = command
    }
}

/// Launch options (Handy's `--start-hidden`, `--no-tray`, `--debug`).
public struct LaunchOptions: Sendable {
    /// No setup or model window at launch.
    public var startHidden: Bool
    /// No menu bar icon this session (it still shows while dictating).
    public var noTray: Bool
    public var debug: Bool

    public init(arguments: [String]) {
        startHidden = arguments.contains("--start-hidden")
        noTray = arguments.contains("--no-tray")
        debug = arguments.contains("--debug")
    }
}

extension DictationController {
    public func perform(_ command: RemoteCommand) {
        Log.info("remote command \(command.rawValue) state=\(state)")
        let now = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0, source: .menu,
                            binding: command == .toggleProcess ? .process : .dictate)
        switch command {
        case .toggle, .toggleProcess:
            if state == .recording { remoteRelease(now) } else { remotePress(now) }
        case .start:
            if state != .recording { remotePress(now) }
        case .stop:
            if state == .recording { remoteRelease(now) }
        case .cancel:
            cancelDictation(reason: "remote")
        case .settings:
            break // the status item opens the window
        }
    }
}
