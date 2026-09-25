import AppKit
import SwiftUI
import UtterCore

/// Model Manager window: browse, download, pause/resume/cancel/retry, delete,
/// set default. Figures shown are measured on a real Mac, not marketing numbers.
/// Transient view state. (With Command Line Tools only, SwiftUI's `@State`
/// macro plugin is unavailable, so view state lives in an @Observable object.)
@MainActor @Observable
final class ModelManagerViewState {
    var licensePrompt: ModelEntry?
}

public struct ModelManagerView: View {
    @Bindable var manager: ModelManager
    @Bindable var viewState: ModelManagerViewState

    public init(manager: ModelManager) {
        self.manager = manager
        self.viewState = ModelManagerViewState()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                ForEach(manager.entries, id: \.id) { entry in
                    ModelRow(entry: entry, status: manager.status[entry.id] ?? .notInstalled,
                             isDefault: entry.id == manager.defaultModelID,
                             action: { handle($0, entry) })
                        .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { manager.refresh() }
        .alert(item: $viewState.licensePrompt) { entry in
            Alert(
                title: Text("\(entry.name) licence"),
                message: Text("\(entry.name) is distributed under the \(entry.license). Please review it before downloading."),
                primaryButton: .default(Text("Accept and Download")) {
                    manager.acceptLicense(entry.id)
                    manager.download(entry.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models").font(.title2.weight(.semibold))
            Text("Everything runs on this Mac. Accuracy and speed were measured on an Apple M4 with Utter's test clips; lower error is better.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Show Models Folder") {
                try? FileManager.default.createDirectory(at: ModelLocation.modelsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ModelLocation.modelsDirectory)
            }
            Spacer()
            Text("Installed: \(manager.installedEntries.count) of \(manager.entries.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func handle(_ action: ModelRow.Action, _ entry: ModelEntry) {
        switch action {
        case .download, .retry, .resume:
            if manager.needsLicenseAcceptance(entry.id) { viewState.licensePrompt = entry } else { manager.download(entry.id) }
        case .pause: manager.pause(entry.id)
        case .cancel: manager.cancel(entry.id)
        case .delete: manager.delete(entry.id)
        case .setDefault: manager.setDefault(entry.id)
        case .redownload:
            if manager.needsLicenseAcceptance(entry.id) { viewState.licensePrompt = entry } else { manager.redownload(entry.id) }
        case .verify: Task { await manager.verify(entry.id) }
        case .license:
            if let url = URL(string: entry.licenseUrl) { NSWorkspace.shared.open(url) }
        }
    }
}

extension ModelEntry: Identifiable {}

struct ModelRow: View {
    enum Action { case download, pause, resume, cancel, retry, delete, setDefault, redownload, license, verify }

    let entry: ModelEntry
    let status: ModelManager.Status
    let isDefault: Bool
    let action: (Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.headline)
                    if entry.recommended { Tag(text: "Recommended", tint: .accentColor) }
                    if isDefault { Tag(text: "In use", tint: .green) }
                }
                Text(entry.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(Self.size(entry.sizeBytes), systemImage: "internaldrive")
                    Label(entry.languages.count == 1 ? "English" : "\(entry.languages.count) languages", systemImage: "globe")
                        .help(Self.languageNames(entry.languages))
                    Label(String(format: "%.0f%% word errors", entry.measuredWer * 100), systemImage: "checkmark.seal")
                        .help("Word error rate on Utter's five spoken test clips. Strict scoring: \"123\" for \"one two three\" and misspelt product names count as errors.")
                    Label(String(format: "%.2fs per 5s of speech", Double(entry.measuredP50Ms) / 1000), systemImage: "bolt")
                    Button(entry.license) { action(.license) }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                statusLine
            }
            Spacer(minLength: 8)
            controls
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Downloading \(Self.size(done)) of \(Self.size(total))").font(.caption)
            }
            .frame(maxWidth: 320)
        case .verifying:
            ProgressView { Text("Verifying download…").font(.caption) }.frame(maxWidth: 320)
        case .partial(let bytes):
            Text("Paused at \(Self.size(bytes))").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .notInstalled, .installed:
            EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch status {
            case .notInstalled:
                Button("Download") { action(.download) }
            case .downloading:
                HStack {
                    Button("Pause") { action(.pause) }
                    Button("Cancel", role: .cancel) { action(.cancel) }
                }
            case .verifying:
                EmptyView()
            case .partial:
                HStack {
                    Button("Resume") { action(.resume) }
                    Button("Cancel", role: .cancel) { action(.cancel) }
                }
            case .failed:
                HStack {
                    Button("Retry") { action(.retry) }
                    Button("Re-download") { action(.redownload) }
                }
            case .installed:
                if isDefault {
                    Text("Default model").font(.caption).foregroundStyle(.secondary)
                    Button("Verify") { action(.verify) }.buttonStyle(.link).font(.caption)
                } else {
                    Button("Use This Model") { action(.setDefault) }
                    HStack {
                        Button("Verify") { action(.verify) }.buttonStyle(.link).font(.caption)
                        Button("Delete", role: .destructive) { action(.delete) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    /// Full language names for the tooltip (codes the system doesn't know are kept as is).
    static func languageNames(_ codes: [String]) -> String {
        codes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct Tag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Hosts the Model Manager in a normal window (the app itself is menu-bar only).
@MainActor
public final class ModelManagerWindowController {
    private var window: NSWindow?
    private let manager: ModelManager

    public init(manager: ModelManager) {
        self.manager = manager
    }

    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ModelManagerView(manager: manager))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Utter Models"
            window.setContentSize(NSSize(width: 720, height: 560))
            window.styleMask.insert([.resizable, .closable, .miniaturizable])
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        manager.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
