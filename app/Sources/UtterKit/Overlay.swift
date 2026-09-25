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

/// Observable state behind the overlay view.
@MainActor @Observable
public final class OverlayModel {
    public var phase: OverlayPhase = .hidden
    /// Recent input levels (0…1), newest last, for the meter.
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

    public static let size = NSSize(width: 240, height: 48)
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
        if case .notice = phase { size = Self.noticeSize } else { size = Self.size }
        if let screen = Self.activeScreen {
            panel.setFrame(Self.frame(for: size, in: screen.visibleFrame), display: false)
        }
        switch phase {
        case .hidden:
            hide()
            return
        case .recording:
            model.resetLevels()
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
        // Never `makeKey`: the panel is shown without activating Utter.
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
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let startedAt):
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 10, height: 10)
                LevelMeter(levels: model.levels)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Utter is listening")
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
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

private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4 + CGFloat(level) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}
