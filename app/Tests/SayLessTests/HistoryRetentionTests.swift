import Foundation
import GRDB
import Testing
import SayLessCore
@testable import SayLessKit

/// Starred entries, retry from kept audio, history limit and retention (PARITY E3 E4 E6).
@Suite struct HistoryRetentionTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-history-\(UUID().uuidString)")

    func entry(_ final: String, daysAgo: Double = 0, audio: String? = nil) -> HistoryEntry {
        HistoryEntry(createdAt: Date().addingTimeInterval(-daysAgo * 86_400), durationMs: 4600, model: "parakeet-tdt-0.6b-v3",
                     mode: "clean", raw: final, final: final, audioFile: audio)
    }

    @Test func aHistoryFromBeforeStarsIsMigrated() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A v1 database as M5 wrote it, with one dictation.
        let old = try DatabaseQueue(path: dir.appendingPathComponent("history.sqlite").path)
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictation (id INTEGER PRIMARY KEY AUTOINCREMENT, createdAt DATETIME NOT NULL, durationMs DOUBLE NOT NULL,
                  model TEXT NOT NULL, mode TEXT NOT NULL, raw TEXT NOT NULL, final TEXT NOT NULL, app TEXT, audioFile TEXT);
                INSERT INTO dictation (createdAt, durationMs, model, mode, raw, final) VALUES ('2026-09-20 10:00:00.000', 4000, 'm', 'clean', 'r', 'Old one.');
                """)
        }
        try v1.migrate(old)
        try old.close()
        let store = try HistoryStore(directory: dir)
        let entries = try store.entries()
        #expect(entries.map(\.final) == ["Old one."] && entries.first?.saved == false)
    }

    @Test func theLimitKeepsTheNewestAndEveryStarredOne() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let audio = try store.saveAudio([Float](repeating: 0.1, count: 1600))
        let oldest = try store.add(entry("oldest, with audio", daysAgo: 5, audio: audio))
        let starred = try store.add(entry("starred", daysAgo: 4))
        try store.setSaved(id: try #require(starred.id), true)
        for i in 0..<4 { try store.add(entry("recent \(i)", daysAgo: Double(3 - i))) }
        var privacy = PrivacySettings()
        #expect(try store.prune(privacy) == 0, "forever keeps everything")
        privacy.retention = .limit
        privacy.historyLimit = 3
        #expect(try store.prune(privacy) == 2) // oldest + recent 0
        let left = try store.entries().map(\.final)
        #expect(left == ["recent 3", "recent 2", "recent 1", "starred"])
        #expect(try store.entry(id: try #require(oldest.id)) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent(audio).path), "its audio went too")
    }

    @Test func retentionRemovesOldUnstarredDictations() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        try store.add(entry("yesterday", daysAgo: 1))
        try store.add(entry("last week", daysAgo: 8))
        let kept = try store.add(entry("starred, last month", daysAgo: 30))
        try store.setSaved(id: try #require(kept.id), true)
        try store.add(entry("last month", daysAgo: 30))
        var privacy = PrivacySettings()
        privacy.retention = .weeks2
        #expect(try store.prune(privacy) == 1)
        privacy.retention = .days3
        #expect(try store.prune(privacy) == 1)
        #expect(try store.entries().map(\.final) == ["yesterday", "starred, last month"])
        #expect(HistoryRetention.months3.cutoff(now: Date(timeIntervalSince1970: 90 * 86_400)) == Date(timeIntervalSince1970: 0))
    }

    @Test func oldPrivacySettingsStillLoad() throws {
        let decoded = try JSONDecoder().decode(PrivacySettings.self, from: Data(#"{"historyEnabled":true,"keepAudio":true,"localOnly":false}"#.utf8))
        #expect(decoded.keepAudio && !decoded.localOnly && decoded.retention == .forever && decoded.historyLimit == 100)
    }

    @Test func keptAudioReadsBackExactly() throws {
        let samples: [Float] = (0..<3200).map { Float(sin(Double($0) * 0.05)) * 0.6 }
        let back = try #require(WAV.decode16kMono(WAV.encode16kMono(samples)))
        #expect(back.count == samples.count)
        #expect(zip(samples, back).allSatisfy { abs($0 - $1) < 1.0 / 16_000 })
        #expect(WAV.decode16kMono(Data("not a wav".utf8)) == nil)
    }

    /// E4 end to end below the UI: kept audio → the real model → updated entry.
    @Test func aKeptRecordingTranscribesAgainAndUpdatesItsEntry() throws {
        let modelPath = ModelLocation.defaultModelURL.path
        try #require(FileManager.default.fileExists(atPath: modelPath), "run `make models` first")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (samples, reference) = try EngineBridgeTests().loadFixture("tts_03")
        let store = try HistoryStore(directory: dir)
        let name = try store.saveAudio(samples)
        let saved = try store.add(HistoryEntry(durationMs: 4600, model: "whisper-small", mode: "clean", raw: "old", final: "Old.", audioFile: name))
        let id = try #require(saved.id)
        let engine = SayLessEngine()
        _ = try engine.loadModel(path: modelPath)
        let reloaded = try store.loadAudio(name)
        let result = try engine.transcribe(pcm: reloaded, options: DictationOptions(language: nil, translate: false, initialPrompt: nil, trimSilence: true))
        #expect(wordErrorRate(reference: reference, hypothesis: result.text) == 0, "\(result.text)")
        try store.updateTranscription(id: id, raw: result.text, final: result.text, model: "parakeet-tdt-0.6b-v3", mode: "clean")
        let updated = try #require(try store.entry(id: id))
        #expect(updated.raw == result.text && updated.model == "parakeet-tdt-0.6b-v3" && updated.audioFile == name)
    }
}
