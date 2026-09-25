import AppKit
import SwiftUI
import Testing
import UtterCore
@testable import UtterKit

/// Uses a temporary models folder and sparse files of the exact catalog size,
/// so no network or real model is needed.
@MainActor @Suite struct ModelManagerTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utter-models-\(UUID().uuidString)")
    let suite = "dev.utter.test.\(UUID().uuidString)"

    func install(_ entry: ModelEntry, size: UInt64? = nil) throws {
        let folder = dir.appendingPathComponent(entry.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(URL(fileURLWithPath: try modelPath(modelsDir: dir.path, id: entry.id)).lastPathComponent)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size ?? entry.sizeBytes) // sparse: no real disk use
        try handle.close()
    }

    func makeManager() throws -> (ModelManager, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (ModelManager(modelsDirectory: dir, defaults: defaults), defaults)
    }

    @Test func catalogHasAllVerifiedModelsAndRecommendsParakeet() throws {
        let (m, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite) }
        // The G3 models and other families, plus a smaller Q4_K_M file for 7 of them (PARITY C6).
        #expect(m.entries.filter { $0.variantOf == nil }.count == 15) // 8 G3 + 7 more families (C17)
        #expect(m.entries.filter { $0.variantOf != nil }.count == 7)
        #expect(m.variants(of: "parakeet-tdt-0.6b-v3").map(\.quant) == ["Q4_K_M"])
        #expect(m.defaultModelID == "parakeet-tdt-0.6b-v3")
        #expect(m.entries.allSatisfy { m.status[$0.id] == .notInstalled })
        #expect(m.entries.allSatisfy { $0.measuredWer > 0 && $0.measuredP50Ms > 0 })
    }

    @Test func installedStateSwitchingAndDeleteRules() throws {
        let (m, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let parakeet = try #require(m.entry("parakeet-tdt-0.6b-v3"))
        let moonshine = try #require(m.entry("moonshine-base"))
        try install(parakeet)
        try install(moonshine)
        try install(try #require(m.entry("whisper-small")), size: 10) // truncated: not installed
        m.refresh()
        #expect(m.status[parakeet.id] == .installed)
        #expect(m.status["whisper-small"] == .notInstalled)
        #expect(Set(m.installedEntries.map(\.id)) == [parakeet.id, moonshine.id])

        var switched: [String] = []
        m.onDefaultModelChange = { switched.append($0) }
        m.setDefault("whisper-small") // not installed: refused
        #expect(m.defaultModelID == parakeet.id)
        m.setDefault(moonshine.id)
        #expect(m.defaultModelID == moonshine.id && switched == [moonshine.id])
        // Saved only once the controller reports a successful load.
        #expect(d.string(forKey: ModelManager.defaultModelKey) == nil)
        m.commitDefault(moonshine.id)
        #expect(d.string(forKey: ModelManager.defaultModelKey) == moonshine.id)
        // A failed switch goes back to the last model that loaded.
        m.setDefault(parakeet.id)
        #expect(m.defaultModelID == parakeet.id)
        m.revertDefault()
        #expect(m.defaultModelID == moonshine.id)

        m.delete(moonshine.id) // the model in use can't be deleted
        #expect(m.status[moonshine.id] == .installed)
        m.delete(parakeet.id)
        #expect(m.status[parakeet.id] == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(parakeet.id).path))
    }

    @Test func licenceAcceptanceIsRequiredOnceAndPersisted() throws {
        let (m, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite) }
        #expect(m.needsLicenseAcceptance("SenseVoiceSmall"))
        #expect(!m.needsLicenseAcceptance("whisper-small"))
        m.download("SenseVoiceSmall") // refused until accepted
        #expect(m.status["SenseVoiceSmall"] == .notInstalled)
        m.acceptLicense("SenseVoiceSmall")
        #expect(!m.needsLicenseAcceptance("SenseVoiceSmall"))
        let reloaded = ModelManager(modelsDirectory: dir, defaults: d)
        #expect(!reloaded.needsLicenseAcceptance("SenseVoiceSmall"))
    }

    @Test func damagedModelShowsErrorAndRefreshKeepsIt() throws {
        let (m, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        // A damaged file usually has the right size, so a size check alone says "installed".
        try install(try #require(m.entry("moonshine-base")))
        m.refresh()
        #expect(m.status["moonshine-base"] == .installed)
        m.markDamaged("moonshine-base", message: "Moonshine Base is damaged or incomplete.")
        m.refresh() // what opening the Model Manager does
        #expect(m.status["moonshine-base"] == .failed("Moonshine Base is damaged or incomplete."))
        #expect(!m.installedEntries.contains { $0.id == "moonshine-base" })
        let reopened = ModelManager(modelsDirectory: dir, defaults: d)
        #expect(reopened.status["moonshine-base"] == .installed, "damage is re-detected by verification, not persisted")
        #expect(!reopened.isVerified("moonshine-base"))
    }

    @Test func corruptFileOfTheRightSizeFailsVerification() async throws {
        let (m, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        try install(try #require(m.entry("moonshine-base"))) // right size, all zeros
        #expect(!m.isVerified("moonshine-base"))
        #expect(await m.verify("moonshine-base") == .damaged)
        guard case .failed(let message) = m.status["moonshine-base"] else {
            Issue.record("expected a damaged status, got \(String(describing: m.status["moonshine-base"]))"); return
        }
        #expect(message.contains("Re-download"))
        #expect(m.isDamaged("moonshine-base") && !m.isVerified("moonshine-base"))
        // "Couldn't check" is not "damaged".
        #expect(await m.verify("not-a-model") == .notChecked)
    }

    @Test func realModelVerifiesOnceAndStaysVerified() async throws {
        let real = ModelLocation.modelsDirectory
        let (_, d) = try makeManager()
        defer { d.removePersistentDomain(forName: suite) }
        let m = ModelManager(modelsDirectory: real, defaults: d)
        try #require(m.status["moonshine-base"] == .installed, "run `make models` first")
        #expect(!m.isVerified("moonshine-base"))
        #expect(await m.verify("moonshine-base") == .good)
        #expect(m.isVerified("moonshine-base") && m.status["moonshine-base"] == .installed)
        let reopened = ModelManager(modelsDirectory: real, defaults: d)
        #expect(reopened.isVerified("moonshine-base"), "the stamp persists, so the check doesn't repeat every launch")
    }

    /// The whole Swift download path against a local server serving the real
    /// Moonshine file: progress, pause, Cancel on a paused row, download,
    /// verify-and-install, Re-download.
    @Test(.timeLimit(.minutes(2)))
    func downloadPauseCancelAndInstallThroughTheManager() async throws {
        let probeDefaults = try #require(UserDefaults(suiteName: suite))
        let source = try #require(ModelManager(modelsDirectory: ModelLocation.modelsDirectory, defaults: probeDefaults).path(for: "moonshine-base"))
        try #require(FileManager.default.fileExists(atPath: source), "run `make models` first")
        let server = try LocalModelServer(serving: URL(fileURLWithPath: source))
        defer { server.stop() }
        server.delayPerChunk = 0.01 // ~3 s for 77 MB: time to pause
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let m = ModelManager(modelsDirectory: dir, defaults: defaults, hubEndpoint: server.endpoint)
        let id = "moonshine-base"

        func waitFor(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            try #require(condition(), "timed out waiting for \(what); status \(String(describing: m.status[id]))")
        }

        m.download(id)
        try await waitFor("progress") { if case .downloading(let got, _) = m.status[id] { got > 5_000_000 } else { false } }
        m.pause(id)
        try await waitFor("pause") { if case .partial = m.status[id] { true } else { false } }
        m.cancel(id) // on the paused row: discards the partial file
        #expect(m.status[id] == .notInstalled)
        m.refresh()
        #expect(m.status[id] == .notInstalled, "the partial file is gone")

        server.delayPerChunk = 0
        m.download(id)
        try await waitFor("install") { m.status[id] == .installed }
        #expect(m.isVerified(id), "the downloader checked the SHA-256")
        #expect(server.ranges.first == .some(nil))

        m.markDamaged(id, message: "damaged")
        m.redownload(id)
        try await waitFor("re-download") { m.status[id] == .installed }
        #expect(!m.isDamaged(id))
    }
}

@Suite struct ModelSwitchTests {
    @Test func switchesWaitForTheDictationToFinish() {
        #expect(DictationController.defersModelSwitch(in: .recording))
        #expect(DictationController.defersModelSwitch(in: .transcribing))
        for idle: DictationController.State in [.ready, .starting, .loadingModel, .failed("x")] {
            #expect(!DictationController.defersModelSwitch(in: idle))
        }
    }

    @Test func onlyTheLatestLoadRequestCounts() {
        let ticket = LoadTicket()
        let a = ticket.next()
        let b = ticket.next()
        #expect(!ticket.isCurrent(a), "a superseded load must not start or update the UI")
        #expect(ticket.isCurrent(b))
    }
}

/// Renders the real Model Manager view offscreen (no Screen Recording
/// permission needed). With `UTTER_SNAPSHOT_DIR` set, the PNG is kept as evidence.
@MainActor @Suite struct ModelManagerSnapshotTests {
    @Test func rendersWithTheInstalledModels() throws {
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ModelManager(modelsDirectory: ModelLocation.modelsDirectory, defaults: defaults)
        let view = ModelManagerView(manager: manager).frame(width: 706, height: 580)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 1412 && image.height == 1160)
        try save(image, "model_manager_view.png")

        // `List` can't be drawn offscreen, so also render every row directly: the
        // real status of each installed model, plus each other state a row can show.
        let samples: [ModelManager.Status] = [
            .downloading(downloaded: 180_000_000, total: 640_000_000), .partial(320_000_000), .verifying,
            .failed("The downloaded file is damaged (checksum mismatch)."), .notInstalled,
        ]
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(manager.entries.enumerated()), id: \.offset) { index, entry in
                let real = manager.status[entry.id] ?? .notInstalled
                ModelRow(entry: entry, status: index < 3 ? real : samples[(index - 3) % samples.count],
                         isDefault: entry.id == manager.defaultModelID, action: { _ in })
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
        }.frame(width: 706).background(Color.white)
        let rowRenderer = ImageRenderer(content: rows)
        rowRenderer.scale = 2
        let rowImage = try #require(rowRenderer.cgImage)
        #expect(rowImage.height > 400)
        try save(rowImage, "model_manager_rows.png")
    }

    func save(_ image: CGImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["UTTER_SNAPSHOT_DIR"] else { return }
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}

/// PARITY C11: the compute device choice persists and asks for a reload.
@MainActor @Suite struct ComputeDeviceTests {
    @Test func choicePersistsAndReloads() throws {
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = ModelManager(modelsDirectory: ModelLocation.modelsDirectory, defaults: defaults)
        #expect(m.computeDevice == .auto)
        var reloads = 0
        m.onComputeDeviceChange = { reloads += 1 }
        m.computeDevice = .cpu
        m.computeDevice = .cpu
        #expect(reloads == 1, "no reload when nothing changed")
        #expect(ModelManager(modelsDirectory: ModelLocation.modelsDirectory, defaults: defaults).computeDevice == .cpu)
    }
}

/// PARITY C7: your own GGUF file, added, listed, and transcribing for real.
@MainActor @Suite struct CustomModelTests {
    @Test func addedFileIsListedAndTranscribes() throws {
        let source = ModelLocation.modelsDirectory.appendingPathComponent("moonshine-base/moonshine-base-Q8_0.gguf")
        try #require(FileManager.default.fileExists(atPath: source.path), "run make models")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utter-custom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = ModelManager(modelsDirectory: dir, defaults: defaults)
        let catalogCount = m.entries.count

        // Not a model: refused with a plain message, nothing added.
        let text = dir.appendingPathComponent("notes.gguf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: text)
        #expect(m.addModelFile(text)?.contains("isn't a GGUF model") == true)
        #expect(m.entries.count == catalogCount)

        #expect(m.addModelFile(source) == nil)
        let id = "custom:moonshine-base-Q8_0.gguf"
        let entry = try #require(m.entry(id))
        #expect(entry.family == "moonshine" && entry.measuredRtf == 0)
        #expect(m.status[id] == .installed && m.isVerified(id))
        #expect(m.installedEntries.contains(entry))
        #expect(m.addModelFile(source)?.contains("already added") == true)

        // It really runs.
        let engine = UtterEngine()
        _ = try engine.loadModel(path: try #require(m.path(for: id)))
        let wav = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fixtures/audio/tts_01.wav").standardized
        let clip = try loadWav16kMono(path: wav.path)
        let result = try engine.transcribe(pcm: clip, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: false))
        #expect(result.text.split(separator: " ").count > 3, "\(result.text)")
        // A new manager (next launch) finds it in the Custom folder.
        #expect(ModelManager(modelsDirectory: dir, defaults: defaults).entry(id) != nil)
    }
}
