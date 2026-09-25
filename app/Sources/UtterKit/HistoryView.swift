import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class HistoryModel {
    let controller: DictationController
    var query = "" { didSet { reload() } }
    var entries: [HistoryEntry] = []
    var selection: HistoryEntry.ID?
    var problem: String?
    var confirmDeleteAll = false
    var playing: HistoryEntry.ID?
    private var sound: NSSound?

    func togglePlayback(_ entry: HistoryEntry, url: URL) {
        sound?.stop()
        if playing == entry.id {
            playing = nil
            return
        }
        sound = NSSound(contentsOf: url, byReference: true)
        playing = sound?.play() == true ? entry.id : nil
    }

    /// The store to show (the controller's, or a given one).
    private let explicitStore: HistoryStore?

    init(controller: DictationController, store: HistoryStore? = nil) {
        self.controller = controller
        explicitStore = store
        // A new dictation shows up without reopening the window.
        observer = NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @ObservationIgnored private var observer: NSObjectProtocol?

    private var store: HistoryStore? { explicitStore ?? controller.history }

    var enabled: Bool { controller.privacySettings.historyEnabled }

    func reload() {
        guard let history = store else {
            problem = "History couldn't be opened."
            return
        }
        do {
            entries = try history.entries(matching: query)
            problem = nil
        } catch {
            problem = "History couldn't be read."
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func delete(_ entry: HistoryEntry) {
        guard let id = entry.id else { return }
        do { try store?.delete(id: id) } catch { problem = "That dictation couldn't be deleted." }
        reload()
    }

    /// Deletes everything off the main thread (VACUUM can take a moment).
    func deleteAll() {
        guard let store else { return }
        Task {
            let failed = await Task.detached { (try? store.deleteAll()) == nil }.value
            if failed { problem = "History couldn't be deleted completely." }
            reload()
        }
    }

    func audioURL(_ entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFile, let history = store else { return nil }
        return history.audioDirectory.appendingPathComponent(name)
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $model.query).textFieldStyle(.roundedBorder)
                Button("Delete All…", role: .destructive) { model.confirmDeleteAll = true }
                    .disabled(model.entries.isEmpty)
            }
            .padding(12)
            if !model.enabled {
                Text("History is off. Turn it on in Settings → Privacy.").font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 0) {
                List(model.entries, selection: $model.selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.final).lineLimit(2)
                        Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f s", entry.durationMs / 1000))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Copy") { model.copy(entry.final) }
                        Button("Delete", role: .destructive) { model.delete(entry) }
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                Divider()
                detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.reload() }
        .confirmationDialog("Delete every dictation in history?", isPresented: $model.confirmDeleteAll) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
        } message: { Text("Kept audio is deleted too. This can't be undone.") }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selection, let entry = model.entries.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("When", value: entry.createdAt.formatted(date: .complete, time: .standard))
                    LabeledContent("Length", value: String(format: "%.1f s", entry.durationMs / 1000))
                    LabeledContent("Model", value: entry.model)
                    LabeledContent("Mode", value: entry.mode.capitalized)
                    if let app = entry.app { LabeledContent("App", value: SettingsView.appName(app)) }
                    GroupBox("Final text") {
                        Text(entry.final).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if entry.raw != entry.final {
                        GroupBox("As transcribed") {
                            Text(entry.raw).textSelection(.enabled).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    HStack {
                        Button("Copy") { model.copy(entry.final) }
                        if entry.raw != entry.final { Button("Copy Original") { model.copy(entry.raw) } }
                        if let url = model.audioURL(entry) {
                            Button(model.playing == entry.id ? "Stop" : "Play") { model.togglePlayback(entry, url: url) }
                            Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { model.delete(entry) }
                    }
                }
                .padding(16)
            }
        } else {
            Text(model.entries.isEmpty ? "No dictations yet." : "Select a dictation.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
public final class HistoryWindowController {
    private let model: HistoryModel
    private var window: NSWindow?

    public init(controller: DictationController) {
        model = HistoryModel(controller: controller)
    }

    public func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Utter History"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(model: model))
            window.center()
            self.window = window
        }
        model.reload()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
