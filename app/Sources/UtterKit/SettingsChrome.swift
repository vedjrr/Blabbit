import AppKit
import SwiftUI
import UtterCore

/// The pages of the Utter window, in sidebar order.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, models, dictation, audio, insertion, language, processing, history, privacy, about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .dictation: "Dictation"
        case .audio: "Audio"
        case .insertion: "Text Insertion"
        case .language: "Language"
        case .processing: "AI Processing"
        case .history: "History"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Your shortcut, model and microphone."
        case .models: "Speech models run on this Mac. Scores are measured, not guessed."
        case .dictation: "How your words are cleaned up, and the words Utter should know."
        case .audio: "Microphone, recording and sounds."
        case .insertion: "How the text gets into the app you're typing in."
        case .language: "The language you speak."
        case .processing: "Optional AI rewriting for Professional and Custom modes."
        case .history: "Everything you've dictated, on this Mac only."
        case .privacy: "What Utter keeps, and for how long."
        case .about: "Version, updates and credits."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .models: "cpu.fill"
        case .dictation: "text.bubble.fill"
        case .audio: "mic.fill"
        case .insertion: "character.cursor.ibeam"
        case .language: "globe"
        case .processing: "sparkles"
        case .history: "clock.fill"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .models: .purple
        case .dictation: .orange
        case .audio: .red
        case .insertion: .blue
        case .language: .teal
        case .processing: .indigo
        case .history: .brown
        case .privacy: .blue
        case .about: .gray
        }
    }

    /// Sidebar groups, separated by a little space.
    static let groups: [[SettingsSection]] = [
        [.general, .models],
        [.dictation, .audio, .insertion, .language, .processing],
        [.history, .privacy],
        [.about],
    ]
}

/// A System Settings–style tinted square behind an SF Symbol.
struct SectionIcon: View {
    let section: SettingsSection
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 44) // clear of the traffic lights
                .padding(.bottom, 14)
            ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Spacer().frame(height: 12) }
                ForEach(group) { section in row(section) }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 214)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial())
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Utter").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// The model manager is observable (the controller isn't), so this stays current.
    private var statusText: String { model.controller.models.defaultEntry?.name ?? "No model yet" }
    private var statusColor: Color { model.controller.models.defaultEntry == nil ? .orange : .green }

    private func row(_ section: SettingsSection) -> some View {
        let selected = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 9) {
                SectionIcon(section: section)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PageHeader: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 12) {
            SectionIcon(section: section, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.system(size: 20, weight: .semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 4)
    }
}

/// A shortcut drawn as a key on a keyboard.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// One 0–100 score as a labelled bar.
struct ScoreBar: View {
    let label: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.gradient)
                        .frame(width: max(4, geometry.size.width * CGFloat(value) / 100))
                }
            }
            .frame(height: 6)
            Text("\(value)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 24, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) out of 100")
    }
}

struct AboutPage: View {
    @Bindable var model: SettingsModel

    static let website = URL(string: "https://github.com/vedjrr/Utter")!
    static let releases = URL(string: "https://github.com/vedjrr/Utter/releases")!
    static let handy = URL(string: "https://github.com/cjpais/Handy")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(short)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Utter").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                        Text("Private dictation for your Mac. Speech never leaves this computer.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Updates") {
                if let updates = model.updates {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks },
                                                                            set: { updates.automaticallyChecks = $0 }))
                    LabeledContent("Updates") { Button("Check Now") { updates.checkForUpdates() } }
                    Text("Updates come from Utter's GitHub releases and are checked against Utter's signing key before they're installed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Updates") { Button("Open Releases Page…") { NSWorkspace.shared.open(Self.releases) } }
                }
            }
            Section("Links") {
                LabeledContent("Source code") { Button("GitHub") { NSWorkspace.shared.open(Self.website) }.buttonStyle(.link) }
                LabeledContent("Log file") { Button("Show Log") { NSWorkspace.shared.open(Log.fileURL) }.buttonStyle(.link) }
                LabeledContent("Models folder") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: ModelLocation.modelsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ModelLocation.modelsDirectory)
                    }.buttonStyle(.link)
                }
            }
            Section {
                Text("MIT licence. Speech recognition by transcribe.cpp (ggml). Inspired by [Handy](https://github.com/cjpais/Handy) by CJ Pais; Utter is a separate, Mac-native app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
