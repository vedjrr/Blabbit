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
    /// Show only starred dictations.
    var starredOnly = false
    /// The entry being transcribed again.
    var retrying: HistoryEntry.ID?
    private var sound: NSSound?

    var shown: [HistoryEntry] { starredOnly ? entries.filter(\.saved) : entries }

    func toggleSaved(_ entry: HistoryEntry) {
        guard let id = entry.id, let store else { return }
        let saved = !entry.saved
        // Show it at once; the store's change notification reloads the rest.
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].saved = saved }
        Task.detached {
            do { try store.setSaved(id: id, saved) } catch {
                await MainActor.run { self.problem = "That dictation couldn't be starred." }
            }
        }
    }

    func retry(_ entry: HistoryEntry) {
        guard let id = entry.id, retrying == nil else { return }
        retrying = id
        problem = nil
        Task {
            let problem = await controller.retranscribe(historyID: id)
            retrying = nil
            self.problem = problem
            reload()
        }
    }

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

    private var store: HistoryStore? { explicitStore ?? controller.historyIfOpen }

    var enabled: Bool { controller.privacySettings.historyEnabled }

    /// Queries off the main thread; the newest request wins (typing in search).
    private var generation = 0

    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard let history = store else {
            problem = controller.privacySettings.historyEnabled ? "History is still opening. Try again in a moment." : nil
            return nil
        }
        generation += 1
        let mine = generation
        let query = self.query
        return Task {
            let result = await Task.detached { () -> [HistoryEntry]? in try? history.entries(matching: query) }.value
            guard mine == generation else { return }
            if let result {
                entries = result
                problem = nil
            } else {
                problem = "History couldn't be read."
            }
        }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
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
                Toggle(isOn: $model.starredOnly) { Label("Starred", systemImage: "star") }
                    .toggleStyle(.button)
                    .help("Show only starred dictations")
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
                List(model.shown, selection: $model.selection) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.final).lineLimit(2)
                            Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f s", entry.durationMs / 1000))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if entry.saved {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Starred")
                        }
                    }
                    .contextMenu {
                        Button("Copy") { model.copy(entry.final) }
                        Button(entry.saved ? "Unstar" : "Star") { model.toggleSaved(entry) }
                        if entry.audioFile != nil { Button("Transcribe Again") { model.retry(entry) } }
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
                        Button { model.toggleSaved(entry) } label: {
                            Label(entry.saved ? "Starred" : "Star", systemImage: entry.saved ? "star.fill" : "star")
                        }
                        .help("Starred dictations are kept whatever the history limit")
                        Button("Delete", role: .destructive) { model.delete(entry) }
                    }
                    if model.audioURL(entry) != nil {
                        HStack {
                            Button("Transcribe Again with \(model.controller.modelName)") { model.retry(entry) }
                                .disabled(model.retrying != nil)
                            if model.retrying == entry.id { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text(model.shown.isEmpty ? (model.starredOnly ? "No starred dictations." : "No dictations yet.") : "Select a dictation.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
