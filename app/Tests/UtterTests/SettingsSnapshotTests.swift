import AppKit
import SwiftUI
import Testing
@testable import UtterKit

/// Draws the real Settings and History windows offscreen with AppKit's own
/// renderer (`cacheDisplay`), which, unlike ImageRenderer, draws AppKit-backed
/// controls and needs no Screen Recording permission.
@MainActor @Suite(.serialized) struct SettingsSnapshotTests {
    init() { _ = NSApplication.shared }

    func snapshot(_ view: some View, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // let SwiftUI settle
        let content = try #require(window.contentView)
        content.wantsLayer = true
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        // Render the layer tree: SwiftUI draws into layers that `cacheDisplay` skips.
        let scale = 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        // Layers draw top-down; the bitmap context is bottom-up.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        content.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        if let dir = ProcessInfo.processInfo.environment["UTTER_SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    @Test func everySettingsTabRenders() throws {
        let controller = DictationController(models: ModelManager())
        let model = SettingsModel(controller: controller)
        for section in SettingsSection.allCases {
            model.section = section
            let rep = try snapshot(SettingsView(model: model, changeShortcut: { _ in }),
                                   size: SettingsWindowController.minSize, name: "settings_\(section.rawValue)")
            #expect(rep.pixelsWide >= 860 && rep.pixelsHigh >= 580)
        }
    }

    /// A Mode chosen from the menu shows up in Settings, and opening Settings
    /// doesn't write stale values back.
    @Test func settingsReloadWhatTheMenuChanged() {
        let controller = DictationController(models: ModelManager())
        let saved = controller.textSettings
        defer { controller.textSettings = saved } // restore the user's own setting
        let model = SettingsModel(controller: controller)
        let other: TextPipelineSettings.Mode = saved.mode == .code ? .exact : .code
        controller.textSettings.mode = other // what Menu → Mode does
        #expect(model.text.mode == saved.mode, "the window's copy is stale until reload")
        model.reload()
        #expect(model.text.mode == other)
        #expect(controller.textSettings.mode == other, "reload didn't write the stale value back")
    }

    @Test func historyRenders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utter-history-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        try store.add(HistoryEntry(createdAt: Date().addingTimeInterval(-300), durationMs: 4640, model: "parakeet-tdt-0.6b-v3", mode: "clean",
                                   raw: "testing udder 123 hold my code uses post gur SQL", final: "Testing Utter, 123, HoldMyCode uses PostgreSQL.", app: "com.apple.TextEdit"))
        let latest = try store.add(HistoryEntry(durationMs: 5050, model: "parakeet-tdt-0.6b-v3", mode: "clean",
                                                raw: "um we rewrote the settings screen in swift UI", final: "We rewrote the settings screen in SwiftUI.", app: "com.apple.Notes"))
        let controller = DictationController(models: ModelManager())
        let model = HistoryModel(controller: controller, store: store)
        await model.reload()?.value
        // A history-changed notification may start a newer reload: wait for it.
        for _ in 0..<50 where model.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        model.selection = latest.id
        let rep = try snapshot(HistoryView(model: model), size: NSSize(width: 646, height: 480), name: "history")
        #expect(model.entries.count == 2 && rep.pixelsWide >= 646)
    }

    @Test func menuPanelRenders() throws {
        let controller = DictationController(models: ModelManager())
        let panel = MenuPanelModel(controller: controller)
        panel.lastText = "We rewrote the settings screen in SwiftUI, and HoldMyCode uses PostgreSQL."
        panel.modelLoaded = true
        let rep = try snapshot(MenuPanelView(model: panel), size: NSSize(width: 320, height: 400), name: "menu_panel")
        #expect(rep.pixelsWide == 640)
        panel.state = .recording
        _ = try snapshot(MenuPanelView(model: panel), size: NSSize(width: 320, height: 400), name: "menu_panel_recording")
    }
}
