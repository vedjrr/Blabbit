import AppKit
import SwiftUI
import Testing
@testable import SayLessKit

@MainActor @Suite(.serialized) struct OverlayTests {
    init() { _ = NSApplication.shared }

    @Test func panelCanNeverTakeFocus() {
        let overlay = OverlayController(levelProvider: { 0 })
        let panel = overlay.panel
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.animationBehavior == .none)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test func showingDoesNotActivateOrTakeKey() {
        let overlay = OverlayController(levelProvider: { 0.05 })
        let wasActive = NSApp.isActive
        let keyBefore = NSApp.keyWindow
        overlay.show(.recording(startedAt: Date()))
        #expect(overlay.isVisible)
        #expect(!overlay.panel.isKeyWindow)
        #expect(NSApp.keyWindow === keyBefore)
        #expect(NSApp.isActive == wasActive)
        overlay.show(.transcribing)
        #expect(overlay.model.phase == .transcribing && !overlay.panel.isKeyWindow)
        overlay.hide()
        #expect(!overlay.isVisible && overlay.model.phase == .hidden)
    }

    @Test func showsWithinOneFrame() {
        let overlay = OverlayController(levelProvider: { 0 })
        overlay.show(.transcribing) // first show builds the view hierarchy
        overlay.hide()
        var worst = 0.0
        for _ in 0..<20 {
            let start = MonoClock.nowNs()
            overlay.show(.recording(startedAt: Date()))
            worst = max(worst, MonoClock.ms(from: start, to: MonoClock.nowNs()))
            overlay.hide()
        }
        // One frame at 60 Hz. (The app logs the real key-down → overlay time.)
        #expect(worst < 16.7, "worst show took \(worst) ms")
    }

    /// The first show of a session, after the pre-warm `launch()` does. This is
    /// what the first key-down pays (building the panel lazily cost 25–36 ms).
    @Test func firstShowAfterPrewarmIsWithinOneFrame() {
        var worst = 0.0
        for _ in 0..<5 {
            let overlay = OverlayController(levelProvider: { 0 })
            overlay.prewarm()
            #expect(!overlay.isVisible && overlay.panel.alphaValue == 1)
            let start = MonoClock.nowNs()
            overlay.show(.recording(startedAt: Date()))
            worst = max(worst, MonoClock.ms(from: start, to: MonoClock.nowNs()))
            overlay.hide()
        }
        #expect(worst < 16.7, "first show after prewarm took \(worst) ms")
    }

    @Test func noticeHidesItself() async throws {
        let overlay = OverlayController(levelProvider: { 0 })
        overlay.noticeDuration = .milliseconds(100)
        overlay.show(.notice("Secure input is on.", .blocked))
        #expect(overlay.isVisible)
        #expect(overlay.panel.frame.size == OverlayController.noticeSize)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!overlay.isVisible)
    }

    @Test func meterFollowsTheRecorderLevel() async throws {
        nonisolated(unsafe) var rms: Float = 0.0
        let overlay = OverlayController(levelProvider: { rms })
        overlay.show(.recording(startedAt: Date()))
        rms = 0.2 // loud speech
        try await Task.sleep(for: .milliseconds(200))
        #expect((overlay.model.levels.last ?? 0) > 0.8)
        overlay.hide()
    }

    @Test func geometryAndFormatting() {
        let visible = NSRect(x: 0, y: 80, width: 1440, height: 800)
        let frame = OverlayController.frame(for: OverlayController.size, in: visible)
        #expect(frame.midX == visible.midX && frame.minY == 152)
        #expect(OverlayModel.displayLevel(rms: 0) == 0)
        #expect(OverlayModel.displayLevel(rms: 0.001) == 0)     // -60 dB: silence
        #expect(OverlayModel.displayLevel(rms: 1) == 1)
        #expect(OverlayModel.displayLevel(rms: 0.01) < OverlayModel.displayLevel(rms: 0.1))
        let start = Date(timeIntervalSince1970: 0)
        #expect(OverlayView.elapsed(from: start, to: start.addingTimeInterval(75)) == "1:15")
    }

    /// Hiding Say Less (⌘H, Hide Others) must not hide the pill (human-found, 2026-09-26).
    @Test func pillSurvivesTheAppBeingHidden() {
        let overlay = OverlayController(levelProvider: { 0 })
        #expect(overlay.panel.canHide == false)
    }

    /// Offscreen renders of each phase (kept as evidence with SAYLESS_SNAPSHOT_DIR).
    @Test func rendersEveryPhase() throws {
        let model = OverlayModel()
        for (i, rms) in [0.002, 0.01, 0.05, 0.2, 0.1, 0.03].enumerated() where i < OverlayModel.barCount { model.push(rms: Float(rms)) }
        let phases: [(String, OverlayPhase, NSSize)] = [
            ("recording", .recording(startedAt: Date().addingTimeInterval(-7)), OverlayController.size),
            ("transcribing", .transcribing, OverlayController.size),
            ("notice_blocked", .notice(SecureInputFallback.action(secureFieldFocused: false).message, .blocked), OverlayController.noticeSize),
            ("notice_unconfirmed", .notice(InsertionOutcome.unconfirmedMessage, .unconfirmed), OverlayController.noticeSize),
            ("recording_live", .recording(startedAt: Date().addingTimeInterval(-4)), OverlayController.liveSize),
        ]
        for (name, phase, size) in phases {
            model.phase = phase
            model.liveText = name == "recording_live" ? "Testing Say Less, one two three. HoldMyCode uses" : nil
            let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: size.width, height: size.height).padding(8).background(Color.gray))
            renderer.scale = 2
            let image = try #require(renderer.cgImage, "\(name) did not render")
            if let dir = ProcessInfo.processInfo.environment["SAYLESS_SNAPSHOT_DIR"] {
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay_\(name).png"))
            }
        }
    }
}

