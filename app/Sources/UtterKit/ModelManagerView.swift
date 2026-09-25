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
    var addProblem: String?
}

public struct ModelManagerView: View {
    @Bindable var manager: ModelManager
    @Bindable var viewState: ModelManagerViewState

    public init(manager: ModelManager) {
        self.manager = manager
        self.viewState = ModelManagerViewState()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(manager.entries.filter { $0.variantOf == nil }, id: \.id) { entry in
                    let family = [entry] + manager.variants(of: entry.id)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(family, id: \.id) { member in
                            if member.variantOf != nil { Divider() }
                            ModelRow(entry: member, status: manager.status[member.id] ?? .notInstalled,
                                     isDefault: member.id == manager.defaultModelID,
                                     action: { handle($0, member) })
                        }
                    }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(family.contains { $0.id == manager.defaultModelID } ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                                          lineWidth: family.contains { $0.id == manager.defaultModelID } ? 1.5 : 1))
                }
                if let problem = viewState.addProblem {
                    Text(problem).font(.caption).foregroundStyle(.red).onTapGesture { viewState.addProblem = nil }
                }
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Run models on").foregroundStyle(.primary)
                Picker("Run models on", selection: $manager.computeDevice) {
                    Text("Automatic (GPU)").tag(ComputeDevice.auto)
                    Text("GPU (Metal)").tag(ComputeDevice.gpu)
                    Text("CPU").tag(ComputeDevice.cpu)
                }
                .labelsHidden().fixedSize()
                Text("CPU is about 3× slower; use it to keep the GPU free or if the GPU misbehaves.")
            }
            .padding(.bottom, 6)
            Text("Accuracy is the share of words right on Utter's spoken test clips; speed comes from the time to transcribe them. Both were measured on an Apple M4. Every model is faster on newer chips, but the order stays the same. The test set is 62 words, so a few points either way is noise: the smaller files are about as accurate as the standard ones.")
            HStack {
                Text("Installed: \(manager.installedEntries.count) of \(manager.entries.count)")
                Spacer()
                Button("Add Model File…") { addModelFile() }.buttonStyle(.link)
                Button("Show Models Folder") {
                    try? FileManager.default.createDirectory(at: ModelLocation.modelsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ModelLocation.modelsDirectory)
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    /// A GGUF file of your own (PARITY C7); it is copied into Models/Custom.
    private func addModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .gguf speech model made for transcribe.cpp. Files you put in the Custom folder are listed too."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewState.addProblem = manager.addModelFile(url)
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.name).font(entry.variantOf == nil ? .headline : .subheadline.weight(.semibold))
                    if !entry.quant.isEmpty { Text(entry.quant).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    if entry.recommended { Tag(text: "Recommended", tint: .accentColor) }
                    if isDefault { Tag(text: "In use", tint: .green) }
                }
                Text(entry.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(Self.size(entry.sizeBytes), systemImage: "internaldrive")
                    Label(entry.languages.count == 1 ? "English" : "\(entry.languages.count) languages", systemImage: "globe")
                        .help(Self.languageNames(entry.languages))
                    Button(entry.license) { action(.license) }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                statusLine
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                scores.frame(width: 210)
                controls
            }
        }
    }

    @ViewBuilder private var scores: some View {
        if entry.measuredRtf > 0 { measuredScores } else {
            Text("Not measured").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var measuredScores: some View {
        let score = ModelScores(entry)
        return VStack(spacing: 6) {
            ScoreBar(label: "Accuracy", value: score.accuracy, tint: .green)
                .help(String(format: "%.0f%% of words wrong on Utter's spoken test clips. Strict scoring: \"123\" for \"one two three\" and misspelt product names count as errors.", entry.measuredWer * 100))
            ScoreBar(label: "Speed", value: score.speed, tint: .blue)
                .help(String(format: "About %.2f s to transcribe 5 s of speech on an Apple M4.", Double(entry.measuredP50Ms) / 1000))
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
                    if !ModelManager.isCustom(entry.id) { Button("Verify") { action(.verify) }.buttonStyle(.link).font(.caption) }
                } else {
                    Button("Use This Model") { action(.setDefault) }
                    HStack {
                        if !ModelManager.isCustom(entry.id) { Button("Verify") { action(.verify) }.buttonStyle(.link).font(.caption) }
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
