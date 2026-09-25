import AppKit
import Observation
import SwiftUI
import UtterCore

/// State behind the Settings window. Every change is written through to the
/// controller (which saves it), so there is no Save button.
@MainActor @Observable
public final class SettingsModel {
    let controller: DictationController

    var general: GeneralSettings { didSet { if !reloading { applyGeneral(oldValue) } } }
    var text: TextPipelineSettings { didSet { if !reloading { controller.textSettings = text } } }
    var insertion: InsertionSettings { didSet { if !reloading { controller.insertionSettings = insertion } } }
    var overrides: [String: [InsertionStrategy]] { didSet { if !reloading { controller.insertionOverrides = overrides } } }
    var processing: ProcessorSettings { didSet { if !reloading { controller.processorSettings = processing } } }
    var privacy: PrivacySettings { didSet { if !reloading { controller.privacySettings = privacy } } }
    var launchAtLogin = LaunchAtLogin.isEnabled
    var message: String?
    var newTerm = ""
    var apiKeyDraft = ""
    var hasAPIKey = false
    var historyCount: Int?
    var connectionResult: String?
    var confirmClear = false
    var selectedTab = "general"

    /// Set while copying the controller's values in, so nothing is written back.
    private var reloading = false

    /// Re-reads every setting from the controller: the menu (Mode, Model,
    /// Microphone…) may have changed them since the window was last open.
    func reload() {
        reloading = true
        defer { reloading = false }
        general = GeneralSettings.load()
        text = controller.textSettings
        insertion = controller.insertionSettings
        overrides = controller.insertionOverrides
        processing = controller.processorSettings
        privacy = controller.privacySettings
        launchAtLogin = LaunchAtLogin.isEnabled
        refreshAPIKeyState()
    }

    func refreshAPIKeyState() {
        Task {
            let has = await Task.detached { KeychainStore.anthropic.read() != nil }.value
            hasAPIKey = has
        }
    }

    /// Called when General settings that the menu bar controls change.
    var onGeneralChange: ((GeneralSettings) -> Void)?

    public init(controller: DictationController) {
        self.controller = controller
        general = GeneralSettings.load()
        text = controller.textSettings
        insertion = controller.insertionSettings
        overrides = controller.insertionOverrides
        processing = controller.processorSettings
        privacy = controller.privacySettings
    }

    private func applyGeneral(_ old: GeneralSettings) {
        general.save()
        if general.appearance != old.appearance { general.applyAppearance() }
        onGeneralChange?(general)
    }

    func setLaunchAtLogin(_ on: Bool) {
        message = LaunchAtLogin.set(on)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !text.vocabulary.contains(term) else { return }
        text.vocabulary.append(term)
        newTerm = ""
    }

