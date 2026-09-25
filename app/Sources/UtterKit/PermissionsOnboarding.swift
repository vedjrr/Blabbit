import AppKit
import AVFoundation
import Observation
import SwiftUI

/// The two permissions Utter needs, as the onboarding window shows them.
public struct PermissionSnapshot: Equatable, Sendable {
    public enum Mic: Equatable, Sendable { case granted, notDetermined, denied }
    public var microphone: Mic
    public var accessibility: Bool

    public init(microphone: Mic, accessibility: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    public var allGranted: Bool { microphone == .granted && accessibility }

    public static func current() -> PermissionSnapshot {
        let mic: Mic
        switch Permissions.microphoneStatus {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
        return PermissionSnapshot(microphone: mic, accessibility: Permissions.accessibilityGranted)
    }
}

/// One row of the onboarding window (pure, so every state is tested).
public struct PermissionRow: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Ask macOS (shows the system prompt).
        case requestMicrophone
        case requestAccessibility
        /// Open the matching System Settings pane.
        case openSettings(URL)
    }

    public var title: String
    public var why: String
    public var granted: Bool
    public var status: String
    public var buttonTitle: String?
    public var action: Action?

    public static func microphone(_ state: PermissionSnapshot.Mic) -> PermissionRow {
        let why = "To hear you while you hold the shortcut. Audio stays on this Mac."
        switch state {
        case .granted:
            return PermissionRow(title: "Microphone", why: why, granted: true, status: "Allowed", buttonTitle: nil, action: nil)
        case .notDetermined:
            return PermissionRow(title: "Microphone", why: why, granted: false, status: "Not asked yet",
                                 buttonTitle: "Allow Microphone…", action: .requestMicrophone)
        case .denied:
            return PermissionRow(title: "Microphone", why: why, granted: false,
                                 status: "Turned off. Turn Utter on in System Settings → Privacy & Security → Microphone.",
                                 buttonTitle: "Open Microphone Settings", action: .openSettings(Permissions.microphoneSettingsURL))
        }
    }

    public static func accessibility(_ granted: Bool, asked: Bool) -> PermissionRow {
        let why = "To see the shortcut in every app and to put the text at your cursor."
        if granted {
            return PermissionRow(title: "Accessibility", why: why, granted: true, status: "Allowed", buttonTitle: nil, action: nil)
        }
        // macOS shows its prompt only once; after that, only Settings can grant it.
        return asked
            ? PermissionRow(title: "Accessibility", why: why, granted: false,
                            status: "Turn Utter on in System Settings → Privacy & Security → Accessibility. If Utter isn't listed, add it with +.",
                            buttonTitle: "Open Accessibility Settings", action: .openSettings(Permissions.accessibilitySettingsURL))
            : PermissionRow(title: "Accessibility", why: why, granted: false, status: "Not allowed yet",
                            buttonTitle: "Allow Accessibility…", action: .requestAccessibility)
    }
}

/// Polls the permission state while the window is open (macOS sends no
/// notification when the user flips a switch in System Settings).
@MainActor @Observable
public final class PermissionsModel {
    public private(set) var snapshot: PermissionSnapshot
    public private(set) var askedAccessibility = false
    /// Called when a permission becomes granted (the controller starts the
    /// shortcut or the microphone without a relaunch).
    public var onChange: ((PermissionSnapshot) -> Void)?
    /// The dictation shortcut as shown to the user (e.g. "⌥Space").
    public var shortcutDisplay = "⌥Space"

    private let probe: () -> PermissionSnapshot
    private var timer: Timer?

    public init(probe: @escaping () -> PermissionSnapshot = PermissionSnapshot.current) {
        self.probe = probe
        snapshot = probe()
    }

    public var rows: [PermissionRow] {
        [.microphone(snapshot.microphone), .accessibility(snapshot.accessibility, asked: askedAccessibility)]
    }

    public func recheck() {
        let now = probe()
        guard now != snapshot else { return }
        snapshot = now
        Log.info("permissions changed microphone=\(now.microphone) accessibility=\(now.accessibility)")
        onChange?(now)
    }

    public func startPolling(interval: TimeInterval = 1) {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func perform(_ action: PermissionRow.Action) {
        switch action {
        case .requestMicrophone:
            Task { @MainActor in
                _ = await Permissions.requestMicrophone()
                recheck()
            }
        case .requestAccessibility:
            askedAccessibility = true
            Permissions.requestAccessibility()
        case .openSettings(let url):
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsView: View {
    let model: PermissionsModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Utter").font(.title2.weight(.semibold))
                Text("Utter needs two permissions. Everything runs on this Mac; nothing is sent anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.rows, id: \.title) { row in
                PermissionRowView(row: row) { if let action = row.action { model.perform(action) } }
            }
            HStack {
                Text(model.snapshot.allGranted ? "All set. Hold \(model.shortcutDisplay) in any app and speak." : "This window updates by itself when you change a setting.")
                    .font(.callout)
                    .foregroundStyle(model.snapshot.allGranted ? .green : .secondary)
                Spacer()
                Button(model.snapshot.allGranted ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct PermissionRowView: View {
    let row: PermissionRow
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(row.granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(row.why).font(.callout).foregroundStyle(.secondary)
                Text(row.status).font(.caption).foregroundStyle(row.granted ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let title = row.buttonTitle {
                Button(title, action: perform)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Hosts the onboarding in a normal window (the app itself is menu-bar only).
@MainActor
public final class PermissionsWindowController {
    public let model: PermissionsModel
    private var window: NSWindow?

    public init(model: PermissionsModel? = nil) {
        self.model = model ?? PermissionsModel()
    }

    public func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Utter Setup"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionsView(model: model) { [weak self] in self?.close() })
            window.center()
            self.window = window
            // The title-bar close button must stop the 1 s polling too.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.stopPolling() }
            }
        }
        model.recheck()
        model.startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        model.stopPolling()
        window?.orderOut(nil)
    }
}
