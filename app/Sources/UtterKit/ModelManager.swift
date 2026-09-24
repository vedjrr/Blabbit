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

    public let entries: [ModelEntry]
    public private(set) var status: [String: Status] = [:]
    public private(set) var defaultModelID: String
    /// Models whose licence the user accepted (persisted), for licences that require it.
    public private(set) var acceptedLicenses: Set<String>
    /// Called when the default model changes (the controller loads it).
    public var onDefaultModelChange: ((String) -> Void)?

    private let modelsDir: String
    private let defaults: UserDefaults
    private var downloads: [String: ModelDownload] = [:]

    public static let defaultModelKey = "model.default"
    public static let acceptedLicensesKey = "model.acceptedLicenses"

    public init(modelsDirectory: URL = ModelLocation.modelsDirectory, defaults: UserDefaults = .standard) {
        entries = catalogEntries()
        modelsDir = modelsDirectory.path
        self.defaults = defaults
        let recommended = entries.first(where: \.recommended)?.id ?? ModelLocation.defaultModelID
        defaultModelID = defaults.string(forKey: Self.defaultModelKey) ?? recommended
        acceptedLicenses = Set(defaults.stringArray(forKey: Self.acceptedLicensesKey) ?? [])
        refresh()
    }

    public func entry(_ id: String) -> ModelEntry? { entries.first { $0.id == id } }

    public var defaultEntry: ModelEntry? { entry(defaultModelID) }

    public func path(for id: String) -> String? { try? modelPath(modelsDir: modelsDir, id: id) }

    public var installedEntries: [ModelEntry] { entries.filter { status[$0.id] == .installed } }

    /// Re-reads install state from disk (cheap: size checks only).
    public func refresh() {
        for entry in entries where downloads[entry.id] == nil {
            switch try? modelState(modelsDir: modelsDir, id: entry.id) {
            case .installed: status[entry.id] = .installed
            case .partial(let bytes): status[entry.id] = .partial(bytes)
            default:
                if case .failed = status[entry.id] {} else { status[entry.id] = .notInstalled }
            }
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
        let resumeFrom: UInt64 = if case .partial(let b) = status[id] { b } else { 0 }
        status[id] = .downloading(downloaded: resumeFrom, total: entry.sizeBytes)
        let listener = Listener(manager: self, id: id)
        do {
            downloads[id] = try ModelDownload.start(modelsDir: modelsDir, id: id, listener: listener)
            Log.info("download started model=\(id) resume_from=\(resumeFrom)")
        } catch let error as CoreError {
            status[id] = .failed(error.userMessage)
        } catch {
            status[id] = .failed("The download could not be started.")
        }
    }

    public func pause(_ id: String) { downloads[id]?.pause() }
    public func cancel(_ id: String) { downloads[id]?.cancel() }

    /// Deletes a model. The default model can't be deleted while it is the default.
    public func delete(_ id: String) {
        guard id != defaultModelID else { return }
        downloads[id]?.cancel()
        do {
            try deleteModel(modelsDir: modelsDir, id: id)
            status[id] = .notInstalled
            Log.info("model deleted model=\(id)")
        } catch let error as CoreError {
            status[id] = .failed(error.userMessage)
        } catch {}
    }

    public func setDefault(_ id: String) {
        guard status[id] == .installed, id != defaultModelID else { return }
        defaultModelID = id
        defaults.set(id, forKey: Self.defaultModelKey)
        onDefaultModelChange?(id)
    }

    /// Marks a model damaged (e.g. its load failed) so the UI offers a re-download.
    public func markDamaged(_ id: String, message: String) {
        status[id] = .failed(message)
    }

    /// Deletes a damaged file and downloads it again (one-click repair, G3).
    public func redownload(_ id: String) {
        downloads[id]?.cancel()
        downloads[id] = nil
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
