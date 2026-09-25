import AppKit
import UtterCore

/// Coordinates hotkey → microphone → local model → text insertion (ADR-008).
/// Nothing here calls into Rust on the main actor except lock-free status reads.
@MainActor
public final class DictationController {
    public enum State: Equatable {
        case starting
        case loadingModel
        case ready
        case recording
        case transcribing
        case failed(String)
    }

    public private(set) var state: State = .starting {
        didSet {
            if state != .recording { stopIncrementalFeed() }
            updateOverlay(from: oldValue)
            onStateChange?(state)
            // Apply a model switch that was requested during the dictation.
            if let pending = pendingModelID, !isBusyDictating, state != .loadingModel {
                Task { @MainActor [weak self] in self?.loadModel(id: pending) }
            }
        }
    }
    public var onStateChange: ((State) -> Void)?
    /// Fired after a dictation that was blocked or couldn't be confirmed.
    public var onAttention: ((AttentionCue) -> Void)?
    public let models: ModelManager
    public var modelName: String { models.defaultEntry?.name ?? "No model" }
    /// Called when no usable model is installed (e.g. first launch) so the UI can open the Model Manager.
    public var onNeedsModel: (() -> Void)?
    /// Called at launch when a permission is missing, so the UI can open the setup window.
    public var onNeedsPermissions: (() -> Void)?
    public private(set) var lastMessage: String?
    /// Shown while secure input is sustained (kept apart from `lastMessage`).
    public private(set) var secureInputNotice: String?
    /// Set when the background load completes; never queried from Rust on main.
    public private(set) var modelLoaded = false

    public let hotkey = HotkeyMonitor(shortcut: Shortcut.load())
    public private(set) var mode = DictationMode.load()

    public func setMode(_ newMode: DictationMode) {
        mode = newMode
        newMode.save()
        Log.info("dictation mode \(newMode.rawValue)")
    }

    /// Changes the shortcut (validated) and saves it.
    public func setShortcut(_ shortcut: Shortcut) {
        guard shortcut.problem == nil else { return }
        hotkey.shortcut = shortcut
        shortcut.save()
        Log.info("shortcut changed to \(shortcut.displayString)")
        onStateChange?(state)
    }

    private func hotkeyEvent(keyDown: Bool, _ timing: KeyTiming) {
        switch HotkeyPolicy.decide(keyDown: keyDown, mode: mode, recording: state == .recording) {
        case .start:
            var timing = timing
            if mode == .toggle { timing.source = .toggle }
            pressed(timing)
        case .stop:
            released(timing)
        case .ignore:
            break
        }
    }
    /// Mic start/stop and resampling run here so neither the event-tap thread
    /// nor the main thread blocks on audio.
    private let audioQueue = DispatchQueue(label: "dev.utter.audio", qos: .userInteractive)
    private lazy var recorder = AudioRecorder(queue: audioQueue)
    private let engine = UtterEngine()
    private let inserter = TextInserter()

    /// Settings → Text Insertion (saved on change).
    public var insertionSettings: InsertionSettings {
        get { inserter.settings }
        set {
            inserter.settings = newValue
            newValue.save()
        }
    }

    /// Per-app strategy overrides (Settings → Text Insertion).
    public var insertionOverrides: [String: [InsertionStrategy]] {
        get { inserter.table.overrides }
        set {
            inserter.table.overrides = newValue
            inserter.table.save()
        }
    }
    private var press: KeyTiming?
    private var recordStartedNs: UInt64 = 0
    /// When the overlay was put on screen for the current dictation.
    private var overlayShownNs: UInt64 = 0

    /// The non-activating overlay (level meter, timer, processing state, notices).
    public private(set) lazy var overlay: OverlayController = {
        let recorder = self.recorder
        return OverlayController(levelProvider: { recorder.level })
    }()

    private func updateOverlay(from old: State) {
        switch state {
        case .recording:
            overlay.show(.recording(startedAt: Date()))
            overlayShownNs = MonoClock.nowNs()
        case .transcribing:
            overlay.show(.transcribing)
        case .failed(let message) where old == .recording || old == .transcribing:
            // A dictation failed: say so where the user is looking.
            overlay.show(.notice(message, .failed))
        case .ready, .failed, .loadingModel, .starting:
            if old == .recording || old == .transcribing { overlay.hide() }
        }
    }
    /// Set when the mic can't be used; shown instead of "Ready" once the model loads.
    private var micProblem: String?
    /// Watches a hotkey-driven recording for a missed key-up (see `startWatchdog`).
    private var watchdog: Timer?
    private var recordingSource: RecordingSource = .tap
    /// Hard cap so a lost key-up can never leave the microphone on indefinitely.
    public static let maxRecordingSeconds: TimeInterval = 10 * 60