@MainActor @Suite struct PermissionsOnboardingTests {
    @Test func rowsForEveryState() {
        let micAsk = PermissionRow.microphone(.notDetermined)
        #expect(!micAsk.granted && micAsk.action == .requestMicrophone)
        let micDenied = PermissionRow.microphone(.denied)
        #expect(micDenied.action == .openSettings(Permissions.microphoneSettingsURL))
        #expect(micDenied.status.contains("System Settings"))
        #expect(PermissionRow.microphone(.granted).action == nil)

        #expect(PermissionRow.accessibility(false, asked: false).action == .requestAccessibility)
        // macOS prompts only once; afterwards the deep link is the only way.
        #expect(PermissionRow.accessibility(false, asked: true).action == .openSettings(Permissions.accessibilitySettingsURL))
        #expect(PermissionRow.accessibility(true, asked: true).granted)
        #expect(Permissions.accessibilitySettingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(Permissions.microphoneSettingsURL.absoluteString.hasSuffix("Privacy_Microphone"))
    }

    @Test func liveRecheckReportsGrants() async throws {
        nonisolated(unsafe) var current = PermissionSnapshot(microphone: .notDetermined, accessibility: false)
        let model = PermissionsModel(probe: { current })
        var seen: [PermissionSnapshot] = []
        model.onChange = { seen.append($0) }
        model.startPolling(interval: 0.05)
        defer { model.stopPolling() }
        #expect(!model.snapshot.allGranted)
        current.accessibility = true // the user flips the switch in System Settings
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.snapshot.accessibility && model.rows[1].granted)
        current.microphone = .granted
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.snapshot.allGranted)
        #expect(seen.count == 2, "one change event per grant, none while nothing changes")
    }

    @Test func rendersTheSetupWindow() throws {
        let model = PermissionsModel(probe: { PermissionSnapshot(microphone: .granted, accessibility: false) })
        let renderer = ImageRenderer(content: PermissionsView(model: model, onDone: {}).background(Color.white))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["SAYLESS_SNAPSHOT_DIR"] {
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("permissions_setup.png"))
        }
    }
}

/// Overlay styles and live text (PARITY A18, F7).
@Suite struct LivePreviewPolicyTests {
    @Test func windowFollowsTheModelsMeasuredSpeed() {
        // Parakeet V3 (RTF 0.0178): 6.7 s of audio ≈ 120 ms per preview.
        let parakeet = LivePreviewPolicy.windowSeconds(measuredRTF: 0.0178)
        #expect(parakeet != nil && abs(parakeet! - 6.74) < 0.1)
        #expect(LivePreviewPolicy.windowSeconds(measuredRTF: 0.013) == LivePreviewPolicy.maxWindowSeconds) // SenseVoice, capped
        #expect(LivePreviewPolicy.windowSeconds(measuredRTF: 0.0848) == nil)  // Whisper Small: too slow
        #expect(LivePreviewPolicy.windowSeconds(measuredRTF: 0) == nil)
        // The budget bounds the extra wait at release.
        if let w = parakeet { #expect(w * 0.0178 <= LivePreviewPolicy.budgetSeconds + 1e-9) }
    }

    @Test func displayJoinsCommittedTextAndKeepsTheEnd() {
        #expect(LivePreviewPolicy.display(committed: "", preview: "hello there", truncatedAudio: false) == "hello there")
        #expect(LivePreviewPolicy.display(committed: "First part.", preview: "and more", truncatedAudio: true) == "First part. and more")
        #expect(LivePreviewPolicy.display(committed: "", preview: "the tail", truncatedAudio: true) == "… the tail")
        let long = String(repeating: "word ", count: 60) + "end"
        let shown = LivePreviewPolicy.display(committed: "", preview: long, truncatedAudio: false, limit: 40)
        #expect(shown.hasPrefix("… ") && shown.hasSuffix("end") && shown.count <= 43)
        #expect(!shown.dropFirst(2).hasPrefix("ord"), "cut at a word boundary: \(shown)")
    }

    @Test func styleDefaultsToLiveAndPersists() throws {
        let suite = "dev.sayless.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(OverlayStyle.load(from: defaults) == .live)
        OverlayStyle.minimal.save(to: defaults)
        #expect(OverlayStyle.load(from: defaults) == .minimal)
    }

    @MainActor @Test func liveTextShowsInAWiderPill() throws {
        let overlay = OverlayController(levelProvider: { 0.05 })
        overlay.live = true
        overlay.show(.recording(startedAt: Date()))
        #expect(overlay.model.liveText == nil)
        #expect(overlay.panel.frame.size == OverlayController.liveSize)
        overlay.model.liveText = "Testing Say Less one two three"
        overlay.panel.contentView?.layoutSubtreeIfNeeded()
        overlay.hide()
        overlay.live = false
        overlay.show(.recording(startedAt: Date()))
        #expect(overlay.panel.frame.size == OverlayController.size)
        overlay.hide()
    }
}
