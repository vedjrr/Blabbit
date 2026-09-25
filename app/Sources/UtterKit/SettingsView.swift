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
    var sounds: SoundSettings { didSet { if !reloading { controller.soundSettings = sounds } } }
    var capture: CaptureSettings { didSet { if !reloading { controller.captureSettings = capture } } }
    var overlayStyle: OverlayStyle { didSet { if !reloading { controller.overlayStyle = overlayStyle } } }
    var launchAtLogin = LaunchAtLogin.isEnabled
    var message: String?
    var newTerm = ""
    var apiKeyDraft = ""
    var hasAPIKey = false
    var historyCount: Int?
    var connectionResult: String?
    var confirmClear = false
    var section = SettingsSection.general
    /// History shown in its sidebar page (made on first use).
    @ObservationIgnored lazy var history = HistoryModel(controller: controller)
    /// Mirrors of the controller's shortcut state (the controller isn't observable).
    var dictationMode = DictationMode.pushToTalk { didSet { if !reloading { controller.setMode(dictationMode) } } }
    var holdThresholdMs = DictationMode.defaultHoldThresholdMs { didSet { if !reloading { controller.setHoldThreshold(ms: holdThresholdMs) } } }
    var processMode = TextPipelineSettings.Mode.professional { didSet { if !reloading { controller.processMode = processMode } } }
    var shortcut = Shortcut.optionSpace
    var processShortcut: Shortcut?

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
        sounds = controller.soundSettings
        capture = controller.captureSettings
        overlayStyle = controller.overlayStyle
        launchAtLogin = LaunchAtLogin.isEnabled
        refreshShortcuts()
        refreshAPIKeyState()
    }

    func refreshShortcuts() {
        let wasReloading = reloading
        reloading = true
        defer { reloading = wasReloading }
        dictationMode = controller.mode
        holdThresholdMs = controller.holdThresholdMs
        processMode = controller.processMode
        shortcut = controller.hotkey.shortcut
        processShortcut = controller.hotkey.processShortcut
    }

    func refreshAPIKeyState() {
        Task {
            let has = await Task.detached { KeychainStore.anthropic.read() != nil }.value
            hasAPIKey = has
        }
    }

    /// Sparkle (nil in tests and when run outside the app bundle).
    var updates: Updates?

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
        sounds = controller.soundSettings
        capture = controller.captureSettings
        overlayStyle = controller.overlayStyle
        refreshShortcuts()
        shortcutObserver = NotificationCenter.default.addObserver(forName: DictationController.shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShortcuts() }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var shortcutObserver: NSObjectProtocol?

    private func applyGeneral(_ old: GeneralSettings) {
        general.save()
        if general.appearance != old.appearance { general.applyAppearance() }
        onGeneralChange?(general)
    }

    /// Picks a sound file for the Custom theme.
    func chooseSound(_ cue: SoundCue) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = cue == .start ? "Sound when recording starts" : "Sound when recording stops"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        if cue == .start { sounds.customStartPath = path } else { sounds.customStopPath = path }
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
    let changeShortcut: (ShortcutBinding) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(section: model.section)
                page(model.section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: SettingsWindowController.minSize.width, minHeight: SettingsWindowController.minSize.height)
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 14)
                    .onTapGesture { model.message = nil }
            }
        }
    }

    @ViewBuilder private func page(_ section: SettingsSection) -> some View {
        switch section {
        case .general: general
        case .dictation: dictation
        case .models: ModelManagerView(manager: model.controller.models)
        case .audio: audio
        case .insertion: insertion
        case .language: language
        case .processing: processing
        case .history: HistoryView(model: model.history).onAppear { model.history.reload() }
        case .privacy: privacy
        case .about: AboutPage(model: model)
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    HStack(spacing: 8) {
                        KeyCap(text: model.shortcut.displayString)
                        Button("Change…") { changeShortcut(.dictate) }
                        Button("Reset") { model.controller.resetShortcut() }
                            .disabled(model.shortcut == .optionSpace)
                            .help("Go back to ⌥Space")
                    }
                }
                Picker("Shortcut mode", selection: $model.dictationMode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.dictationMode == .holdOrToggle {
                    Stepper(value: $model.holdThresholdMs, in: DictationMode.holdThresholdRange, step: 50) {
                        LabeledContent("A tap is shorter than", value: "\(model.holdThresholdMs) ms")
                    }
                }
                Picker("Model", selection: Binding(get: { model.controller.models.defaultModelID },
                                                   set: { model.controller.models.setDefault($0) })) {
                    ForEach(model.controller.models.installedEntries, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Microphone", selection: Binding(get: { model.controller.preferredMicrophoneUID ?? "" },
                                                        set: { model.controller.selectMicrophone(uid: $0.isEmpty ? nil : $0) })) {
                    Text("System Default").tag("")
                    ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag($0.uid) }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("\(model.dictationMode == .toggle ? "Press" : "Hold") \(model.shortcut.displayString) and speak; the text appears where your cursor is. Press Esc while dictating to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While dictating") {
                Picker("Show", selection: $model.overlayStyle) {
                    ForEach(OverlayStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(Self.overlayNote(model.overlayStyle, entry: model.controller.loadedModelEntry))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play a sound when recording starts and stops", isOn: $model.sounds.enabled)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Picker("Appearance", selection: $model.general.appearance) {
                    ForEach(GeneralSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show the menu bar icon when idle", isOn: $model.general.showMenuBarIcon)
                Toggle("Open setup at launch when a permission is missing", isOn: $model.general.showSetupWhenNeeded)
                Toggle("Allow utter:// links to control dictation", isOn: $model.general.allowURLCommands)
                    .help("For Shortcuts, Raycast or scripts: utter://toggle, utter://start, utter://stop, utter://cancel. Off by default, because any web page can open a link.")
            } header: {
                Text("App")
            } footer: {
                Text("The icon always appears while you dictate. With it hidden, open Settings by launching Utter again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Dictation

    private var dictation: some View {
        Form {
            Section("AI shortcut") {
                Text("A second shortcut that dictates and then runs an AI mode, whatever your everyday mode is.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Shortcut") {
                    HStack {
                        Text(model.processShortcut?.displayString ?? "None").monospaced()
                        Button(model.processShortcut == nil ? "Set…" : "Change…") { changeShortcut(.process) }
                        if model.processShortcut != nil {
                            Button("Remove") { model.controller.setProcessShortcut(nil) }
                        }
                    }
                }
                Picker("Runs", selection: $model.processMode) {
                    ForEach(TextPipelineSettings.Mode.allCases.filter(\.usesProcessor), id: \.self) { Text($0.title).tag($0) }
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

    // MARK: Audio

    private var audio: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: Binding(get: { model.controller.preferredMicrophoneUID ?? "" },
                                                          set: { model.controller.selectMicrophone(uid: $0.isEmpty ? nil : $0) })) {
                    Text("System Default").tag("")
                    ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                LabeledContent("In use", value: model.controller.microphoneName ?? "—")
                if model.controller.microphoneChannels > 1 || model.capture.inputChannel != nil {
                    Picker("Channel", selection: $model.capture.inputChannel) {
                        Text("All channels (mixed)").tag(Int?.none)
                        ForEach(0..<max(model.controller.microphoneChannels, (model.capture.inputChannel ?? 0) + 1), id: \.self) {
                            Text("Channel \($0 + 1)").tag(Int?.some($0))
                        }
                    }
                }
                if Clamshell.isLaptop {
                    Picker("With the lid closed, use", selection: $model.capture.clamshellDeviceUID) {
                        Text("The same microphone").tag(String?.none)
                        ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
                    }
                }
            }
            Section("Recording") {
                Toggle("Keep the microphone ready (instant start)", isOn: Binding(get: { model.controller.keepMicrophoneReady },
                                                                                 set: { model.controller.setKeepMicrophoneReady($0) }))
                Text("Recording starts instantly and includes the moment before you press the shortcut. macOS shows the microphone indicator the whole time, and a Bluetooth headset stays in call mode. Audio is never stored unless you keep audio in History.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the microphone open for 30 s after dictating", isOn: $model.capture.lazyClose)
                    .disabled(model.controller.keepMicrophoneReady)
                Text("Back-to-back dictations start instantly; the microphone indicator stays on for those 30 s.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $model.capture.extraBufferMs, in: CaptureSettings.extraBufferRange, step: 50) {
                    LabeledContent("Keep recording after release", value: model.capture.extraBufferMs == 0 ? "Off" : "\(model.capture.extraBufferMs) ms")
                }
                Toggle("Remove long silences before transcribing", isOn: $model.capture.trimSilence)
            }
            Section("Sounds") {
                Toggle("Play a sound when recording starts and stops", isOn: $model.sounds.enabled)
                Picker("Sound", selection: $model.sounds.theme) {
                    ForEach(SoundSettings.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.sounds.theme == .custom {
                    LabeledContent("Start") {
                        HStack {
                            Text(model.sounds.customStartPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not chosen")
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { model.chooseSound(.start) }
                        }
                    }
                    LabeledContent("Stop") {
                        HStack {
                            Text(model.sounds.customStopPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not chosen")
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { model.chooseSound(.stop) }
                        }
                    }
                }
                Slider(value: $model.sounds.volume, in: 0...1) { Text("Volume") }
                Picker("Play on", selection: $model.sounds.outputDeviceUID) {
                    Text("System Output").tag(String?.none)
                    ForEach(AudioDevices.outputDevices(), id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
                }
                HStack {
                    Spacer()
                    Button("Play Start") { model.controller.playTestSound(.start) }
                    Button("Play Stop") { model.controller.playTestSound(.stop) }
                }
            }
            Section("Other audio") {
                Toggle("Mute other audio while recording", isOn: $model.sounds.muteWhileRecording)
                Text("Music and videos go quiet while you speak and come back as it was when you stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    static func overlayNote(_ style: OverlayStyle, entry: ModelEntry?) -> String {
        switch style {
        case .none: return "No pill while you speak. Notices (secure input, text that couldn't be confirmed) still appear."
        case .minimal: return "A small pill with a level meter and timer."
        case .live:
            guard let entry else { return "The words appear as you speak." }
            if let window = LivePreviewPolicy.windowSeconds(measuredRTF: entry.measuredRtf) {
                return "The words appear as you speak (the last \(Int(window)) s with \(entry.name)). The final text is transcribed again when you stop."
            }
            return "\(entry.name) is too slow for live text, so the meter and timer are shown. Parakeet, SenseVoice and Moonshine support it."
        }
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
            Picker("Keep dictations for", selection: $model.privacy.retention) {
                ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.privacy.historyEnabled)
            if model.privacy.retention == .limit {
                Picker("How many", selection: $model.privacy.historyLimit) {
                    ForEach(PrivacySettings.historyLimitChoices, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Text("Older dictations and their audio are deleted automatically. Starred ones are always kept.")
                .font(.caption).foregroundStyle(.secondary)
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

/// Hosts the Utter window: Settings, Models and History behind one sidebar.
@MainActor
public final class SettingsWindowController {
    static let minSize = NSSize(width: 860, height: 580)

    public let model: SettingsModel
    private var window: NSWindow?
    private let changeShortcut: (ShortcutBinding) -> Void

    public init(controller: DictationController, updates: Updates? = nil, changeShortcut: @escaping (ShortcutBinding) -> Void) {
        model = SettingsModel(controller: controller)
        model.updates = updates
        self.changeShortcut = changeShortcut
    }

    public func show(_ section: SettingsSection? = nil) {
        model.reload()
        if let section { model.section = section }
        if section == .models { model.controller.models.refresh() }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.minSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Utter"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = Self.minSize
            window.contentView = NSHostingView(rootView: SettingsView(model: model, changeShortcut: changeShortcut))
            window.setFrameAutosaveName("UtterSettings")
            if !window.setFrameUsingName("UtterSettings") { window.center() }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