    public init(models: ModelManager) {
        self.models = models
        models.onDefaultModelChange = { [weak self] id in self?.loadModel(id: id) }
    }

    /// Only an idle controller accepts a new dictation; presses during
    /// transcription or insertion are ignored so dictations never overlap.
    private var acceptsPress: Bool {
        switch state {
        case .ready, .failed: return modelLoaded
        default: return false
        }
    }

    public func launch() {
        Log.info("launch pid=\(ProcessInfo.processInfo.processIdentifier) core=\(coreVersion()) macos=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        if #available(macOS 15.4, *) {
            Log.info("pasteboard access_behavior=\(NSPasteboard.general.accessBehavior.rawValue) (0 default, 1 ask, 2 allow, 3 deny)")
        }
        hotkey.onPress = { [weak self] timing in
            Task { @MainActor in self?.hotkeyEvent(keyDown: true, timing) }
        }
        hotkey.onRelease = { [weak self] timing in
            Task { @MainActor in self?.hotkeyEvent(keyDown: false, timing) }
        }
        hotkey.onShortcutConflict = { [weak self] error in
            self?.lastMessage = error.userMessage
            self?.onStateChange?(self?.state ?? .ready)
        }
        hotkey.onSecureInputChange = { [weak self] sustained in
            self?.secureInputNotice = sustained
                ? "Secure input is on (a password field, or Terminal's Secure Keyboard Entry), so Utter won't type until it's off. Dictation still works: text goes to the clipboard."
                : nil
            self?.onStateChange?(self?.state ?? .ready)
        }
        // No system prompts at launch: the setup window explains each
        // permission and asks when the user clicks.
        let store = historyStore
        historyQueue.async { _ = store.value } // open + migrate off the main thread
        // Build and draw the overlay once now, so the first key-down doesn't pay for it.
        overlay.prewarm()
        recorder.onCaptureLost = { [weak self] in
            Task { @MainActor in self?.captureLost() }
        }
        recorder.onKeepReadyFailed = { [weak self] _ in
            Task { @MainActor in
                self?.lastMessage = "Utter couldn't keep the microphone ready, so the next recording may start a moment later. It retries when a microphone is available."
            }
        }
        // First CoreAudio enumeration and listener setup off the main thread.
        audioQueue.async { _ = AudioDeviceCache.shared }
        recorder.onDeviceReady = { [weak self] name in
            Task { @MainActor in
                self?.microphoneName = name
                self?.onStateChange?(self?.state ?? .ready)
            }
        }
        let permissions = PermissionSnapshot.current()
        startHotkey()
        prepareMicrophone(permissions.microphone)
        let general = GeneralSettings.load()
        general.applyAppearance()
        // Always at launch: the model loads once, warms up and stays resident (hard rule 3).
        loadModel(id: models.defaultModelID)
        if !permissions.allGranted, general.showSetupWhenNeeded { onNeedsPermissions?() }
        // Always: a permission revoked and granted again later must be noticed too.
        startPermissionWatch()
    }

    /// While a permission is missing, re-check every 2 s even with the setup
    /// window closed ("Later"), so a grant in System Settings takes effect.
    private var permissionWatch: Timer?
    private var lastPermissions = PermissionSnapshot.current()

    private func startPermissionWatch() {
        permissionWatch?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = PermissionSnapshot.current()
                if now != self.lastPermissions {
                    self.lastPermissions = now
                    self.permissionsChanged(now)
                }

            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionWatch = timer
    }

    /// Called by the setup window when a permission changes, so a grant takes
    /// effect without relaunching Utter.
    public func permissionsChanged(_ snapshot: PermissionSnapshot) {
        lastPermissions = snapshot
        if snapshot.accessibility, !hotkey.isRunning { startHotkey() }
        prepareMicrophone(snapshot.microphone)
        onStateChange?(state)
    }

    private func prepareMicrophone(_ access: PermissionSnapshot.Mic) {
        switch access {
        case .granted:
            if micProblem == Self.micDeniedMessage || micProblem == Self.micNotAskedMessage {
                micProblem = nil
                if case .failed = state, modelLoaded { state = .ready }
            }
            applyMicrophoneChoice(UserDefaults.standard.string(forKey: AudioDevices.preferenceKey))
        case .notDetermined:
            micProblem = Self.micNotAskedMessage
        case .denied:
            micProblem = Self.micDeniedMessage
            fail(Self.micDeniedMessage)
        }
    }

