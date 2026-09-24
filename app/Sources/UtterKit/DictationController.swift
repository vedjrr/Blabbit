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
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?
    public private(set) var modelName = ModelLocation.defaultModelName
    public private(set) var lastMessage: String?
    /// Set when the background load completes; never queried from Rust on main.
    public private(set) var modelLoaded = false

    public let hotkey = HotkeyMonitor()
    /// Mic start/stop and resampling run here so neither the event-tap thread
    /// nor the main thread blocks on audio.
    private let audioQueue = DispatchQueue(label: "dev.utter.audio", qos: .userInteractive)
    private lazy var recorder = AudioRecorder(queue: audioQueue)
    private let engine = UtterEngine()
    private let inserter = PasteInserter()
    private var press: KeyTiming?
    private var recordStartedNs: UInt64 = 0

    public init() {}

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
            Task { @MainActor in self?.pressed(timing) }
        }
        hotkey.onRelease = { [weak self] timing in
            Task { @MainActor in self?.released(timing) }
        }
        startHotkey()
        Task {
            if await Permissions.requestMicrophone() {
                let recorder = self.recorder
                audioQueue.async {
                    do { try recorder.prepare() } catch let error as AudioRecorderError {
                        Task { @MainActor in self.fail(error.userMessage) }
                    } catch {}
                }
            } else {
                fail("Utter needs microphone access. Allow it in System Settings → Privacy & Security → Microphone.")
            }
        }
        loadModel()
    }

    public func startHotkey() {
        guard !hotkey.isRunning else { return }
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        do {
            try hotkey.start()
            if lastMessage == HotkeyError.tapCreationFailed.userMessage { lastMessage = nil }
        } catch let error as HotkeyError {
            Log.error("hotkey start failed: \(error)")
            lastMessage = error.userMessage
            onStateChange?(state)
        } catch {}
    }

    private func loadModel() {
        let url = ModelLocation.defaultModelURL
        state = .loadingModel
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let started = MonoClock.nowNs()
            do {
                let info = try engine.loadModel(path: url.path)
                Log.info(String(format: "model_load model=%@ load_ms=%.0f warmup_ms=%.0f footprint_mb=%.0f total_ms=%.0f load_count=%llu",
                                url.lastPathComponent, info.loadMs, info.warmupMs,
                                Double(info.footprintAfterBytes) / 1_048_576,
                                MonoClock.ms(from: started, to: MonoClock.nowNs()), engine.loadCount()))
                await MainActor.run {
                    self.modelLoaded = true
                    self.state = .ready
                }
            } catch let error as CoreError {
                Log.error("model load failed: \(error.logDetail)")
                let message = error.userMessage + (FileManager.default.fileExists(atPath: url.path) ? "" : " (expected at \(url.path))")
                await MainActor.run { self.fail(message) }
            } catch {
                await MainActor.run { self.fail("The speech model could not be loaded.") }
            }
        }
    }

    // MARK: Recording lifecycle

    private func pressed(_ timing: KeyTiming) {
        guard acceptsPress else {
            if state == .loadingModel { lastMessage = "\(modelName) is still loading. Try again in a moment." }
            Log.info("press ignored state=\(state)")
            return
        }
        press = timing
        state = .recording
        let recorder = self.recorder
        audioQueue.async {
            do {
                try recorder.start()
                let started = MonoClock.nowNs()
                Task { @MainActor in self.recordStartedNs = started }
            } catch let error as AudioRecorderError {
                Task { @MainActor in self.fail(error.userMessage) }
            } catch {}
        }
    }

    private func released(_ timing: KeyTiming) {
        guard state == .recording, let press else { return }
        state = .transcribing
        let recorder = self.recorder
        audioQueue.async {
            let recording = recorder.stop(releaseNs: timing.callbackNs)
            Task { @MainActor in await self.finish(recording, press: press, release: timing) }
        }
    }

    /// Menu-driven start/stop (same path as the hotkey).
    public func toggleFromMenu() {
        let now = KeyTiming(callbackNs: MonoClock.nowNs(), eventTimestamp: 0)
        if state == .recording { released(now) } else { pressed(now) }
    }

    private func finish(_ recording: Recording, press: KeyTiming, release: KeyTiming) async {
        let engine = self.engine
        let samples = recording.samples
        let result: TranscriptionResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try engine.transcribe(pcm: samples, options: DictationOptions(language: nil, translate: false, initialPrompt: nil))
            }.value
        } catch let error as CoreError {
            Log.error("transcribe failed: \(error.logDetail)")
            fail(error.userMessage)
            return
        } catch {
            fail("Transcription failed. Please try again.")
            return
        }
        let transcribedNs = MonoClock.nowNs()
        if let skipped = result.skipped {
            logDictation(recording, result, press: press, release: release, transcribedNs: transcribedNs, outcome: "skipped_\(skipped)")
            state = .ready
            return
        }
        let outcome = await inserter.insert(result.text)
        logDictation(recording, result, press: press, release: release, transcribedNs: transcribedNs, outcome: "\(outcome)")
        switch outcome {
        case .pasted:
            if !inserter.lastTiming.clipboardReadable {
                lastMessage = "macOS did not let Utter read the clipboard, so the transcript was left on it. Allow Utter under System Settings → Privacy & Security → Paste from Other Apps."
            }
            state = .ready
        case .blockedBySecureInput:
            lastMessage = "A password field is active, so Utter did not type anything."
            state = .ready
        case .failed(let message): fail(message)
        }
    }

    /// One line per dictation with every stage, so latency can be read from the log.
    private func logDictation(_ rec: Recording, _ result: TranscriptionResult, press: KeyTiming, release: KeyTiming, transcribedNs: UInt64, outcome: String) {
        func ms(_ from: UInt64, _ to: UInt64?) -> String {
            guard let to else { return "n/a" }
            return String(format: "%.1f", MonoClock.ms(from: from, to: to))
        }
        let t = inserter.lastTiming
        let fields: [(String, String)] = [
            ("audio_ms", "\(result.audioMs)"),
            ("keydown_to_record_started_ms", ms(press.callbackNs, recordStartedNs)),
            ("keydown_to_first_sample_ms", ms(press.callbackNs, rec.firstSampleNs)),
            ("keydown_to_first_callback_ms", ms(press.callbackNs, rec.firstCallbackNs)),
            ("release_to_last_sample_end_ms", ms(release.callbackNs, rec.lastSampleEndNs)),
            ("release_to_transcribed_ms", ms(release.callbackNs, transcribedNs)),
            ("inference_ms", String(format: "%.1f", result.inferenceMs)),
            ("release_to_paste_sent_ms", ms(release.callbackNs, t.pasteSentNs)),
            ("release_to_target_read_ms", ms(release.callbackNs, t.firstReadNs)),
            ("release_to_restored_ms", ms(release.callbackNs, t.restoredNs)),
            ("snapshot_ms", String(format: "%.1f", t.snapshotMs)),
            ("reads", "\(t.reads)"),
            ("clipboard_readable", "\(t.clipboardReadable)"),
            ("dropped_frames", "\(rec.droppedFrames)"),
            ("key_event_ts", "\(press.eventTimestamp)"),
            ("key_callback_ns", "\(press.callbackNs)"),
            ("front_app", t.frontmostBundleID ?? "n/a"),
            ("chars", "\(result.text.count)"),
            ("outcome", outcome),
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
             .ModelNotLoaded(let m, _), .InferenceFailed(let m, _), .InputTooLong(let m, _), .AudioRead(let m, _):
            return m
        }
    }

    /// Technical detail for the log; never shown to users.
    public var logDetail: String {
        switch self {
        case .ModelMissing(_, let d), .ModelCorrupt(_, let d), .ModelUnsupported(_, let d), .InsufficientMemory(_, let d),
             .ModelNotLoaded(_, let d), .InferenceFailed(_, let d), .InputTooLong(_, let d), .AudioRead(_, let d):
            return d
        }
    }
}
