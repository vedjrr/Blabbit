import AVFoundation
import Foundation
import Testing
@testable import BlabbitKit

@Suite struct HistoryTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blabbit-history-\(UUID().uuidString)")

    func entry(_ final: String, raw: String? = nil, minutesAgo: Double = 0) -> HistoryEntry {
        HistoryEntry(createdAt: Date().addingTimeInterval(-minutesAgo * 60), durationMs: 4600, model: "parakeet-tdt-0.6b-v3",
                     mode: "clean", raw: raw ?? final, final: final, app: "com.apple.TextEdit")
    }

    @Test func storesSearchesAndDeletes() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let a = try store.add(entry("HoldMyCode uses PostgreSQL.", raw: "hold my code uses post gur SQL", minutesAgo: 2))
        let b = try store.add(entry("Schedule a meeting on Tuesday.", minutesAgo: 1))
        _ = try store.add(entry("We moved the backend to TypeScript."))
        #expect(try store.count() == 3)
        #expect(try store.entries().map(\.final).first == "We moved the backend to TypeScript.", "newest first")
        #expect(try store.entries(matching: "postgres").map(\.id) == [a.id], "prefix search on final text")
        #expect(try store.entries(matching: "gur").map(\.id) == [a.id], "raw text is searchable too")
        #expect(try store.entries(matching: "tues meet").map(\.id) == [b.id], "all words must match")
        #expect(try store.entries(matching: "nothing-like-this").isEmpty)
        try store.delete(id: try #require(a.id))
        #expect(try store.count() == 2 && store.entries(matching: "postgres").isEmpty)
        // Reopening keeps data and doesn't re-run the migration.
        let reopened = try HistoryStore(directory: dir)
        #expect(try reopened.count() == 2)
        try reopened.deleteAll()
        #expect(try reopened.count() == 0 && reopened.entries(matching: "meeting").isEmpty)
    }

    @Test func audioIsKeptOnlyWhenSavedAndGoesWithItsEntry() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let tone = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 }
        let name = try store.saveAudio(tone)
        let url = store.audioDirectory.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1 && file.length == 16_000)
        var e = entry("with audio")
        e.audioFile = name
        let saved = try store.add(e)
        try store.delete(id: try #require(saved.id))
        #expect(!FileManager.default.fileExists(atPath: url.path), "deleting the entry deletes its audio")

        _ = try store.add(entry("no audio"))
        let second = try store.saveAudio(tone)
        try store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent(second).path))
    }

    @Test func whatIsKept() {
        let on = PrivacySettings()
        let off = PrivacySettings(historyEnabled: false)
        let audioOn = PrivacySettings(keepAudio: true)
        for kept in [InsertReport.Result.inserted(.paste), .unverified(.accessibility), .copiedToClipboard, .handledByScript] {
            #expect(HistoryPolicy.shouldRecord(kept, privacy: on), "\(kept)")
            #expect(!HistoryPolicy.shouldRecord(kept, privacy: off), "history off keeps nothing")
        }
        for dropped in [InsertReport.Result.blockedBySecureInput, .failed("x"), .skipped] {
            #expect(!HistoryPolicy.shouldRecord(dropped, privacy: on), "\(dropped) leaves no trace")
        }
        let samples: [Float] = [0.1, 0.2]
        #expect(HistoryPolicy.audioToKeep(samples, privacy: on) == nil, "no audio unless enabled")
        #expect(HistoryPolicy.audioToKeep(samples, privacy: audioOn) == samples)
        #expect(HistoryPolicy.audioToKeep(samples, privacy: PrivacySettings(historyEnabled: false, keepAudio: true)) == nil)
    }

    @Test func privacyDefaults() throws {
        let suite = "dev.blabbit.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = PrivacySettings.load(from: defaults)
        #expect(p.historyEnabled && !p.keepAudio && p.localOnly, "history on, no audio kept, local-only by default")
        var changed = p
        changed.historyEnabled = false
        changed.save(to: defaults)
        #expect(PrivacySettings.load(from: defaults) == changed)
    }
}
