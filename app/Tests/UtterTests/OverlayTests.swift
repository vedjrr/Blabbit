import AppKit
import SwiftUI
import Testing
@testable import UtterKit

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

    /// Offscreen renders of each phase (kept as evidence with UTTER_SNAPSHOT_DIR).
    @Test func rendersEveryPhase() throws {
        let model = OverlayModel()
        for (i, rms) in [0.002, 0.01, 0.05, 0.2, 0.1, 0.03].enumerated() where i < OverlayModel.barCount { model.push(rms: Float(rms)) }
        let phases: [(String, OverlayPhase, NSSize)] = [
            ("recording", .recording(startedAt: Date().addingTimeInterval(-7)), OverlayController.size),
            ("transcribing", .transcribing, OverlayController.size),
            ("notice_blocked", .notice(SecureInputFallback.action(secureFieldFocused: false).message, .blocked), OverlayController.noticeSize),
            ("notice_unconfirmed", .notice(InsertionOutcome.unconfirmedMessage, .unconfirmed), OverlayController.noticeSize),
        ]
        for (name, phase, size) in phases {
            model.phase = phase
            let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: size.width, height: size.height).padding(8).background(Color.gray))
            renderer.scale = 2
            let image = try #require(renderer.cgImage, "\(name) did not render")
            if let dir = ProcessInfo.processInfo.environment["UTTER_SNAPSHOT_DIR"] {
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay_\(name).png"))
            }
        }
    }
}
