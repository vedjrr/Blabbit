import Foundation
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
        #expect(m.entries.count == 8)
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
        #expect(d.string(forKey: ModelManager.defaultModelKey) == moonshine.id)

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
        defer { d.removePersistentDomain(forName: suite) }
        m.markDamaged("moonshine-base", message: "Moonshine Base is damaged or incomplete.")
        m.refresh()
        #expect(m.status["moonshine-base"] == .failed("Moonshine Base is damaged or incomplete."))
    }
}
