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
    /// Starred: never removed by the history limit or retention (PARITY E3).
    public var saved = false

    public static let databaseTableName = "dictation"

    public init(id: Int64? = nil, createdAt: Date = Date(), durationMs: Double, model: String, mode: String,
                raw: String, final: String, app: String? = nil, audioFile: String? = nil, saved: Bool = false) {
        self.saved = saved
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
    /// How long dictations are kept (PARITY E6). Starred ones always stay.
    public var retention = HistoryRetention.forever
    /// With `.limit`: how many unstarred dictations to keep.
    public var historyLimit = 100

    public static let historyLimitChoices = [10, 50, 100, 500, 1000]

    public init(historyEnabled: Bool = true, keepAudio: Bool = false, localOnly: Bool = true) {
        self.historyEnabled = historyEnabled
        self.keepAudio = keepAudio
        self.localOnly = localOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? false
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? true
        retention = (try? c.decodeIfPresent(HistoryRetention.self, forKey: .retention)) ?? .forever
        historyLimit = max(1, try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 100)
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

/// How long history keeps dictations (Handy's `recording_retention_period`).
public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case forever, limit, days3, weeks2, months3

    public var title: String {
        switch self {
        case .forever: "Forever"
        case .limit: "The most recent ones"
        case .days3: "3 days"
        case .weeks2: "2 weeks"
        case .months3: "3 months"
        }
    }

    /// Entries created before this are removed (nil: no age limit).
    public func cutoff(now: Date) -> Date? {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .forever, .limit: return nil
        case .days3: return now.addingTimeInterval(-3 * day)
        case .weeks2: return now.addingTimeInterval(-14 * day)
        case .months3: return now.addingTimeInterval(-90 * day)
        }
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
    public static let historyChanged = Notification.Name("dev.blabbit.historyChanged")
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
        // Added in M7; runs after v1 on existing databases.
        m.registerMigration("v2-saved") { db in
            try db.alter(table: HistoryEntry.databaseTableName) { t in
                t.add(column: "saved", .boolean).notNull().defaults(to: false)
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

    public func entry(id: Int64) throws -> HistoryEntry? {
        try db.read { db in try HistoryEntry.fetchOne(db, key: id) }
    }

    /// Stars or unstars a dictation (PARITY E3).
    public func setSaved(id: Int64, _ saved: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE dictation SET saved = ? WHERE id = ?", arguments: [saved, id])
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .historyChanged, object: self) }
    }

    /// Replaces a dictation's text after it was transcribed again (PARITY E4).
    public func updateTranscription(id: Int64, raw: String, final: String, model: String, mode: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE dictation SET raw = ?, final = ?, model = ?, mode = ? WHERE id = ?",
                           arguments: [raw, final, model, mode, id])
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .historyChanged, object: self) }
    }

    /// Applies the history limit or retention period (PARITY E6). Starred
    /// dictations are never removed. Returns how many were removed.
    @discardableResult
    public func prune(_ privacy: PrivacySettings, now: Date = Date()) throws -> Int {
        let removed: [(Int64, String?)] = try db.write { db in
            var doomed: [HistoryEntry] = []
            switch privacy.retention {
            case .forever:
                return []
            case .limit:
                doomed = try HistoryEntry.filter(Column("saved") == false).order(Column("createdAt").desc)
                    .limit(-1, offset: privacy.historyLimit).fetchAll(db)
            case .days3, .weeks2, .months3:
                guard let cutoff = privacy.retention.cutoff(now: now) else { return [] }
                doomed = try HistoryEntry.filter(Column("saved") == false && Column("createdAt") < cutoff).fetchAll(db)
            }
            let ids = doomed.compactMap(\.id)
            _ = try HistoryEntry.deleteAll(db, keys: ids)
            return doomed.compactMap { e in e.id.map { ($0, e.audioFile) } }
        }
        for case let (_, audio?) in removed {
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(audio))
        }
        if !removed.isEmpty {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .historyChanged, object: self) }
        }
        return removed.count
    }

    /// Reads a kept recording back as 16 kHz mono samples.
    public func loadAudio(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: audioDirectory.appendingPathComponent(name))
        guard let samples = WAV.decode16kMono(data) else { throw CocoaError(.fileReadCorruptFile) }
        return samples
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
    /// Reads what `encode16kMono` wrote (PCM 16-bit mono 16 kHz); nil otherwise.
    static func decode16kMono(_ d: Data) -> [Float]? {
        let bytes = [UInt8](d)
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        guard bytes.count >= 44, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else { return nil }
        var i = 12
        var format: (channels: UInt16, rate: UInt32, bits: UInt16)?
        while i + 8 <= bytes.count {
            let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let size = Int(u32(i + 4))
            let body = i + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = (u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                guard let f = format, f.channels == 1, f.rate == 16_000, f.bits == 16 else { return nil }
                let end = min(body + size, bytes.count)
                return stride(from: body, to: end - 1, by: 2).map { Float(Int16(bitPattern: u16($0))) / 32768 }
            }
            i = body + size + (size & 1)
        }
        return nil
    }

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
