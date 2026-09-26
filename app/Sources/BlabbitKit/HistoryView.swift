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
    /// The entry just copied (its button shows a tick for a moment).
    var copied: HistoryEntry.ID?
    /// Entries showing the text as transcribed, before clean-up.
    var showingOriginal: Set<Int64> = []
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
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

    func copy(_ text: String, from entry: HistoryEntry? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let entry else { return }
        copied = entry.id
        copiedReset?.cancel()
        copiedReset = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            self?.copied = nil
        }
    }

    func toggleOriginal(_ entry: HistoryEntry) {
        guard let id = entry.id else { return }
        if showingOriginal.contains(id) { showingOriginal.remove(id) } else { showingOriginal.insert(id) }
    }

    /// Entries grouped by day, newest first: "Today", "Yesterday", then dates.
    var days: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(title: String, entries: [HistoryEntry])] = []
        for entry in shown {
            let title = calendar.isDateInToday(entry.createdAt) ? "Today"
                : calendar.isDateInYesterday(entry.createdAt) ? "Yesterday"
                : entry.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else { groups.append((title, [entry])) }
        }
        return groups
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

/// A feed of dictations, newest first, grouped by day (like Handy's).
struct HistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search dictations", text: $model.query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Toggle(isOn: $model.starredOnly) { Label("Starred", systemImage: model.starredOnly ? "star.fill" : "star") }
                    .toggleStyle(.button)
                    .help("Show only starred dictations")
                Menu {
                    Button("Delete All…", role: .destructive) { model.confirmDeleteAll = true }
                        .disabled(model.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 10)
            if !model.enabled {
                notice("History is off. Turn it on in Advanced → History and privacy.")
            }
            if let problem = model.problem {
                notice(problem, color: .red)
            }
            if model.shown.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(model.days, id: \.title) { day in
                            Text(day.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .padding(.leading, 2)
                            ForEach(day.entries) { entry in card(entry) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { model.reload() }
        .confirmationDialog("Delete every dictation in history?", isPresented: $model.confirmDeleteAll) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
        } message: { Text("Kept audio is deleted too. This can't be undone.") }
    }

    private func notice(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.callout).foregroundStyle(color).padding(.horizontal, 28).padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: model.starredOnly ? "star" : "waveform").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(model.starredOnly ? "No starred dictations." : model.query.isEmpty ? "No dictations yet." : "Nothing matches “\(model.query)”.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ entry: HistoryEntry) -> some View {
        let original = entry.id.map { model.showingOriginal.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(meta(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let url = model.audioURL(entry) {
                    iconButton(model.playing == entry.id ? "stop.fill" : "play.fill",
                               help: model.playing == entry.id ? "Stop" : "Play the recording") {
                        model.togglePlayback(entry, url: url)
                    }
                    if model.retrying == entry.id {
                        ProgressView().controlSize(.small).frame(width: 24)
                    } else {
                        iconButton("arrow.clockwise", help: "Transcribe again with \(model.controller.modelName)") { model.retry(entry) }
                            .disabled(model.retrying != nil)
                    }
                }
                iconButton(model.copied == entry.id ? "checkmark" : "doc.on.doc",
                           help: model.copied == entry.id ? "Copied" : "Copy") { model.copy(entry.final, from: entry) }
                iconButton(entry.saved ? "star.fill" : "star",
                           help: entry.saved ? "Unstar" : "Star (starred dictations are always kept)",
                           tint: entry.saved ? .yellow : nil) { model.toggleSaved(entry) }
                iconButton("trash", help: "Delete") { model.delete(entry) }
            }
            Text(original ? entry.raw : entry.final)
                .font(.body)
                .foregroundStyle(original ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if entry.raw != entry.final {
                Button(original ? "Show cleaned-up text" : "Show as transcribed") { model.toggleOriginal(entry) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contextMenu {
            Button("Copy") { model.copy(entry.final, from: entry) }
            if entry.raw != entry.final { Button("Copy as Transcribed") { model.copy(entry.raw) } }
            if let url = model.audioURL(entry) { Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            Divider()
            Button("Delete", role: .destructive) { model.delete(entry) }
        }
    }

    /// "10:42 · 4.6 s · TextEdit · Parakeet"
    private func meta(_ entry: HistoryEntry) -> String {
        var parts = [entry.createdAt.formatted(date: .omitted, time: .shortened),
                     String(format: "%.1f s", entry.durationMs / 1000)]
        if let app = entry.app { parts.append(SettingsView.appName(app)) }
        parts.append(model.controller.models.entry(entry.model)?.name ?? entry.model)
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
