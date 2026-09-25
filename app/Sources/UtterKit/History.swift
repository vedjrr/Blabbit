import Foundation
import GRDB

/// One dictation in the local history (G5). Audio is only kept when the user
/// turns on audio retention.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var durationMs: Double
    public var model: String
    public var mode: String
    public var raw: String
    public var final: String
    /// Bundle ID of the app the text went into.
    public var app: String?
    /// File name inside the history audio folder, if audio was kept.
    public var audioFile: String?

    public static let databaseTableName = "dictation"

    public init(id: Int64? = nil, createdAt: Date = Date(), durationMs: Double, model: String, mode: String,
                raw: String, final: String, app: String? = nil, audioFile: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.model = model
        self.mode = mode
        self.raw = raw
        self.final = final
        self.app = app
        self.audioFile = audioFile
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Privacy settings (Settings → Privacy).
public struct PrivacySettings: Codable, Equatable, Sendable {
    public var historyEnabled = true
    /// Keep each dictation's audio (16 kHz WAV) with its history entry.
    public var keepAudio = false
    /// Local-only: never use a cloud processor, whatever else is set.
    public var localOnly = true

    public init(historyEnabled: Bool = true, keepAudio: Bool = false, localOnly: Bool = true) {
        self.historyEnabled = historyEnabled
        self.keepAudio = keepAudio
        self.localOnly = localOnly
    }

    public static let defaultsKey = "privacy.settings"

    public static func load(from defaults: UserDefaults = .standard) -> PrivacySettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(PrivacySettings.self, from: data) else { return PrivacySettings() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// When a dictation is kept, and with what (pure; tested).
public enum HistoryPolicy {
    /// Text that reached an app or the clipboard; never a password-field block.
    public static func shouldRecord(_ result: InsertReport.Result, privacy: PrivacySettings) -> Bool {
        guard privacy.historyEnabled else { return false }
        switch result {
        case .inserted, .unverified, .copiedToClipboard, .handledByScript: return true
        case .blockedBySecureInput, .failed, .skipped: return false
        }
    }

    /// Audio is stored only when the user turned on "keep audio".
    public static func audioToKeep(_ samples: [Float], privacy: PrivacySettings) -> [Float]? {
        privacy.historyEnabled && privacy.keepAudio ? samples : nil
    }
}

extension Notification.Name {
    /// Posted on the main thread after an entry is added or deleted.
    public static let historyChanged = Notification.Name("dev.utter.historyChanged")
}

/// SQLite history with full-text search (GRDB + FTS5), ADR-009.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    private let db: DatabaseQueue
    public var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }

    public static var defaultDirectory: URL {
        ModelLocation.modelsDirectory.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
    }

    public init(directory: URL = HistoryStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        // Deleted dictations are overwritten on disk, not left in free pages.
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        db = try DatabaseQueue(path: directory.appendingPathComponent("history.sqlite").path, configuration: config)
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: HistoryEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("durationMs", .double).notNull()
                t.column("model", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("raw", .text).notNull()
                t.column("final", .text).notNull()
                t.column("app", .text)
                t.column("audioFile", .text)
            }
            // Kept in sync with the table by triggers GRDB creates.
            try db.create(virtualTable: "dictation_ft", using: FTS5()) { t in
                t.synchronize(withTable: HistoryEntry.databaseTableName)
                t.tokenizer = .unicode61()
                t.column("raw")
                t.column("final")
            }
        }
        return m
    }

    @discardableResult
    public func add(_ entry: HistoryEntry) throws -> HistoryEntry {
        var e = entry
        try db.write { db in try e.insert(db) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .historyChanged, object: self) }
        return e
    }

    /// Newest first. An empty query lists everything.
    public func entries(matching query: String = "", limit: Int = 500) throws -> [HistoryEntry] {
        try db.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else {
                return try HistoryEntry.order(Column("createdAt").desc).limit(limit).fetchAll(db)
            }
            let sql = """
                SELECT dictation.* FROM dictation
                JOIN dictation_ft ON dictation_ft.rowid = dictation.id
                WHERE dictation_ft MATCH ?
                ORDER BY dictation.createdAt DESC LIMIT ?
                """
            return try HistoryEntry.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }

    public func count() throws -> Int {
        try db.read { db in try HistoryEntry.fetchCount(db) }
    }

    public func delete(id: Int64) throws {
        let audio: String? = try db.write { db in
            let entry = try HistoryEntry.fetchOne(db, key: id)
            _ = try HistoryEntry.deleteOne(db, key: id)
            return entry?.audioFile
        }
        if let audio { try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(audio)) }
    }

    /// Deletes every entry and every kept audio file ("Clear local data").
    public func deleteAll() throws {
        _ = try db.write { db in try HistoryEntry.deleteAll(db) }
        try? FileManager.default.removeItem(at: audioDirectory)
        try db.vacuum()
    }

    /// Saves 16 kHz mono samples as a 16-bit WAV and returns its file name.
    public func saveAudio(_ samples: [Float]) throws -> String {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).wav"
        try WAV.encode16kMono(samples).write(to: audioDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }
}

enum WAV {
    /// RIFF/WAVE, PCM 16-bit, mono, 16 kHz.
    static func encode16kMono(_ samples: [Float]) -> Data {
        let rate: UInt32 = 16_000
        let dataBytes = UInt32(samples.count * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.reserveCapacity(d.count + Int(dataBytes))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
