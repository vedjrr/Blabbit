import AppKit
import Observation
import SwiftUI
import BlabbitCore

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
    /// Models the chosen provider reported (Refresh), and a note about the last fetch.
    var providerModels: [String] = []
    var providerModelsNote: String?
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
            connectionResult = "Local-only mode is on (Privacy), so Blabbit won't contact \(processing.provider == .anthropic ? "Anthropic" : "that address")."
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

    /// Asks the provider which models it has (user-initiated).
    func refreshProviderModels() {
        let settings = processing
        providerModels = []
        if privacy.localOnly && !settings.isLocal {
            providerModelsNote = "Local-only mode is on (Privacy), so Blabbit won't contact that server."
            return
        }
        providerModelsNote = "Asking…"
        Task {
            do {
                let models: [String]
                switch settings.provider {
                case .none, .appleIntelligence: models = []
                case .ollama:
                    guard let url = URL(string: settings.ollamaURL) else { providerModelsNote = "That Ollama address isn't valid."; return }
                    models = try await ProcessorModels.ollama(baseURL: url)
                case .anthropic:
                    guard let key = await Task.detached(operation: { KeychainStore.anthropic.read() }).value else {
                        providerModelsNote = "Add an API key first."
                        return
                    }
                    models = try await ProcessorModels.anthropic(apiKey: key)
                }
                providerModels = models
                providerModelsNote = models.isEmpty
                    ? (settings.provider == .ollama ? "Ollama has no models yet. Run “ollama pull llama3.2” in Terminal." : "No models were listed.")
                    : nil
            } catch let error as TextProcessorError {
                providerModelsNote = error.userMessage
            } catch {
                providerModelsNote = "The model list couldn't be fetched."
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
        case .history: HistoryView(model: model.history).onAppear { model.history.reload() }
        case .models: ModelManagerView(manager: model.controller.models)
        case .advanced: advanced
        case .processing: processing
        case .about: AboutPage(model: model)
        }
    }

    // MARK: General — the everyday settings

    private var general: some View {
        Form {
            Section("Dictation") {
                LabeledContent {
                    HStack(spacing: 8) {
                        KeyCap(text: model.shortcut.displayString)
                        Button("Change…") { changeShortcut(.dictate) }
                        if model.shortcut != .optionSpace {
                            Button("Reset") { model.controller.resetShortcut() }
                        }
                    }
                } label: {
                    SettingLabel("Shortcut", help: "Press this anywhere to dictate; the text appears where your cursor is. Press Esc while dictating to cancel. Reset goes back to ⌥Space.")
                }
                Picker(selection: $model.dictationMode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Shortcut mode", help: "Hold to Talk: record while you hold the shortcut. Press to Start and Stop: press once to start, again to stop. The third choice does both: hold for a quick note, or tap to keep recording until the next tap.")
                }
                if model.dictationMode == .holdOrToggle {
                    Stepper(value: $model.holdThresholdMs, in: DictationMode.holdThresholdRange, step: 50) {
                        LabeledContent {
                            Text("\(model.holdThresholdMs) ms")
                        } label: {
                            SettingLabel("A tap is shorter than", help: "Presses shorter than this count as a tap (start and keep recording); longer ones as a hold.")
                        }
                    }
                }
                Toggle(isOn: $model.insertion.typeWhileSpeaking) {
                    SettingLabel("Type as you speak", help: Self.typeWhileSpeakingHelp(entry: model.controller.loadedModelEntry))
                }
            }
            Section("Speech") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("Model", selection: Binding(get: { model.controller.models.defaultModelID },
                                                           set: { model.controller.models.setDefault($0) })) {
                            ForEach(model.controller.models.installedEntries, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Manage…") { model.section = .models }
                    }
                } label: {
                    SettingLabel("Model", help: "The speech model that turns your voice into text. It runs on this Mac. Models shows how accurate and fast each one is.")
                }
                Picker(selection: Binding(get: { model.text.language ?? "" }, set: { model.text.language = $0.isEmpty ? nil : $0 })) {
                    Text("Detect automatically").tag("")
                    ForEach(Self.languages(for: model.controller.loadedModelEntry ?? model.controller.models.defaultEntry), id: \.self) { code in
                        Text(ChineseScript(languageCode: code)?.title ?? Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                } label: {
                    SettingLabel("Language", help: "The language you speak. Choosing it can help short dictations. The list shows what \(model.controller.modelName) supports.")
                }
                Picker(selection: $model.text.mode) {
                    ForEach(TextPipelineSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Text style", help: TextPipelineSettings.Mode.allCases.map { "\($0.title): \($0.summary)" }.joined(separator: "\n\n"))
                }
            }
            Section("Sound") {
                Picker(selection: Binding(get: { model.controller.preferredMicrophoneUID ?? "" },
                                          set: { model.controller.selectMicrophone(uid: $0.isEmpty ? nil : $0) })) {
                    Text("System Default").tag("")
                    ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag($0.uid) }
                } label: {
                    SettingLabel("Microphone", help: "Which microphone to record from. System Default follows the input chosen in System Settings → Sound.")
                }
                Toggle(isOn: $model.sounds.enabled) {
                    SettingLabel("Sound effects", help: "A short sound when recording starts and stops. Choose the sound and volume in Advanced.")
                }
                Toggle(isOn: $model.sounds.muteWhileRecording) {
                    SettingLabel("Mute other audio while recording", help: "Music and videos go quiet while you speak, and come back as they were when you stop.")
                }
            }
            Section("App") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    SettingLabel("Launch at login", help: "Start Blabbit when you log in, so the shortcut always works.")
                }
            }
        }
        .formStyle(.grouped)
    }

    static func typeWhileSpeakingHelp(entry: ModelEntry?) -> String {
        var text = "Each phrase is typed where your cursor is at the pause after it, while you keep talking. When you stop, only the last phrase is left. Turn off to insert everything at once when you stop."
        if let entry, !LiveTypingPolicy.applies(settings: InsertionSettings(), mode: .clean, family: entry.family, measuredRTF: entry.measuredRtf) {
            text += "\n\n\(entry.name) is too slow for this, so text goes in when you stop. Parakeet, SenseVoice and Moonshine support it."
        } else {
            text += "\n\nProfessional and Custom styles always insert when you stop, because the AI needs the whole text."
        }
        return text
    }

    // MARK: Advanced — everything else, grouped like Handy's

    private var advanced: some View {
        Form {
            Section("App") {
                Picker(selection: $model.overlayStyle) {
                    ForEach(OverlayStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("While dictating, show", help: Self.overlayNote(model.overlayStyle, entry: model.controller.loadedModelEntry))
                }
                Toggle(isOn: $model.general.showMenuBarIcon) {
                    SettingLabel("Menu bar icon", help: "Show Blabbit's icon in the menu bar when idle. It always appears while you dictate. With it hidden, open Settings by launching Blabbit again.")
                }
                Picker(selection: $model.general.appearance) {
                    ForEach(GeneralSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Appearance", help: "Light or dark windows, or follow your Mac.")
                }
                Toggle(isOn: $model.general.showSetupWhenNeeded) {
                    SettingLabel("Open setup when a permission is missing", help: "At launch, open the permissions window if Blabbit can't use the microphone or type into apps.")
                }
                Toggle(isOn: $model.general.allowURLCommands) {
                    SettingLabel("Allow blabbit:// links", help: "For Shortcuts, Raycast or scripts: blabbit://toggle, blabbit://start, blabbit://stop, blabbit://cancel. Off by default, because any web page can open a link.")
                }
            }
            Section("Text") {
                Toggle(isOn: $model.text.removeFillers) {
                    SettingLabel("Remove filler words", help: "Drops “um”, “uh” and similar from English text.")
                }
                Toggle(isOn: $model.text.capitalize) {
                    SettingLabel("Capitalize sentences", help: "Starts each sentence with a capital letter.")
                }
                Toggle(isOn: $model.text.autoPunctuation) {
                    SettingLabel("Full stop at the end", help: "Adds a full stop if the dictation doesn't end with punctuation.")
                }
                Toggle(isOn: $model.text.spokenLineBreaks) {
                    SettingLabel("Spoken line breaks", help: "Say “new line” or “new paragraph” to start one.")
                }
                Toggle(isOn: $model.text.translateToEnglish) {
                    SettingLabel("Translate to English", help: "Speak any language Whisper knows and get English text. Only Whisper models do this; others ignore it.")
                }
                vocabulary
            }
            Section("Inserting text") {
                Picker(selection: $model.insertion.method) {
                    Text("Type into the app").tag(InsertionSettings.Method.automatic)
                    Text("Copy to the clipboard only").tag(InsertionSettings.Method.clipboardOnly)
                    Text("Run a script").tag(InsertionSettings.Method.externalScript)
                } label: {
                    SettingLabel("Insert text by", help: "Type into the app puts the text where your cursor is (recommended). Clipboard only copies it for you to paste. Run a script sends it to your own script on stdin.")
                }
                if model.insertion.method == .externalScript {
                    TextField("Script path", text: Binding(get: { model.insertion.externalScriptPath ?? "" },
                                                           set: { model.insertion.externalScriptPath = $0.isEmpty ? nil : $0 }))
                }
                Toggle(isOn: $model.insertion.restoreClipboard) {
                    SettingLabel("Restore my clipboard after pasting", help: "Some apps get text by pasting. This puts back what was on your clipboard before.")
                }
                Toggle(isOn: $model.insertion.copyToClipboard) {
                    SettingLabel("Also leave the text on the clipboard", help: "After inserting, the dictation stays on the clipboard so you can paste it again.")
                }
                Toggle(isOn: $model.insertion.appendTrailingSpace) {
                    SettingLabel("Add a space after the text", help: "Handy when you dictate several times in a row.")
                }
                Picker(selection: $model.insertion.newlines) {
                    Text("Keep").tag(InsertionSettings.Newlines.keep)
                    Text("Replace with spaces").tag(InsertionSettings.Newlines.spaces)
                } label: {
                    SettingLabel("Line breaks", help: "Replace with spaces for chat apps, where Return sends the message.")
                }
                Picker(selection: $model.insertion.autoSubmit) {
                    Text("Nothing").tag(InsertionSettings.AutoSubmit.off)
                    Text("Return").tag(InsertionSettings.AutoSubmit.enter)
                    Text("⌃Return").tag(InsertionSettings.AutoSubmit.controlEnter)
                    Text("⌘Return").tag(InsertionSettings.AutoSubmit.commandEnter)
                } label: {
                    SettingLabel("Then press", help: "Press a key after the text goes in, for example to send a chat message. Never pressed if Blabbit couldn't confirm the text went in.")
                }
                perAppMethods
            }
            Section("Microphone and recording") {
                if model.controller.microphoneChannels > 1 || model.capture.inputChannel != nil {
                    Picker(selection: $model.capture.inputChannel) {
                        Text("All channels (mixed)").tag(Int?.none)
                        ForEach(0..<max(model.controller.microphoneChannels, (model.capture.inputChannel ?? 0) + 1), id: \.self) {
                            Text("Channel \($0 + 1)").tag(Int?.some($0))
                        }
                    } label: {
                        SettingLabel("Channel", help: "For audio interfaces with several inputs: record just one of them.")
                    }
                }
                if Clamshell.isLaptop {
                    Picker(selection: $model.capture.clamshellDeviceUID) {
                        Text("The same microphone").tag(String?.none)
                        ForEach(AudioDeviceCache.shared.devices, id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
                    } label: {
                        SettingLabel("With the lid closed, use", help: "The built-in microphone doesn't work with the lid closed; choose another one to switch to automatically.")
                    }
                }
                Toggle(isOn: Binding(get: { model.controller.keepMicrophoneReady },
                                     set: { model.controller.setKeepMicrophoneReady($0) })) {
                    SettingLabel("Keep the microphone ready", help: "Recording starts instantly and includes the moment before you press the shortcut. macOS shows the microphone indicator the whole time, and a Bluetooth headset stays in call mode. Audio is never stored unless you keep audio in History.")
                }
                Toggle(isOn: $model.capture.lazyClose) {
                    SettingLabel("Keep the microphone open for 30 s after dictating", help: "Back-to-back dictations start instantly; the microphone indicator stays on for those 30 s.")
                }
                .disabled(model.controller.keepMicrophoneReady)
                Stepper(value: $model.capture.extraBufferMs, in: CaptureSettings.extraBufferRange, step: 50) {
                    LabeledContent {
                        Text(model.capture.extraBufferMs == 0 ? "Off" : "\(model.capture.extraBufferMs) ms")
                    } label: {
                        SettingLabel("Keep recording after release", help: "Catches a last word you're still finishing as you let go of the shortcut.")
                    }
                }
                Toggle(isOn: $model.capture.trimSilence) {
                    SettingLabel("Remove long silences", help: "Cuts long pauses out before transcribing, which is faster for long dictations.")
                }
            }
            Section("Sounds") {
                Picker(selection: $model.sounds.theme) {
                    ForEach(SoundSettings.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Sound", help: "The start and stop sounds. Custom Files lets you pick your own.")
                }
                .disabled(!model.sounds.enabled)
                if model.sounds.theme == .custom {
                    soundFile("Start", path: model.sounds.customStartPath, cue: .start)
                    soundFile("Stop", path: model.sounds.customStopPath, cue: .stop)
                }
                Slider(value: $model.sounds.volume, in: 0...1) { SettingLabel("Volume") }
                    .disabled(!model.sounds.enabled)
                Picker(selection: $model.sounds.outputDeviceUID) {
                    Text("System Output").tag(String?.none)
                    ForEach(AudioDevices.outputDevices(), id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
                } label: {
                    SettingLabel("Play on", help: "Which speakers or headphones play the sounds.")
                }
                .disabled(!model.sounds.enabled)
                HStack {
                    Spacer()
                    Button("Play Start") { model.controller.playTestSound(.start) }
                    Button("Play Stop") { model.controller.playTestSound(.stop) }
                }
            }
            Section("History and privacy") {
                Toggle(isOn: $model.privacy.localOnly) {
                    SettingLabel("Local-only mode", help: "Never send text to a cloud AI, even in Professional or Custom style. Speech is always transcribed on this Mac either way.")
                }
                Toggle(isOn: $model.privacy.historyEnabled) {
                    SettingLabel("Keep a history", help: "Save each dictation in History, on this Mac only (~/Library/Application Support/Blabbit).")
                }
                Toggle(isOn: $model.privacy.keepAudio) {
                    SettingLabel("Keep the audio", help: "Also save each recording, so you can play it back or transcribe it again with another model.")
                }
                .disabled(!model.privacy.historyEnabled)
                Picker(selection: $model.privacy.retention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Keep dictations for", help: "Older dictations and their audio are deleted automatically. Starred ones are always kept.")
                }
                .disabled(!model.privacy.historyEnabled)
                if model.privacy.retention == .limit {
                    Picker("How many", selection: $model.privacy.historyLimit) {
                        ForEach(PrivacySettings.historyLimitChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                LabeledContent {
                    Button("Clear…", role: .destructive) { model.confirmClear = true }
                        .confirmationDialog("Delete all history and kept audio?", isPresented: $model.confirmClear) {
                            Button("Delete", role: .destructive) { model.clearLocalData() }
                        } message: {
                            Text("This can't be undone. Models and settings are kept.")
                        }
                } label: {
                    SettingLabel("Saved dictations: \(model.historyCount.map(String.init) ?? "—")", help: "Delete all history and kept audio from this Mac.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHistoryCount() }
    }

    private func soundFile(_ title: String, path: String?, cue: SoundCue) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not chosen")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { model.chooseSound(cue) }
            }
        }
    }

    @ViewBuilder private var vocabulary: some View {
        LabeledContent {
            HStack {
                TextField("Add a word", text: $model.newTerm)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { model.addTerm() }
                Button("Add") { model.addTerm() }.disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } label: {
            SettingLabel("Personal vocabulary", help: "Names and terms Blabbit should spell your way, like HoldMyCode or PostgreSQL. Close mishearings are corrected, and Whisper models are primed with them.")
        }
        if !model.text.vocabulary.isEmpty {
            FlowTags(tags: model.text.vocabulary) { term in model.text.vocabulary.removeAll { $0 == term } }
        }
    }

    @ViewBuilder private var perAppMethods: some View {
        LabeledContent {
            Button("Add App…") { addOverride() }
        } label: {
            SettingLabel("Per-app method", help: "Blabbit uses Accessibility in native apps and paste in terminals, browsers and Electron apps. If an app gets text wrong, choose its method here.")
        }
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

    static func overlayNote(_ style: OverlayStyle, entry: ModelEntry?) -> String {
        switch style {
        case .none: return "No pill while you speak. Notices (secure input, text that couldn't be confirmed) still appear."
        case .minimal: return "A small pill with the listening orb and a timer."
        case .live:
            let base = "The orb and timer, plus the words so far when they can't be typed as you speak (Professional and Custom styles, or with Type as You Speak off)."
            guard let entry, LivePreviewPolicy.windowSeconds(measuredRTF: entry.measuredRtf) == nil else { return base }
            return base + " \(entry.name) is too slow for live words; Parakeet, SenseVoice and Moonshine support them."
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

    static let releasesURL = URL(string: "https://github.com/vedjrr/Blabbit/releases")!

    static func languages(for entry: ModelEntry?) -> [String] {
        var codes = entry?.languages ?? ["en"]
        if codes.isEmpty { codes = ["en"] } // a custom file: languages unknown
        // Chinese comes as a choice of script (PARITY D7).
        if let i = codes.firstIndex(of: "zh") { codes.replaceSubrange(i...i, with: ChineseScript.allCases.map(\.rawValue)) }
        return codes.sorted {
            (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1)
        }
    }

    // MARK: AI rewriting

    private var processing: some View {
        Form {
            Section("Processor") {
                Picker(selection: $model.processing.provider) {
                    ForEach(ProcessorSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Processor", help: "Professional and Custom styles can use an AI after Blabbit's own clean-up. Exact, Clean and Code never do. If the AI fails, the cleaned-up text is used.")
                }
                switch model.processing.provider {
                case .none:
                    EmptyView()
                case .appleIntelligence:
                    Text(AppleIntelligenceProcessor.unavailableReason ?? "Uses Apple's on-device model. Nothing leaves your Mac.")
                        .font(.callout).foregroundStyle(AppleIntelligenceProcessor.unavailableReason == nil ? Color.secondary : Color.orange)
                case .ollama:
                    TextField("Ollama address", text: $model.processing.ollamaURL)
                    modelField($model.processing.ollamaModel)
                    if model.privacy.localOnly && !model.processing.isLocal {
                        Text("This address isn't on this Mac. Local-only mode is on, so it won't be used.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                case .anthropic:
                    if model.privacy.localOnly {
                        Text("Local-only mode is on (Advanced), so the cloud processor won't be used.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    modelField($model.processing.anthropicModel)
                    if model.hasAPIKey {
                        LabeledContent {
                            HStack { Text("Saved in Keychain").foregroundStyle(.secondary); Button("Remove") { model.removeAPIKey() } }
                        } label: {
                            SettingLabel("API key", help: "Your text is sent to Anthropic only when you dictate in Professional or Custom style.")
                        }
                    } else {
                        HStack {
                            SecureField("API key", text: $model.apiKeyDraft)
                            Button("Save") { model.saveAPIKey() }.disabled(model.apiKeyDraft.isEmpty)
                        }
                    }
                }
                if model.processing.provider != .none {
                    HStack {
                        Button("Test") { model.testProcessor() }
                        if let result = model.connectionResult { Text(result).font(.caption).lineLimit(2) }
                    }
                }
            }
            Section("AI shortcut") {
                LabeledContent {
                    HStack {
                        if let shortcut = model.processShortcut { KeyCap(text: shortcut.displayString) } else { Text("None").foregroundStyle(.secondary) }
                        Button(model.processShortcut == nil ? "Set…" : "Change…") { changeShortcut(.process) }
                        if model.processShortcut != nil {
                            Button("Remove") { model.controller.setProcessShortcut(nil) }
                        }
                    }
                } label: {
                    SettingLabel("Shortcut", help: "A second shortcut that dictates and then runs an AI style, whatever your everyday text style is.")
                }
                Picker(selection: $model.processMode) {
                    ForEach(TextPipelineSettings.Mode.allCases.filter(\.usesProcessor), id: \.self) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel("Runs", help: "Which AI style the AI shortcut uses.")
                }
            }
            Section("Custom style prompts") {
                promptEditor
            }
        }
        .formStyle(.grouped)
    }

    /// Custom style's saved prompts (PARITY D5): pick one, edit it, add or delete.
    @ViewBuilder private var promptEditor: some View {
        Picker(selection: $model.text.selectedPromptID) {
            ForEach(model.text.prompts) { Text($0.name).tag($0.id) }
        } label: {
            SettingLabel("Prompt", help: "The instruction the AI follows in Custom style. Keep several and switch between them.")
        }
        if let index = model.text.prompts.firstIndex(where: { $0.id == model.text.selectedPrompt?.id }) {
            TextField("Name", text: $model.text.prompts[index].name)
            TextField("Instruction", text: $model.text.prompts[index].instruction, axis: .vertical)
                .lineLimit(2...5)
        }
        HStack {
            Button("New Prompt") {
                let prompt = SavedPrompt(name: "New prompt", instruction: "Rewrite this as ")
                model.text.prompts.append(prompt)
                model.text.selectedPromptID = prompt.id
            }
            Button("Delete", role: .destructive) {
                model.text.prompts.removeAll { $0.id == model.text.selectedPrompt?.id }
                model.text.selectedPromptID = model.text.prompts.first?.id ?? ""
            }
            .disabled(model.text.prompts.count <= 1)
        }
    }

    /// A model name with a menu of what the provider reported (PARITY D9).
    private func modelField(_ name: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Model", text: name)
                if !model.providerModels.isEmpty {
                    Menu("Choose") {
                        ForEach(model.providerModels, id: \.self) { id in Button(id) { name.wrappedValue = id } }
                    }
                    .fixedSize()
                }
                Button("Refresh") { model.refreshProviderModels() }
                    .help("Ask the provider which models it has")
            }
            if let note = model.providerModelsNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Vocabulary terms as removable chips.
struct FlowTags: View {
    let tags: [String]
    let remove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(.callout)
                    Button { remove(tag) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(tag)")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Hosts the Blabbit window: Settings, Models and History behind one sidebar.
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
            window.title = "Blabbit"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = Self.minSize
            window.contentView = NSHostingView(rootView: SettingsView(model: model, changeShortcut: changeShortcut))
            window.setFrameAutosaveName("BlabbitSettings")
            if !window.setFrameUsingName("BlabbitSettings") { window.center() }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