    /// The microphone went away mid-recording and none could take over: stop
    /// now (in toggle mode the user might otherwise talk into nothing) and
    /// transcribe what was captured.
    private func captureLost() {
        guard state == .recording else { return }
        Log.error("capture lost mid-recording; stopping the dictation")
        released(KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0, source: recordingSource))
    }

    /// How text is shaped after transcription (Settings → Dictation).
    public var textSettings = TextPipelineSettings.load() {
        didSet { textSettings.save() }
    }
    /// Which AI processor Professional/Custom use (Settings → Processing).
    public var processorSettings = ProcessorSettings.load() {
        didSet { processorSettings.save() }
    }
    /// Settings → Privacy.
    public var privacySettings = PrivacySettings.load() {
        didSet { privacySettings.save() }
    }
    /// Local history, opened (with its migration) on a background queue.
    private nonisolated let historyStore = LazyStore()
    private let historyQueue = DispatchQueue(label: "dev.utter.history", qos: .utility)
    /// nil if the database couldn't be opened; dictation still works. May block
    /// briefly while the background open finishes: prefer `historyIfOpen` on main.
    public var history: HistoryStore? { historyStore.value }
    /// The store if it's already open (never opens or waits on the main thread).
    public var historyIfOpen: HistoryStore? { historyStore.ifOpen }
    /// For work already off the main thread.
    public nonisolated func historyStoreForBackground() -> HistoryStore? { historyStore.value }
    /// The model actually loaded (for Settings → Language).
    public var loadedModelEntry: ModelEntry? { loadedModelID.flatMap { models.entry($0) } }

    /// Opens the history database once, on a background queue.
    final class LazyStore: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: HistoryStore?
        private var tried = false
        var ifOpen: HistoryStore? {
            guard lock.try() else { return nil } // being opened right now
            defer { lock.unlock() }
            return opened
        }
        var value: HistoryStore? {
            lock.lock(); defer { lock.unlock() }
            if !tried {
                tried = true
                do { opened = try HistoryStore() } catch { Log.error("history unavailable: \(error)") }
            }
            return opened
        }
    }

    /// Saves a finished dictation off the main thread (text only unless audio retention is on).
    private func recordHistory(_ pipeline: PipelineResult, recording: Recording, app: String?) {
        guard privacySettings.historyEnabled else { return }
        let entry = HistoryEntry(durationMs: recording.durationMs, model: loadedModelID ?? "unknown",
                                 mode: textSettings.mode.rawValue, raw: pipeline.raw, final: pipeline.final, app: app)
        let audio = HistoryPolicy.audioToKeep(recording.samples, privacy: privacySettings)
        let store = historyStore
        historyQueue.async {
            do {
                guard let history = store.value else { return }
                var e = entry
                if let audio { e.audioFile = try history.saveAudio(audio) }
                try history.add(e)
            } catch {
                Log.error("history write failed: \(error)")
            }
        }
    }

    /// The last dictation's pipeline result (for history).
    public private(set) var lastPipeline: PipelineResult?
    private var processedNs: UInt64 = 0
    /// This dictation's pipeline result, for its log line (set even when skipped).
    private var currentPipeline: PipelineResult?
    /// "No processor" is said once per session, not on every dictation.
    private var warnedNoProcessor = false
    /// The model the language notice was last shown for (once per model).
    private var lastLanguageNotice: String?

    /// Transcription options for the loaded model and current settings.
    private func dictationOptions(noticeUnsupportedLanguage: Bool) -> DictationOptions {
        let text = textSettings
        let loadedEntry = loadedModelID.flatMap { models.entry($0) }
        let family = loadedEntry?.family
        // A language the loaded model lacks would fail every dictation: detect instead.
        let language = text.effectiveLanguage(forModelLanguages: loadedEntry?.languages)
        if noticeUnsupportedLanguage, text.language != nil, language == nil, lastLanguageNotice != loadedModelID {
            lastLanguageNotice = loadedModelID
            let name = Locale.current.localizedString(forLanguageCode: text.language ?? "") ?? text.language ?? ""
            lastMessage = "\(loadedEntry?.name ?? "This model") doesn't support \(name), so the language is detected automatically."
        }
        return DictationOptions(language: language, translate: text.translateToEnglish && family == "whisper",
                                initialPrompt: text.initialPrompt(forModelFamily: family, modelID: loadedModelID))
    }

    // MARK: Incremental transcription of long dictations

    private var incremental: IncrementalTranscriber?
    private var feedTimer: Timer?

    /// Every 2 s while recording, hand new audio to the incremental transcriber.
    private func startIncremental() {
        stopIncrementalFeed()
        let inc = IncrementalTranscriber(engine: engine, options: dictationOptions(noticeUnsupportedLanguage: false))
        incremental = inc
        let recorder = self.recorder
        let queue = audioQueue
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            queue.async {
                guard recorder.isRecording else { return }
                inc.append(recorder.samplesSoFar(from: inc.fed))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        feedTimer = timer
    }

    private func stopIncrementalFeed() {
        feedTimer?.invalidate()
        feedTimer = nil
    }

    public nonisolated static let keepMicReadyKey = "audio.keepMicrophoneReady"
    public var keepMicrophoneReady: Bool { UserDefaults.standard.bool(forKey: Self.keepMicReadyKey) }

    /// Keeps the input running between dictations for an instant start (the
    /// microphone indicator stays on). Off by default.
    public func setKeepMicrophoneReady(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.keepMicReadyKey)
        guard Permissions.microphoneStatus == .authorized else { return }
        let recorder = self.recorder
        audioQueue.async {
            do { try recorder.setKeepReady(on) } catch let error as AudioRecorderError {
                Task { @MainActor in self.lastMessage = self.message(for: error) }
            } catch {}
        }
    }

    /// The input device in use, for the menu (updated after each graph build).
    public private(set) var microphoneName: String?
    public var preferredMicrophoneUID: String? { UserDefaults.standard.string(forKey: AudioDevices.preferenceKey) }

    /// Chooses the microphone (nil = follow the system default) and persists it.
    public func selectMicrophone(uid: String?) {
        UserDefaults.standard.set(uid, forKey: AudioDevices.preferenceKey)
        applyMicrophoneChoice(uid)
    }

    private func applyMicrophoneChoice(_ uid: String?) {
        let recorder = self.recorder
        audioQueue.async {
            do {
                try recorder.setPreferredDevice(uid: uid)
                try recorder.prepare()
                try recorder.setKeepReady(UserDefaults.standard.bool(forKey: Self.keepMicReadyKey))
                let name = recorder.activeDevice?.name
                let missing = recorder.missingPreferredDevice
                Task { @MainActor in
                    self.microphoneName = name
                    if missing != nil, let name {
                        self.lastMessage = "Your chosen microphone isn't connected, so Utter is using \(name)."
                    }
                    self.onStateChange?(self.state)
                }
            } catch let error as AudioRecorderError {
                Task { @MainActor in
                    self.micProblem = self.message(for: error)
                    self.fail(self.message(for: error))
                }
            } catch {}
        }
    }

    /// `prompt`: show the system Accessibility prompt if not trusted (only on a
    /// user action, never by itself at launch).
    public func startHotkey(prompt: Bool = false) {
        guard !hotkey.isRunning else { return }
        if prompt, !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        do {
            try hotkey.start()
            if lastMessage == HotkeyError.tapCreationFailed.userMessage { lastMessage = nil }
        } catch let error as HotkeyError {
            Log.error("hotkey start failed: \(error)")
            lastMessage = error.userMessage
            onStateChange?(state)
        } catch {}
    }

    /// Bumped by every load request; a load that is no longer the latest
    /// neither starts (if still queued) nor touches the UI when it finishes.
    private let loadTicket = LoadTicket()
    /// Loads run one at a time in request order, so the last choice is the one resident.
    private let loadQueue = DispatchQueue(label: "dev.utter.model-load", qos: .userInitiated)
    /// A switch requested mid-dictation; applied once the controller is idle.
    private var pendingModelID: String?
    private var loadedModelID: String?

    private var isBusyDictating: Bool { Self.defersModelSwitch(in: state) }

    /// A model switch must never interrupt a dictation: loading would unload the
    /// model mid-transcription and the state change would strand the microphone.
    public nonisolated static func defersModelSwitch(in state: State) -> Bool {
        state == .recording || state == .transcribing
    }

    /// Loads (or switches to) a model in the background. The Rust engine unloads
    /// the previous model first, so two are never resident at once. Never
    /// interrupts a dictation: a switch during recording/transcription waits.
    public func loadModel(id requested: String) {
        if isBusyDictating {
            pendingModelID = requested
            Log.info("model switch to \(requested) queued until the current dictation finishes")
            return
        }
        pendingModelID = nil
        // Switching back to the model already resident (e.g. B then A during a dictation).
        if requested == loadedModelID, modelLoaded, models.status[requested] == .installed {
            models.commitDefault(requested)
            return
        }
        guard let entry = models.entry(requested) ?? models.entry(models.committedDefaultID) ?? models.entries.first(where: \.recommended),
              let path = models.path(for: entry.id) else { return }
        let id = entry.id
        guard models.status[id] == .installed else {
            let problem: String
            if models.isDamaged(id) {
                problem = "\(entry.name) is damaged or incomplete. Open the Model Manager and choose Re-download."
            } else if FileManager.default.fileExists(atPath: path) {
                problem = "\(entry.name)'s file is incomplete. Open the Model Manager and download it again."
            } else {
                problem = "\(entry.name) isn't downloaded. Open the Model Manager to download it."
            }
            // Keep dictation working with another installed model if there is one.
            // Prefer the last model that loaded, else the first installed one.
            let committed = models.committedDefaultID
            let fallbackID = committed != id && models.status[committed] == .installed
                ? committed : models.installedEntries.first(where: { $0.id != id })?.id
            if let fallbackID, let fallback = models.entry(fallbackID) {
                Log.info("model \(id) unavailable; falling back to \(fallbackID)")
                models.setDefault(fallbackID) // loads it through onDefaultModelChange
                lastMessage = "\(problem) Using \(fallback.name) for now."
                return
            }
            modelLoaded = false
            fail(installedNothingMessage(problem))
            onNeedsModel?()
            return
        }
        let ticket = loadTicket.next()
        modelLoaded = false
        state = .loadingModel
        let engine = self.engine
        let loadTicket = self.loadTicket
        let loadQueue = self.loadQueue
        Task {
            // SHA-256 once per file before its first load; a damaged file is
            // caught here instead of failing (or mis-transcribing) later.
            if !models.isVerified(id) {
                let result = await models.verify(id)
                guard loadTicket.isCurrent(ticket) else { return }
                // `.notChecked` says nothing about the file: load it, and the
                // loader reports a genuinely broken file itself.
                if result == .damaged {
                    loadFailed(id: id, entry: entry, damaged: true, message: nil)
                    return
                }
            }
            let before = processFootprintBytes()
            let started = MonoClock.nowNs()
            let outcome: Result<LoadInfo, Error>? = await withCheckedContinuation { continuation in
                loadQueue.async {
                    // Superseded while queued: skip the load entirely.
                    guard loadTicket.isCurrent(ticket) else { return continuation.resume(returning: nil) }
                    continuation.resume(returning: Result { try engine.loadModel(path: path) })
                }
            }
            guard let outcome else { return }
            switch outcome {
            case .success(let info):
                Log.info(String(format: "model_load model=%@ load_ms=%.0f warmup_ms=%.0f footprint_before_mb=%.0f footprint_mb=%.0f total_ms=%.0f load_count=%llu",
                                id, info.loadMs, info.warmupMs, Double(before) / 1_048_576,
                                Double(info.footprintAfterBytes) / 1_048_576,
                                MonoClock.ms(from: started, to: MonoClock.nowNs()), engine.loadCount()))
                loadedModelID = id
                guard loadTicket.isCurrent(ticket) else { return }
                models.commitDefault(id)
                modelLoaded = true
                if let problem = micProblem { state = .failed(problem) } else { state = .ready }
            case .failure(let error as CoreError):
                Log.error("model load failed model=\(id): \(error.logDetail)")
                guard loadTicket.isCurrent(ticket) else { return }
                switch error {
                case .ModelCorrupt, .ModelMissing: loadFailed(id: id, entry: entry, damaged: true, message: nil)
                default: loadFailed(id: id, entry: entry, damaged: false, message: error.userMessage)
                }
            case .failure:
                guard loadTicket.isCurrent(ticket) else { return }
                loadFailed(id: id, entry: entry, damaged: false, message: "The speech model could not be loaded.")
            }
        }
    }

    private func installedNothingMessage(_ problem: String) -> String {
        models.installedEntries.isEmpty ? "No speech model is installed yet. " + problem : problem
    }

    /// A load failed. Mark the file if it is damaged, go back to the last model
    /// that worked (the engine already unloaded it), and tell the user.
    private func loadFailed(id: String, entry: ModelEntry, damaged: Bool, message: String?) {
        let text = damaged ? "\(entry.name) is damaged or incomplete. Open the Model Manager and choose Re-download." : (message ?? "")
        if damaged { models.markDamaged(id, message: text) }
        let previous = models.committedDefaultID
        if previous != id, models.status[previous] == .installed {
            models.revertDefault()
            let name = models.entry(previous)?.name ?? previous
            Log.info("model switch to \(id) failed; going back to \(previous)")
            loadModel(id: previous)
            lastMessage = "\(text) Utter went back to \(name)."
            return
        }
        modelLoaded = false
        fail(text)
        if damaged { onNeedsModel?() }
    }

    // MARK: Recording lifecycle

    private func pressed(_ timing: KeyTiming) {
        guard acceptsPress else {
            if state == .loadingModel { lastMessage = "\(modelName) is still loading. Try again in a moment." }
            Log.info("press ignored state=\(state)")
            return
        }
        press = timing
        recordStartedNs = 0
        // A notice belongs to the dictation that caused it.
        lastMessage = nil
        // Microphone first: nothing (overlay, menu) may delay key-down → first audio.
        let recorder = self.recorder
        defer {
            state = .recording
            recordingSource = timing.source
            startWatchdog()
            startIncremental()
        }
        audioQueue.async {
            do {
                try recorder.start()
                let started = MonoClock.nowNs()
                Task { @MainActor in
                    self.recordStartedNs = started
                    self.micProblem = nil
                }
            } catch let error as AudioRecorderError {
                Task { @MainActor in
                    self.stopWatchdog()
                    self.micProblem = self.message(for: error)
                    self.fail(self.message(for: error))
                }
            } catch {}
        }
    }

    static let micDeniedMessage = UserMessages.microphoneDenied
    private static let micNotAskedMessage = "Utter needs microphone access. Choose Set Up Permissions… in the Utter menu."

    /// A denied permission looks like "no input device" to AVAudioEngine; say which it is.
    private func message(for error: AudioRecorderError) -> String {
        if Permissions.microphoneStatus == .denied || Permissions.microphoneStatus == .restricted {
            return Self.micDeniedMessage
        }
        return error.userMessage
    }

    /// While a hotkey recording runs, check every 250 ms that the key is still
    /// physically down and secure input is off; otherwise release it ourselves.
    /// Also enforces the hard length cap. Menu-started recordings only get the cap.
    private func startWatchdog() {
        stopWatchdog()
        let started = Date()
        let keyCode = CGKeyCode(hotkey.shortcut.keyCode)
        let source = recordingSource
        var keyUpChecks = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                guard let reason = WatchdogPolicy.releaseReason(
                    elapsed: Date().timeIntervalSince(started), maxSeconds: Self.maxRecordingSeconds, source: source,
                    keyDown: CGEventSource.keyState(.combinedSessionState, key: keyCode),
                    secureInput: PasteInserter.secureInputActive, keyUpChecks: &keyUpChecks)
                else { return }
                if reason == "max_length" {
                    self.lastMessage = "Recording stopped after \(Int(Self.maxRecordingSeconds / 60)) minutes."
                }
                Log.error("watchdog released recording reason=\(reason) source=\(source)")
                self.hotkey.forceRelease()
                self.released(KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0, source: source))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func released(_ timing: KeyTiming) {
        guard state == .recording, let press else { return }
        stopWatchdog()
        stopIncrementalFeed()
        state = .transcribing
        let recorder = self.recorder
        audioQueue.async {
            let recording = recorder.stop(releaseNs: timing.callbackNs)
            Task { @MainActor in await self.finish(recording, press: press, release: timing) }
        }
    }

    /// Menu-driven start/stop (same path as the hotkey).
    public func toggleFromMenu() {
        let now = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0, source: .menu)
        if state == .recording { released(now) } else { pressed(now) }
    }

    private func finish(_ recording: Recording, press: KeyTiming, release: KeyTiming) async {
        guard recording.didRecord else {
            // The microphone never started (the failure is already shown); keep that state.
            if state == .transcribing { state = micProblem.map { .failed($0) } ?? .ready }
            return
        }
        if recording.interruptedByDeviceChange {
            lastMessage = recording.continuedOnDevice.map { "The microphone changed while you were speaking; Utter kept listening on \($0)." }
                ?? UserMessages.microphoneDisconnected
            Log.info("dictation device change continued_on=\(recording.continuedOnDevice ?? "none") samples=\(recording.samples.count)")
        }
        let engine = self.engine
        let samples = recording.samples
        let text = textSettings
        let options = dictationOptions(noticeUnsupportedLanguage: true)
        let incremental = self.incremental
        self.incremental = nil
        let result: TranscriptionResult
        do {
            result = try await Task.detached(priority: .userInitiated) { () throws -> TranscriptionResult in
                // A long dictation was already transcribed up to its last pause:
                // only the tail is left (see IncrementalTranscriber).
                if let incremental, incremental.segments > 0 {
                    let r = try incremental.finish(complete: samples)
                    Log.info("incremental segments=\(r.segments) tail_inference_ms=\(Int(r.tailInferenceMs)) total_inference_ms=\(Int(r.totalInferenceMs))")
                    return TranscriptionResult(text: r.text, skipped: r.skipped, language: nil,
                                               audioMs: UInt64(samples.count / 16), inferenceMs: r.tailInferenceMs)
                }
                return try engine.transcribe(pcm: samples, options: options)
            }.value
        } catch let error as CoreError {
            Log.error("transcribe failed: \(error.logDetail)")
            fail(error.userMessage)
            if case .InferenceFailed = error, let id = loadedModelID {
                // A damaged file can load and warm up yet fail every inference.
                // Re-check it; a mismatch shows as damaged with Re-download.
                models.setVerifiedStale(id)
                Task { @MainActor [weak self] in
                    guard let self, await self.models.verify(id) == .damaged, let entry = self.models.entry(id) else { return }
                    let message = "\(entry.name) is damaged. Open the Model Manager and choose Re-download."
                    // A new dictation may have started meanwhile: never change its
                    // state (key-up and the watchdog only act on .recording).
                    if self.isBusyDictating {
                        self.lastMessage = message
                        return
                    }
                    self.fail(message)
                    self.onNeedsModel?()
                }
            }
            return
        } catch {
            fail("Transcription failed. Please try again.")
            return
        }
        let transcribedNs = MonoClock.nowNs()
        // Raw transcript → local stages → optional AI processor → final text.
        // Local-only mode (the default) allows only processors on this Mac.
        let allowed = processorSettings.isLocal || !privacySettings.localOnly
        let settingsForKey = processorSettings
        let processor: (any TextProcessor)? = text.mode.usesProcessor && allowed
            ? await Task.detached { settingsForKey.makeProcessor() }.value // Keychain read off main
            : nil
        if text.mode.usesProcessor, processor == nil, !warnedNoProcessor {
            warnedNoProcessor = true
            lastMessage = allowed
                ? "\(text.mode.title) mode has no AI processor set up, so the cleaned-up text is used. Set one up in Settings → Processing."
                : "Local-only mode is on, so \(text.mode.title) mode uses the cleaned-up text. Change this in Settings → Privacy."
        }
        let pipeline = TextPipeline(settings: text, processor: processor)
        let processed = result.skipped == nil ? await pipeline.run(result.text) : PipelineResult(raw: result.text, final: "", changes: [])
        currentPipeline = processed
        processedNs = MonoClock.nowNs()
        // A lone "um" cleans up to nothing: skip it like silence.
        let skipped = result.skipped.map { "\($0)" } ?? (TranscriptPolicy.isBlank(processed.final) ? "empty" : nil)
        if let skipped {
            logDictation(recording, result, press: press, release: release, transcribedNs: transcribedNs,
                         report: InsertReport(result: .failed("skipped_\(skipped)"), bundleID: nil))
            state = .ready
            if recording.interruptedByDeviceChange, let message = lastMessage {
                overlay.show(.notice(message, recording.continuedOnDevice == nil ? .failed : .unconfirmed))
            }
            return
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard NSWorkspace.shared.frontmostApplication != nil else {
            // Nowhere to type (e.g. every window closed): keep the words.
            Self.putOnClipboard(inserter.settings.finalText(processed.final))
            logDictation(recording, result, press: press, release: release, transcribedNs: transcribedNs,
                         report: InsertReport(result: .copiedToClipboard, bundleID: nil))
            lastMessage = UserMessages.noFocusedApp
            state = .ready
            onAttention?(.unconfirmed)
            overlay.show(.notice(UserMessages.noFocusedApp, .unconfirmed))
            lastPipeline = processed
            recordHistory(processed, recording: recording, app: nil)
            return
        }
        let report = await inserter.insert(processed.final, bundleID: bundleID)
        if let problem = processed.processorProblem {
            lastMessage = problem
            overlay.show(.notice(problem, .unconfirmed))
        }
        // Only text that reached an app or the clipboard can be copied again or kept;
        // a password-field block leaves no trace.
        if HistoryPolicy.shouldRecord(report.result, privacy: PrivacySettings(historyEnabled: true)) {
            lastPipeline = processed
            recordHistory(processed, recording: recording, app: report.bundleID ?? bundleID)
        }
        logDictation(recording, result, press: press, release: release, transcribedNs: transcribedNs, report: report)
        let plan = InsertionOutcome.plan(for: report)
        // Keep the words rather than lose them when they may not have gone in.
        if plan.copyToClipboard {
            Self.putOnClipboard(inserter.settings.finalText(processed.final))
            // On the clipboard now, so it can be copied again (never for a password field).
            if !report.secureFieldFocused { lastPipeline = processed }
        }
        if let failure = plan.failure {
            fail(failure)
            return
        }
        if let message = plan.message { lastMessage = message }
        state = .ready
        if let cue = plan.cue {
            onAttention?(cue)
            if let message = plan.message { overlay.show(.notice(message, cue)) }
        } else if recording.interruptedByDeviceChange, let message = lastMessage {
            // Say where the user is looking that the microphone changed.
            overlay.show(.notice(message, recording.continuedOnDevice == nil ? .failed : .unconfirmed))
        }
    }

    private static func putOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One line per dictation with every stage, so latency can be read from the log.
    private func logDictation(_ rec: Recording, _ result: TranscriptionResult, press: KeyTiming, release: KeyTiming, transcribedNs: UInt64, report: InsertReport) {
        let doneNs = MonoClock.nowNs()
        func ms(_ from: UInt64, _ to: UInt64?) -> String {
            guard let to else { return "n/a" }
            return String(format: "%.1f", MonoClock.ms(from: from, to: to))
        }
        let t = report.paste ?? InsertTiming()
        let fields: [(String, String)] = [
            ("model", loadedModelID ?? "n/a"),
            ("mode", mode.rawValue),
            ("audio_ms", "\(result.audioMs)"),
            // HID event → our tap callback (the part of key-down latency before Utter runs).
            ("event_to_callback_ms", MonoClock.eventNs(press.eventTimestamp, before: press.callbackNs).map { ms($0, press.callbackNs) } ?? "n/a"),
            ("keydown_to_record_started_ms", recordStartedNs == 0 ? "n/a" : ms(press.callbackNs, recordStartedNs)),
            ("keydown_to_overlay_ms", overlayShownNs == 0 ? "n/a" : ms(press.callbackNs, overlayShownNs)),
            // Keep Microphone Ready: audio from before the key-down included in the recording.
            ("pre_roll_ms", String(format: "%.0f", rec.preRollMs)),
            ("device_changed", "\(rec.interruptedByDeviceChange)"),
            ("keydown_to_first_sample_ms", ms(press.callbackNs, rec.firstSampleNs)),
            ("keydown_to_first_callback_ms", ms(press.callbackNs, rec.firstCallbackNs)),
            ("release_to_last_sample_end_ms", ms(release.callbackNs, rec.lastSampleEndNs)),
            ("release_to_transcribed_ms", ms(release.callbackNs, transcribedNs)),
            ("text_mode", textSettings.mode.rawValue),
            ("processing_ms", processedNs >= transcribedNs ? ms(transcribedNs, processedNs) : "n/a"),
            ("text_changes", "\(currentPipeline?.changes.count ?? 0)"),
            ("processor", currentPipeline?.processor.map { "\"\($0)\"" } ?? "none"),
            ("inference_ms", String(format: "%.1f", result.inferenceMs)),
            ("release_to_paste_sent_ms", t.pasteSentNs == nil ? "n/a" : ms(release.callbackNs, t.pasteSentNs)),
            ("release_to_target_read_ms", ms(release.callbackNs, t.firstReadNs)),
            ("release_to_restored_ms", ms(release.callbackNs, t.restoredNs)),
            ("snapshot_ms", String(format: "%.1f", t.snapshotMs)),
            ("reads", "\(t.reads)"),
            ("clipboard_readable", "\(t.clipboardReadable)"),
            ("dropped_frames", "\(rec.droppedFrames)"),
            ("key_event_ts", "\(press.eventTimestamp)"),
            ("key_callback_ns", "\(press.callbackNs)"),
            ("release_to_insert_done_ms", ms(release.callbackNs, doneNs)),
            ("front_app", report.bundleID ?? "n/a"),
            ("chars", "\(result.text.count)"),
            ("result", "\(report.result)".replacingOccurrences(of: " ", with: "_")),
            ("attempts", "\"" + report.attempts.joined(separator: "; ") + "\""),
            ("load_count", "\(engine.loadCount())"),
        ]
        Log.info("dictation " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    private func fail(_ message: String) {
        lastMessage = message
        state = .failed(message)
        Log.error("user-facing error: \(message)")
    }
}

extension CoreError {
    /// Plain-English text for the UI. (The generated `errorDescription` is a debug
    /// dump, so never show `localizedDescription` for these errors.)
    public var userMessage: String {
        switch self {
        case .ModelMissing(let m, _), .ModelCorrupt(let m, _), .ModelUnsupported(let m, _), .InsufficientMemory(let m, _),
             .ModelNotLoaded(let m, _), .InferenceFailed(let m, _), .InputTooLong(let m, _), .AudioRead(let m, _),
             .LanguageUnsupported(let m, _),
             .DownloadFailed(let m, _):
            return m
        }
    }

    /// Technical detail for the log; never shown to users.
    public var logDetail: String {
        switch self {
        case .ModelMissing(_, let d), .ModelCorrupt(_, let d), .ModelUnsupported(_, let d), .InsufficientMemory(_, let d),
             .ModelNotLoaded(_, let d), .InferenceFailed(_, let d), .InputTooLong(_, let d), .AudioRead(_, let d),
             .LanguageUnsupported(_, let d),
             .DownloadFailed(_, let d):
            return d
        }
    }
}

/// Latest model-load request number, readable from the load queue.
final class LoadTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; current += 1; return current }
    func isCurrent(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return current == ticket }
}
