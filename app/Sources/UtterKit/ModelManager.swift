import Foundation
import Observation
import UtterCore

/// Catalog, install state and downloads for the Model Manager (G3).
@MainActor @Observable
public final class ModelManager {
    public enum Status: Equatable {
        case notInstalled
        /// Paused or interrupted; this many bytes can be resumed.
        case partial(UInt64)
        case downloading(downloaded: UInt64, total: UInt64)
        case verifying
        case installed
        case failed(String)
    }

    /// The catalog plus the user's own model files (PARITY C7).
    public private(set) var entries: [ModelEntry]
    private let catalog: [ModelEntry]
    public private(set) var status: [String: Status] = [:]
    public private(set) var defaultModelID: String
    /// Models whose licence the user accepted (persisted), for licences that require it.
    public private(set) var acceptedLicenses: Set<String>
    /// Called when the default model changes (the controller loads it).
    public var onDefaultModelChange: ((String) -> Void)?

    private let modelsDir: String
    private let defaults: UserDefaults
    private var downloads: [String: ModelDownload] = [:]
    /// Models found damaged, with the message to show. Survives `refresh()`
    /// (a damaged file usually has the right size) until repaired.
    private var damaged: [String: String] = [:]
    /// Files whose SHA-256 was checked, keyed by id → "size:mtime" (persisted),
    /// so the ~1 s/GB check runs once per file, not on every launch.
    private var verifiedStamps: [String: String]

    /// Where models run (PARITY C11). Changing it reloads the current model.
    public var computeDevice: ComputeDevice {
        didSet {
            guard computeDevice != oldValue else { return }
            defaults.set(Self.name(computeDevice), forKey: Self.computeDeviceKey)
            onComputeDeviceChange?()
        }
    }
    public var onComputeDeviceChange: (() -> Void)?
    public static let computeDeviceKey = "model.computeDevice"

    static func name(_ device: ComputeDevice) -> String {
        switch device { case .auto: "auto"; case .gpu: "gpu"; case .cpu: "cpu" }
    }

    static func computeDevice(named name: String?) -> ComputeDevice {
        switch name { case "gpu": .gpu; case "cpu": .cpu; default: .auto }
    }

    public static let defaultModelKey = "model.default"
    public static let acceptedLicensesKey = "model.acceptedLicenses"
    public static let verifiedStampsKey = "model.verifiedStamps"

    /// Download mirror in place of huggingface.co (`HF_ENDPOINT`), if set.
    private let hubEndpoint: String?

    public init(modelsDirectory: URL = ModelLocation.modelsDirectory, defaults: UserDefaults = .standard,
                hubEndpoint: String? = ProcessInfo.processInfo.environment["HF_ENDPOINT"]) {
        let catalog = catalogEntries()
        self.catalog = catalog
        entries = catalog
        self.hubEndpoint = hubEndpoint
        modelsDir = modelsDirectory.path
        self.defaults = defaults
        let recommended = catalog.first(where: \.recommended)?.id ?? ModelLocation.defaultModelID
        defaultModelID = defaults.string(forKey: Self.defaultModelKey) ?? recommended
        acceptedLicenses = Set(defaults.stringArray(forKey: Self.acceptedLicensesKey) ?? [])
        verifiedStamps = defaults.dictionary(forKey: Self.verifiedStampsKey) as? [String: String] ?? [:]
        computeDevice = Self.computeDevice(named: defaults.string(forKey: Self.computeDeviceKey))
        refresh()
        // A saved choice that is no longer in the catalog falls back to the recommended model.
        if entry(defaultModelID) == nil { defaultModelID = recommended }
    }

    public func entry(_ id: String) -> ModelEntry? { entries.first { $0.id == id } }

    public var defaultEntry: ModelEntry? { entry(defaultModelID) }

    public func path(for id: String) -> String? {
        if let file = Self.customFileName(id) { return customDirectory.appendingPathComponent(file).path }
        return try? modelPath(modelsDir: modelsDir, id: id)
    }

