import AppKit
import UtterCore

/// Coordinates hotkey → microphone → local model → text insertion (ADR-008).
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

    public let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let engine = UtterEngine()
    private let inserter = PasteInserter()
    /// Mic start/stop happen here so the event-tap thread never blocks.
    private let audioQueue = DispatchQueue(label: "dev.utter.audio", qos: .userInteractive)
    private var pressNs: UInt64 = 0

    public init() {}

    public var modelLoaded: Bool { engine.isLoaded() }

    public func launch() {
        Log.info("launch pid=\(ProcessInfo.processInfo.processIdentifier) core=\(coreVersion())")
        hotkey.onPress = { [weak self] ns in self?.pressed(at: ns) }
        hotkey.onRelease = { [weak self] ns in self?.released(at: ns) }
        startHotkey()
        Task {
            if await Permissions.requestMicrophone() {
                do { try recorder.prepare() } catch let error as AudioRecorderError { fail(error.userMessage) } catch {}
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
                await MainActor.run { self.state = .ready }
            } catch let error as CoreError {
                Log.error("model load failed: \(error.logDetail)")
                let message = error.userMessage + (FileManager.default.fileExists(atPath: url.path) ? "" : " (expected at \(url.path))")
                await MainActor.run { self.fail(message) }
            } catch {
                await MainActor.run { self.fail("The speech model could not be loaded.") }
            }
        }
    }

    // MARK: Recording lifecycle (tap thread → audio queue → main actor)

    private nonisolated func pressed(at ns: UInt64) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.start()
                let started = MonoClock.nowNs()
                Task { @MainActor in
                    self.pressNs = ns
                    self.state = .recording
                    Log.info(String(format: "record_start keydown_to_engine_started_ms=%.1f", MonoClock.ms(from: ns, to: started)))
                }
            } catch let error as AudioRecorderError {
                Task { @MainActor in self.fail(error.userMessage) }
            } catch {}
        }
    }

    private nonisolated func released(at ns: UInt64) {
        audioQueue.async { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            let recording = self.recorder.stop()
            Task { @MainActor in await self.finish(recording, releaseNs: ns) }
        }
    }

    /// Menu-driven start/stop (same path as the hotkey).
    public func toggleFromMenu() {
        if state == .recording { released(at: MonoClock.nowNs()) } else { pressed(at: MonoClock.nowNs()) }
    }

    private func finish(_ recording: Recording, releaseNs: UInt64) async {
        let captureMs = recording.firstSampleNs.map { MonoClock.ms(from: pressNs, to: $0) }
        guard engine.isLoaded() else {
            state = .failed("The speech model is still loading. Try again in a moment.")
            return
        }
        state = .transcribing
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
            Log.info(String(format: "dictation skipped=%@ audio_ms=%llu", "\(skipped)", result.audioMs))
            state = .ready
            return
        }
        let outcome = await inserter.insert(result.text)
        let doneNs = MonoClock.nowNs()
        Log.info(String(format: "dictation audio_ms=%llu keydown_to_first_sample_ms=%@ release_to_transcribed_ms=%.0f inference_ms=%.0f release_to_insert_done_ms=%.0f chars=%d outcome=%@ load_count=%llu",
                        result.audioMs, captureMs.map { String(format: "%.1f", $0) } ?? "n/a",
                        MonoClock.ms(from: releaseNs, to: transcribedNs), result.inferenceMs,
                        MonoClock.ms(from: releaseNs, to: doneNs), result.text.count, "\(outcome)", engine.loadCount()))
        switch outcome {
        case .pasted: state = .ready
        case .blockedBySecureInput:
            lastMessage = "A password field is active, so Utter did not type anything."
            state = .ready
        case .failed(let message): fail(message)
        }
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