    func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        apiKeyDraft = ""
        Task {
            let saved = await Task.detached { KeychainStore.anthropic.write(key) }.value
            hasAPIKey = saved
            message = saved ? "API key saved in your Keychain." : "The API key couldn't be saved in the Keychain."
        }
    }

    func removeAPIKey() {
        Task {
            _ = await Task.detached { KeychainStore.anthropic.delete() }.value
            hasAPIKey = false
        }
    }

    /// Sends one short request through the chosen processor (user-initiated).
    func testProcessor() {
        if privacy.localOnly && !processing.isLocal {
            connectionResult = "Local-only mode is on (Privacy), so Utter won't contact \(processing.provider == .anthropic ? "Anthropic" : "that address")."
            return
        }
        connectionResult = "Testing…"
        let settings = processing
        Task {
            guard let processor = await Task.detached(operation: { settings.makeProcessor() }).value else {
                connectionResult = settings.provider == .anthropic ? "Add an API key first." : "Choose a processor first."
                return
            }
            do {
                let out = try await processor.process("um so this is a test", instruction: TextPipeline.professionalInstruction, vocabulary: [])
                connectionResult = "Works: “\(out.prefix(60))”"
            } catch let error as TextProcessorError {
                connectionResult = error.userMessage
            } catch {
                connectionResult = "The test failed."
            }
        }
    }

    func refreshHistoryCount() {
        let controller = self.controller
        Task {
            historyCount = await Task.detached { try? controller.historyStoreForBackground()?.count() }.value
        }
    }

    func clearLocalData() {
        guard let history = controller.historyIfOpen else {
            message = "History isn't available, so there was nothing to delete."
            return
        }
        Task {
            let ok = await Task.detached { (try? history.deleteAll()) != nil }.value
            message = ok ? "History and kept audio were deleted." : "Local data couldn't be deleted completely."
            refreshHistoryCount()
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let openModelManager: () -> Void
    let changeShortcut: () -> Void

    var body: some View {
        TabView(selection: $model.selectedTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            dictation.tabItem { Label("Dictation", systemImage: "waveform") }.tag("dictation")
            models.tabItem { Label("Models", systemImage: "cpu") }.tag("models")
            audio.tabItem { Label("Audio", systemImage: "mic") }.tag("audio")
            insertion.tabItem { Label("Text Insertion", systemImage: "text.cursor") }.tag("insertion")
            language.tabItem { Label("Language", systemImage: "globe") }.tag("language")
            processing.tabItem { Label("Processing", systemImage: "sparkles") }.tag("processing")
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
        }
        .frame(width: 620, height: 520)
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message).font(.callout).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
                    .onTapGesture { model.message = nil }
            }
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Picker("Appearance", selection: $model.general.appearance) {
                ForEach(GeneralSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show the menu bar icon when idle", isOn: $model.general.showMenuBarIcon)
            Text("It always appears while you dictate. With the icon hidden, open Settings by launching Utter again.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open setup at launch when a permission is missing", isOn: $model.general.showSetupWhenNeeded)
            LabeledContent("Updates") {
                Button("Check for Updates…") { NSWorkspace.shared.open(Self.releasesURL) }
            }
            Text("Opens Utter's releases page. Automatic updates arrive with the signed release build.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build")
        }
        .formStyle(.grouped)
    }

    // MARK: Dictation

    private var dictation: some View {
        Form {
            Section("Shortcut") {
                Picker("Shortcut mode", selection: Binding(get: { model.controller.mode }, set: { model.controller.setMode($0) })) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Shortcut") {
                    HStack {
                        Text(model.controller.hotkey.shortcut.displayString).monospaced()
                        Button("Change…", action: changeShortcut)
                    }
                }
            }
            Section("Text") {
                Picker("Mode", selection: $model.text.mode) {
                    ForEach(TextPipelineSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(model.text.mode.summary).font(.caption).foregroundStyle(.secondary)
                Toggle("Remove filler words (um, uh)", isOn: $model.text.removeFillers)
                Toggle("Capitalize sentences", isOn: $model.text.capitalize)
                Toggle("Add a full stop at the end", isOn: $model.text.autoPunctuation)
                Toggle("“New line” / “new paragraph” start a new line", isOn: $model.text.spokenLineBreaks)
                if model.text.mode == .custom {
                    TextField("Instruction for Custom mode", text: $model.text.customInstruction, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            Section("Personal vocabulary") {
                Text("Names and terms Utter should spell your way. Close mishearings are corrected, and Whisper models are primed with them.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a word or phrase", text: $model.newTerm).onSubmit { model.addTerm() }
                    Button("Add") { model.addTerm() }.disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.text.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button(role: .destructive) { model.text.vocabulary.removeAll { $0 == term } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Models

    private var models: some View {
        Form {
            Picker("Default model", selection: Binding(get: { model.controller.models.defaultModelID },
                                                       set: { model.controller.models.setDefault($0) })) {
                ForEach(model.controller.models.installedEntries, id: \.id) { Text($0.name).tag($0.id) }
            }
            Section("Available models") {
                ForEach(model.controller.models.entries, id: \.id) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Text(Self.statusText(model.controller.models.status[entry.id])).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Storage") {
                HStack {
                    Text(ModelLocation.modelsDirectory.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: ModelLocation.modelsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ModelLocation.modelsDirectory)
                    }
                }
            }
            Button("Open Model Manager…", action: openModelManager)
        }
        .formStyle(.grouped)
    }

    // MARK: Audio

    private var audio: some View {
        Form {
            Picker("Input device", selection: Binding(get: { model.controller.preferredMicrophoneUID ?? "" },
                                                      set: { model.controller.selectMicrophone(uid: $0.isEmpty ? nil : $0) })) {
                Text("System Default").tag("")
                ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag($0.uid) }
            }
            LabeledContent("In use", value: model.controller.microphoneName ?? "—")
            Toggle("Keep the microphone ready (instant start)", isOn: Binding(get: { model.controller.keepMicrophoneReady },
                                                                             set: { model.controller.setKeepMicrophoneReady($0) }))
            Text("Recording starts instantly and includes the moment before you press the shortcut. macOS shows the microphone indicator the whole time, and a Bluetooth headset stays in call mode. Audio is never stored unless you keep audio in History.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Text insertion

    private var insertion: some View {
        Form {
            Picker("Insert text by", selection: $model.insertion.method) {
                Text("Typing into the app (recommended)").tag(InsertionSettings.Method.automatic)
                Text("Copying to the clipboard only").tag(InsertionSettings.Method.clipboardOnly)
                Text("Running a script").tag(InsertionSettings.Method.externalScript)
            }
            if model.insertion.method == .externalScript {
                TextField("Script path (receives the text on stdin)", text: Binding(
                    get: { model.insertion.externalScriptPath ?? "" },
                    set: { model.insertion.externalScriptPath = $0.isEmpty ? nil : $0 }))
            }
            Toggle("Restore my clipboard after pasting", isOn: $model.insertion.restoreClipboard)
            Toggle("Also leave the text on the clipboard", isOn: $model.insertion.copyToClipboard)
            Picker("Line breaks", selection: $model.insertion.newlines) {
                Text("Keep").tag(InsertionSettings.Newlines.keep)
                Text("Replace with spaces (chat apps)").tag(InsertionSettings.Newlines.spaces)
            }
            Toggle("Add a space after the text", isOn: $model.insertion.appendTrailingSpace)
            Picker("Then press", selection: $model.insertion.autoSubmit) {
                Text("Nothing").tag(InsertionSettings.AutoSubmit.off)
                Text("Return").tag(InsertionSettings.AutoSubmit.enter)
                Text("⌃Return").tag(InsertionSettings.AutoSubmit.controlEnter)
                Text("⌘Return").tag(InsertionSettings.AutoSubmit.commandEnter)
            }
            Section("Per-app method") {
                Text("Accessibility is used first in native apps, paste in terminals, browsers and Electron apps. Override an app here.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.overrides.keys.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(bundleID)).lineLimit(1)
                        Spacer()
                        Picker("", selection: Binding(get: { model.overrides[bundleID]?.first ?? .paste },
                                                      set: { model.overrides[bundleID] = Self.chain(startingWith: $0) })) {
                            ForEach(InsertionStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                        Button(role: .destructive) { model.overrides[bundleID] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addOverride() }
            }
        }
        .formStyle(.grouped)
    }

    /// The override chain for a chosen first method (later methods are fallbacks;
    /// Accessibility never follows paste, which could insert twice).
    static func chain(startingWith first: InsertionStrategy) -> [InsertionStrategy] {
        switch first {
        case .accessibility: [.accessibility, .paste, .typing]
        case .paste: [.paste, .typing]
        case .typing: [.typing]
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addOverride() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.overrides[id] = [.paste, .typing]
    }

    // MARK: Language

    private var language: some View {
        Form {
            Picker("Language", selection: Binding(get: { model.text.language ?? "" }, set: { model.text.language = $0.isEmpty ? nil : $0 })) {
                Text("Detect automatically").tag("")
                ForEach(Self.languages(for: model.controller.loadedModelEntry ?? model.controller.models.defaultEntry), id: \.self) { code in
                    Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                }
            }
            Text("Choosing your language can help short dictations. The list shows what the current model (\(model.controller.modelName)) supports.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Translate to English (Whisper models)", isOn: $model.text.translateToEnglish)
            Text("Speak any language Whisper knows and get English text. Other models ignore this.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    static func statusText(_ status: ModelManager.Status?) -> String {
        switch status {
        case .installed: "Installed"
        case .downloading(let done, let total): "Downloading \(Int(Double(done) / Double(max(total, 1)) * 100)) %"
        case .partial: "Paused"
        case .verifying: "Verifying…"
        case .failed: "Needs attention"
        case .notInstalled, nil: "Not installed"
        }
    }

    static let releasesURL = URL(string: "https://github.com/vedjrr/Utter/releases")!

    static func languages(for entry: ModelEntry?) -> [String] {
        (entry?.languages ?? ["en"]).sorted {
            (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1)
        }
    }

    // MARK: Processing

    private var processing: some View {
        Form {
            Text("Professional and Custom modes can use an AI processor after Utter's own clean-up. Exact, Clean and Code never do. If the processor fails, the cleaned-up text is used.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Processor", selection: $model.processing.provider) {
                ForEach(ProcessorSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch model.processing.provider {
            case .none:
                EmptyView()
            case .ollama:
                TextField("Ollama address", text: $model.processing.ollamaURL)
                TextField("Model", text: $model.processing.ollamaModel)
                if model.privacy.localOnly && !model.processing.isLocal {
                    Text("This address isn't on this Mac. Local-only mode is on (Privacy), so it won't be used.")
                        .font(.callout).foregroundStyle(.orange)
                }
            case .anthropic:
                if model.privacy.localOnly {
                    Text("Local-only mode is on (Privacy), so the cloud processor won't be used.")
                        .font(.callout).foregroundStyle(.orange)
                }
                TextField("Model", text: $model.processing.anthropicModel)
                if model.hasAPIKey {
                    LabeledContent("API key") {
                        HStack { Text("Saved in Keychain"); Button("Remove") { model.removeAPIKey() } }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $model.apiKeyDraft)
                        Button("Save") { model.saveAPIKey() }.disabled(model.apiKeyDraft.isEmpty)
                    }
                }
                Text("Your text is sent to Anthropic only when you dictate in Professional or Custom mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.processing.provider != .none {
                HStack {
                    Button("Test") { model.testProcessor() }
                    if let result = model.connectionResult { Text(result).font(.caption).lineLimit(2) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Privacy

    private var privacy: some View {
        Form {
            Toggle("Local-only mode (never use cloud processing)", isOn: $model.privacy.localOnly)
            Toggle("Keep a history of dictations", isOn: $model.privacy.historyEnabled)
            Toggle("Keep the audio of each dictation", isOn: $model.privacy.keepAudio)
                .disabled(!model.privacy.historyEnabled)
            Text("Everything stays on this Mac, in ~/Library/Application Support/Utter.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Saved dictations", value: model.historyCount.map(String.init) ?? "—")
            Button("Clear Local Data…", role: .destructive) { model.confirmClear = true }
                .confirmationDialog("Delete all history and kept audio?", isPresented: $model.confirmClear) {
                    Button("Delete", role: .destructive) { model.clearLocalData() }
                } message: {
                    Text("This can't be undone. Models and settings are kept.")
                }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHistoryCount() }
    }
}

/// Hosts Settings in a normal window (⌘, from the menu).
@MainActor
public final class SettingsWindowController {
    public let model: SettingsModel
    private var window: NSWindow?
    private let openModelManager: () -> Void
    private let changeShortcut: () -> Void

    public init(controller: DictationController, openModelManager: @escaping () -> Void, changeShortcut: @escaping () -> Void) {
        model = SettingsModel(controller: controller)
        self.openModelManager = openModelManager
        self.changeShortcut = changeShortcut
    }

    public func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Utter Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, openModelManager: openModelManager,
                                                                      changeShortcut: changeShortcut))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
