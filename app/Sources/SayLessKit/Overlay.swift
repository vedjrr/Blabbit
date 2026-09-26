import AppKit
import Observation
import SwiftUI

/// What the overlay shows (G5: level meter, timer, processing state; G2: notices).
public enum OverlayPhase: Equatable, Sendable {
    case hidden
    case recording(startedAt: Date)
    case transcribing
    case notice(String, AttentionCue)
}

/// Settings → General → Overlay (PARITY F7).
public enum OverlayStyle: String, Codable, CaseIterable, Sendable {
    /// No pill while dictating (notices such as secure input still show).
    case none
    /// Level meter and timer.
    case minimal
    /// Meter and timer plus the words so far (PARITY A18).
    case live

    public static let defaultsKey = "overlay.style"

    public var title: String {
        switch self {
        case .none: "Nothing"
        case .minimal: "Orb and Timer"
        case .live: "Orb, Timer and Words"
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> OverlayStyle {
        // Live by default, like Handy on macOS (models too slow for it show the meter).
        defaults.string(forKey: defaultsKey).flatMap(OverlayStyle.init(rawValue:)) ?? .live
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// How much recent audio a live preview may transcribe for a model, so a
/// preview still running at release delays the text by at most `budget`
/// (transcribe.cpp's Parakeet one-shot path can't be interrupted mid-run).
public enum LivePreviewPolicy {
    public static let budgetSeconds = 0.12
    public static let maxWindowSeconds = 8.0
    /// Below this, a preview shows too few words to be worth it.
    public static let minWindowSeconds = 3.0
    public static let interval: TimeInterval = 0.8

    /// nil: the model is too slow for live text.
    public static func windowSeconds(measuredRTF rtf: Double) -> Double? {
        guard rtf > 0 else { return nil }
        let window = min(budgetSeconds / rtf, maxWindowSeconds)
        return window >= minWindowSeconds ? window : nil
    }

    /// The overlay line: text already transcribed plus the newest preview,
    /// kept to the last `limit` characters (the start scrolls away).
    public static func display(committed: String, preview: String?, truncatedAudio: Bool, limit: Int = 90) -> String {
        var parts: [String] = []
        if !committed.isEmpty { parts.append(committed) }
        if let preview, !preview.isEmpty { parts.append((truncatedAudio && committed.isEmpty ? "… " : "") + preview) }
        let text = parts.joined(separator: " ")
        guard text.count > limit else { return text }
        return "… " + String(text.suffix(limit)).drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
    }
}

/// Observable state behind the overlay view.
@MainActor @Observable
public final class OverlayModel {
    public var phase: OverlayPhase = .hidden
    /// Live Text style: the words so far (nil hides the line).
    public var liveText: String?
    /// Recent input levels (0…1), newest last, for the orb.
    public private(set) var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    public static let barCount = 16

    public init() {}

    /// Maps RMS (≈ 0.001 quiet room … 0.3 loud speech) onto 0…1 on a log scale
    /// so normal speech fills most of the meter.
    public nonisolated static func displayLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)          // -60 dB … -10 dB is the useful range
        return min(max((db + 60) / 50, 0), 1)
    }

    public func push(rms: Float) {
        levels.removeFirst()
        levels.append(Self.displayLevel(rms: rms))
    }

    /// The last few levels averaged, so the orb swells smoothly with the voice.
    public var voiceLevel: Float {
        let recent = levels.suffix(4)
        return recent.reduce(0, +) / Float(max(recent.count, 1))
    }

    public func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// A panel that can never become key or main, so showing it never takes focus
/// from the app the user is dictating into.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay panel. All calls on the main actor.
@MainActor
public final class OverlayController {
    public let model = OverlayModel()
    let panel: OverlayPanel
    private var meterTimer: Timer?
    private var hideTask: Task<Void, Never>?
    /// Returns the current input RMS (the recorder's level).
    private let levelProvider: () -> Float

    public static let size = NSSize(width: 176, height: 52)
    public static let liveSize = NSSize(width: 460, height: 80)
    /// Live Text style: the recording pill is wider and has a text line.
    public var live = false
    public static let noticeSize = NSSize(width: 420, height: 64)
    /// How long a notice stays up.
    public var noticeDuration: Duration = .seconds(4)

    public init(levelProvider: @escaping () -> Float) {
        self.levelProvider = levelProvider
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // ⌘H in Settings, or "Hide Others" in another app, hides Say Less; the
        // pill must still appear, or dictating looks like it does nothing.
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none // appear immediately, within a frame
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    public var isVisible: Bool { panel.isVisible }

    /// Lays out and draws every phase once, off screen and invisible, so the
    /// first real show is as fast as later ones (G5: within one frame).
    public func prewarm() {
        let alpha = panel.alphaValue
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        for phase in [OverlayPhase.recording(startedAt: Date()), .transcribing, .notice(" ", .blocked)] {
            model.phase = phase
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
            panel.display()
        }
        panel.orderOut(nil)
        model.phase = .hidden
        panel.alphaValue = alpha
    }

    /// Bottom-centre of the visible frame, clear of the Dock.
    public nonisolated static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(x: (visibleFrame.midX - size.width / 2).rounded(),
               y: (visibleFrame.minY + 72).rounded(),
               width: size.width, height: size.height)
    }

    /// The screen the user is working on: the one under the mouse pointer.
    private static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    public func show(_ phase: OverlayPhase) {
        hideTask?.cancel()
        model.phase = phase
        let size: NSSize
        switch phase {
        case .notice: size = Self.noticeSize
        case .recording where live: size = Self.liveSize
        default: size = Self.size
        }
        if let screen = Self.activeScreen {
            panel.setFrame(Self.frame(for: size, in: screen.visibleFrame), display: false)
        }
        switch phase {
        case .hidden:
            hide()
            return
        case .recording:
            model.resetLevels()
            model.liveText = nil
            startMeter()
        case .transcribing:
            stopMeter()
        case .notice:
            stopMeter()
            hideTask = Task { @MainActor [weak self] in
                guard let duration = self?.noticeDuration, (try? await Task.sleep(for: duration)) != nil else { return }
                self?.hide()
            }
        }
        // Never `makeKey`: the panel is shown without activating Say Less.
        panel.orderFrontRegardless()
        panel.display()
    }

    public func hide() {
        hideTask?.cancel()
        stopMeter()
        model.phase = .hidden
        panel.orderOut(nil)
    }

    private func startMeter() {
        stopMeter()
        // 30 Hz is smooth for a meter; the recorder updates its level every 20 ms.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.push(rms: self.levelProvider())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

/// The pill shown near the bottom of the screen.
struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let startedAt):
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    OrbView(level: model.voiceLevel, size: 44)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.elapsed(from: startedAt, to: context.date))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
                if let live = model.liveText {
                    Text(live.isEmpty ? " " : live)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.liveText.map { "Say Less is listening: \($0)" } ?? "Say Less is listening")
        case .transcribing:
            HStack(spacing: 10) {
                OrbView(speed: 0.45, size: 44)
                Text("Transcribing…").font(.callout)
            }
            .accessibilityElement(children: .combine)
        case .notice(let text, let cue):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: cue.symbolName)
                    .foregroundStyle(cue == .failed ? .red : cue == .blocked ? .orange : .yellow)
                Text(text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