    // MARK: Your own model files (PARITY C7)

    static let customPrefix = "custom:"
    /// Models → Custom: any GGUF file here is listed (Add Model File… copies into it).
    public var customDirectory: URL { URL(fileURLWithPath: modelsDir).appendingPathComponent("Custom", isDirectory: true) }

    public static func isCustom(_ id: String) -> Bool { id.hasPrefix(customPrefix) }
    static func customFileName(_ id: String) -> String? { isCustom(id) ? String(id.dropFirst(customPrefix.count)) : nil }

    /// A GGUF file starts with the bytes "GGUF".
    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    private func customEntries() -> [ModelEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let lower = name.lowercased()
            // The family decides extras such as Whisper's vocabulary prompt.
            let family = ["whisper", "parakeet", "moonshine", "sensevoice"].first { lower.contains($0) } ?? "custom"
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            return ModelEntry(id: Self.customPrefix + url.lastPathComponent, name: name, family: family,
                              description: "Your own model file. Not measured by Utter, so there are no scores.",
                              languages: [], sizeBytes: size, license: "Your file", licenseUrl: url.deletingLastPathComponent().absoluteString,
                              licenseRequiresAcceptance: false, recommended: false,
                              measuredWer: 0, measuredRtf: 0, measuredP50Ms: 0, measuredFootprintMb: 0,
                              variantOf: nil, quant: "")
        }
    }

    /// Copies a GGUF model file into the Custom folder. Returns a problem, or nil.
    @discardableResult
    public func addModelFile(_ url: URL) -> String? {
        guard Self.isGGUF(url) else { return "That file isn't a GGUF model. Utter runs .gguf files made for transcribe.cpp." }
        let dest = customDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { return "A model file with that name is already added." }
            try FileManager.default.copyItem(at: url, to: dest) // an APFS clone: instant, no extra space
        } catch {
            Log.error("add model file failed: \(error)")
            return "The model file couldn't be copied into Utter's models folder."
        }
        Log.info("custom model added file=\(url.lastPathComponent)")
        refresh()
        return nil
    }

    /// Smaller quantisations of a model (PARITY C6), shown inside its card.
    public func variants(of id: String) -> [ModelEntry] { entries.filter { $0.variantOf == id } }

    public var installedEntries: [ModelEntry] { entries.filter { status[$0.id] == .installed } }

    /// Re-reads install state from disk (cheap: size checks only).
    public func refresh() {
        let custom = customEntries()
        entries = catalog + custom
        for entry in custom { status[entry.id] = .installed }
        for entry in catalog where downloads[entry.id] == nil && !verifying.contains(entry.id) {
            switch try? modelState(modelsDir: modelsDir, id: entry.id) {
            case .installed:
                status[entry.id] = damaged[entry.id].map { .failed($0) } ?? .installed
            case .partial(let bytes): status[entry.id] = .partial(bytes)
            default:
                damaged[entry.id] = nil
                if case .failed = status[entry.id] {} else { status[entry.id] = .notInstalled }
            }
        }
    }

    // MARK: Verification

    private var verifying: Set<String> = []

    private func stamp(_ id: String) -> String? {
        guard let path = path(for: id),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size):\(modified.timeIntervalSince1970)"
    }

    /// True if this exact file (same size and modification time) passed a SHA-256 check.
    public func isVerified(_ id: String) -> Bool {
        if Self.isCustom(id) { return true } // no pinned hash to check against
        guard let current = stamp(id) else { return false }
        return verifiedStamps[id] == current
    }

    private func setVerified(_ id: String, _ value: String?) {
        verifiedStamps[id] = value
        defaults.set(verifiedStamps, forKey: Self.verifiedStampsKey)
    }

    public enum VerifyResult: Equatable, Sendable {
        case good
        /// SHA-256 or size mismatch: marked damaged, Re-download offered.
        case damaged
        /// Not checked (already verifying, downloading, unknown id, or an I/O
        /// error): says nothing about the file, so callers must not treat it as damaged.
        case notChecked
    }

    /// Full SHA-256 check off the main thread. A mismatch marks the model
    /// damaged (error + Re-download in the UI).
    @discardableResult
    public func verify(_ id: String) async -> VerifyResult {
        guard let entry = entry(id), downloads[id] == nil, !verifying.contains(id), !Self.isCustom(id) else { return .notChecked }
        verifying.insert(id)
        status[id] = .verifying
        let dir = modelsDir
        let result: CoreError? = await Task.detached(priority: .userInitiated) {
            do { try verifyModel(modelsDir: dir, id: id); return nil } catch let error as CoreError { return error } catch {
                return .ModelCorrupt(userMessage: "The model file is damaged.", detail: "\(error)")
            }
        }.value
        verifying.remove(id)
        switch result {
        case nil:
            setVerified(id, stamp(id))
            damaged[id] = nil
            status[id] = .installed
            Log.info("model verified model=\(id)")
            return .good
        case .ModelCorrupt(_, let detail)?, .ModelMissing(_, let detail)?:
            Log.error("model verification failed model=\(id): \(detail)")
            markDamaged(id, message: "\(entry.name) is damaged or incomplete. Choose Re-download to replace it.")
            return .damaged
        case let error?:
            Log.error("model verification error model=\(id): \(error.logDetail)")
            refresh()
            return .notChecked
        }
    }

    public func needsLicenseAcceptance(_ id: String) -> Bool {
        (entry(id)?.licenseRequiresAcceptance ?? false) && !acceptedLicenses.contains(id)
    }

    public func acceptLicense(_ id: String) {
        acceptedLicenses.insert(id)
        defaults.set(Array(acceptedLicenses).sorted(), forKey: Self.acceptedLicensesKey)
    }

    /// Starts, resumes or retries a download.
    public func download(_ id: String) {
        guard downloads[id] == nil, !needsLicenseAcceptance(id), let entry = entry(id) else { return }
        // Also right after a failure (status .failed) whose partial file was kept.
        let resumeFrom: UInt64 = if case .partial(let b)? = try? modelState(modelsDir: modelsDir, id: id) { b } else { 0 }
        status[id] = .downloading(downloaded: resumeFrom, total: entry.sizeBytes)
        let listener = Listener(manager: self, id: id)
        do {
            downloads[id] = try ModelDownload.start(modelsDir: modelsDir, id: id, hubEndpoint: hubEndpoint, listener: listener)
            Log.info("download started model=\(id) resume_from=\(resumeFrom)")
        } catch let error as CoreError {
            status[id] = .failed(error.userMessage)
        } catch {
            status[id] = .failed("The download could not be started.")
        }
    }

    public func pause(_ id: String) { downloads[id]?.pause() }

    /// Cancels a running download, or discards a paused/interrupted one.
    public func cancel(_ id: String) {
        if let running = downloads[id] {
            running.cancel()
            return
        }
        do {
            try discardPartialDownload(modelsDir: modelsDir, id: id)
            damaged[id] = nil
            status[id] = .notInstalled
            refresh()
            Log.info("partial download discarded model=\(id)")
        } catch let error as CoreError {
            status[id] = .failed(error.userMessage)
        } catch {
            status[id] = .failed("The partial download could not be removed.")
        }
    }

    /// Deletes a model. The default model can't be deleted while it is the default.
    public func delete(_ id: String) {
        guard id != defaultModelID else { return }
        if let path = path(for: id), Self.isCustom(id) {
            // The user's own file goes to the Trash, so it can be put back.
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch {
                status[id] = .failed("The model file couldn't be moved to the Trash.")
                return
            }
            status[id] = nil
            refresh()
            Log.info("custom model removed model=\(id)")
            return
        }
        downloads[id]?.cancel()
        do {
            try deleteModel(modelsDir: modelsDir, id: id)
            damaged[id] = nil
            setVerified(id, nil)
            status[id] = .notInstalled
            Log.info("model deleted model=\(id)")
        } catch let error as CoreError {
            status[id] = .failed(error.userMessage)
        } catch {
            Log.error("model delete failed model=\(id): \(error)")
            status[id] = .failed("The model could not be deleted.")
        }
    }

    /// Selects a model. The controller loads it and calls `commitDefault` once
    /// it has loaded, so a model that fails to load is never saved as the choice.
    public func setDefault(_ id: String) {
        guard status[id] == .installed, id != defaultModelID else { return }
        defaultModelID = id
        if let onDefaultModelChange { onDefaultModelChange(id) } else { commitDefault(id) }
    }

    /// The last choice that loaded successfully (what the next launch loads).
    public var committedDefaultID: String {
        defaults.string(forKey: Self.defaultModelKey) ?? entries.first(where: \.recommended)?.id ?? ModelLocation.defaultModelID
    }

    public func commitDefault(_ id: String) {
        defaults.set(id, forKey: Self.defaultModelKey)
    }

    /// A switch failed: go back to the last model that loaded.
    public func revertDefault() {
        defaultModelID = committedDefaultID
    }

    /// Marks a model damaged (failed verification or load) so the UI offers a
    /// re-download. Kept across `refresh()` until repaired.
    public func markDamaged(_ id: String, message: String) {
        damaged[id] = message
        setVerified(id, nil)
        status[id] = .failed(message)
    }

    public func isDamaged(_ id: String) -> Bool { damaged[id] != nil }

    /// Forces the next `verify`/load to re-check the file (e.g. after an inference failure).
    public func setVerifiedStale(_ id: String) { setVerified(id, nil) }

    /// Deletes a damaged file and downloads it again (one-click repair, G3).
    public func redownload(_ id: String) {
        // Never delete a file we then can't replace: the licence prompt comes first.
        guard !needsLicenseAcceptance(id) else { return }
        downloads[id]?.cancel()
        downloads[id] = nil
        damaged[id] = nil
        setVerified(id, nil)
        try? deleteModel(modelsDir: modelsDir, id: id)
        status[id] = .notInstalled
        download(id)
    }

    fileprivate func progress(_ id: String, _ downloaded: UInt64, _ total: UInt64) {
        guard downloads[id] != nil else { return }
        status[id] = downloaded >= total ? .verifying : .downloading(downloaded: downloaded, total: total)
    }

    fileprivate func finished(_ id: String, _ outcome: DownloadOutcome) {
        downloads[id] = nil
        switch outcome {
        case .completed:
            // The downloader checked the SHA-256 before installing the file.
            damaged[id] = nil
            setVerified(id, stamp(id))
            status[id] = .installed
            Log.info("download completed and verified model=\(id)")
            if id == defaultModelID { onDefaultModelChange?(id) }
        case .paused:
            refresh()
        case .cancelled:
            status[id] = .notInstalled
        case .failed(let userMessage, let detail):
            Log.error("download failed model=\(id): \(detail)")
            refresh()
            if case .partial = status[id] {
                status[id] = .failed(userMessage + " Progress was kept; Retry resumes it.")
            } else {
                status[id] = .failed(userMessage)
            }
        }
    }

    /// Bridges Rust download callbacks (worker thread) to the main actor.
    private final class Listener: DownloadListener, @unchecked Sendable {
        weak var manager: ModelManager?
        let id: String
        init(manager: ModelManager, id: String) {
            self.manager = manager
            self.id = id
        }
        func onProgress(downloaded: UInt64, total: UInt64) {
            let id = self.id
            Task { @MainActor [weak manager] in manager?.progress(id, downloaded, total) }
        }
        func onFinished(outcome: DownloadOutcome) {
            let id = self.id
            Task { @MainActor [weak manager] in manager?.finished(id, outcome) }
        }
    }
}
