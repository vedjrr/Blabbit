import AppKit

/// What happened when inserting one transcript.
public struct InsertReport: Sendable {
    public enum Result: Equatable, Sendable {
        case inserted(InsertionStrategy)
        /// The text may or may not have gone in (AX read-back inconclusive, or
        /// the target never read the pasted clipboard). Never retried, so no
        /// duplicate text; the caller keeps the words on the clipboard.
        case unverified(InsertionStrategy)
        /// Secure input or a password field: nothing was inserted.
        case blockedBySecureInput
        /// Method "clipboard only": text placed on the clipboard, not typed.
        case copiedToClipboard
        /// Method "external script": the user's script received the text.
        case handledByScript
        /// Nothing to insert (blank transcript); nothing was touched.
        case skipped
        case failed(String)
    }

    public var result: Result
    public var bundleID: String?
    /// With `.blockedBySecureInput`: true if a password field was focused (text
    /// must be dropped), false if only global secure input was on.
    public var secureFieldFocused = false
    /// With `.blockedBySecureInput`: typing had already sent part of the text.
    public var partiallyTyped = false
    /// Each strategy tried, with the reason it was skipped or failed.
    public var attempts: [String] = []
    /// Timing of the paste attempt (if paste was used).
    public var paste: InsertTiming?
}

/// Runs the per-app strategy chain: Accessibility → paste → typing (ADR-006).
@MainActor
public final class TextInserter {
    public typealias FocusProvider = @Sendable () -> FocusedTextElement?
    public typealias Typer = @MainActor (String) async -> String?

    public var table: AppInsertionTable
    public var settings: InsertionSettings
    /// Longest an external insertion script may run.
    public var scriptTimeout: TimeInterval = 5
    public let paste: PasteInserter
    private let keys: KeyPoster
    private let focus: FocusProvider
    private let typer: Typer
    private let checkSecureInput: Bool
    private let secureInputActive: @Sendable () -> Bool
    /// All Accessibility calls go here, never on the main thread (ADR-008).
    private let axQueue = DispatchQueue(label: "dev.utter.ax", qos: .userInitiated)

    public typealias KeyPoster = @MainActor (InsertionSettings.AutoSubmit) -> Void

    public init(table: AppInsertionTable = .load(),
                settings: InsertionSettings = .load(),
                paste: PasteInserter = PasteInserter(),
                keys: @escaping KeyPoster = TextInserter.postSubmitKey,
                checkSecureInput: Bool = true,
                secureInputActive: @escaping @Sendable () -> Bool = { PasteInserter.secureInputActive },
                focus: @escaping FocusProvider = { AXFocusedElement.current() },
                typer: @escaping Typer = { await TypingInserter.type($0) }) {
        self.table = table
        self.settings = settings
        self.paste = paste
        self.keys = keys
        self.checkSecureInput = checkSecureInput
        self.secureInputActive = secureInputActive
        self.focus = focus
        self.typer = typer
    }

    /// The app that owns the focused element. It can differ from the frontmost
    /// app (Spotlight-style non-activating panels), and its running bundle is
    /// the copy actually in use.
    nonisolated static func owner(of pid: pid_t?) -> (bundleID: String?, bundleURL: URL?)? {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return (app.bundleIdentifier, app.bundleURL)
    }

    private func onAXQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: work()) }
        }
    }

    public func insert(_ rawText: String, bundleID: String?) async -> InsertReport {
        // Noise can transcribe to nothing; never paste an empty string or send a bare Enter.
        guard !TranscriptPolicy.isBlank(rawText) else {
            return InsertReport(result: .skipped, bundleID: bundleID)
        }
        let text = settings.finalText(rawText)
        var report = await insertWithoutExtras(text, bundleID: bundleID)
        switch report.result {
        case .inserted, .unverified, .handledByScript:
            if settings.copyToClipboard { paste.board.clearContents(); paste.board.setString(text, forType: .string) }
            // Never submit something we couldn't verify, or text a script consumed.
            if settings.autoSubmit != .off, case .inserted = report.result {
                keys(settings.autoSubmit)
                report.attempts.append("auto-submit: \(settings.autoSubmit.rawValue)")
            }
        case .copiedToClipboard, .blockedBySecureInput, .failed, .skipped:
            break
        }
        return report
    }

    private func insertWithoutExtras(_ text: String, bundleID: String?) async -> InsertReport {
        var report = InsertReport(result: .failed("No insertion method worked for this app."), bundleID: bundleID)
        // Secure input blocks every method, including clipboard-only and scripts:
        // Utter never outputs dictated text while a password may be being typed.
        let focus = self.focus
        let table = self.table
        let frontmost = bundleID
        // One trip to the AX queue: password check, owner of the focused field,
        // and the chain (the Electron check touches the disk, so not on main).
        let (secureField, ownerID, chain) = await onAXQueue { () -> (Bool, String?, [InsertionStrategy]) in
            let element = focus()
            let owner = Self.owner(of: element?.pid)
            let id = owner?.bundleID ?? frontmost
            return (element.map(AccessibilityInserter.isSecure) ?? false, id, table.chain(for: id, bundleURL: owner?.bundleURL))
        }
        report.bundleID = ownerID
        if secureField {
            report.result = .blockedBySecureInput
            report.secureFieldFocused = true
            report.attempts.append("focused field is a password field")
            return report
        }
        if checkSecureInput && secureInputActive() {
            report.result = .blockedBySecureInput
            report.attempts.append("secure event input is on")
            return report
        }
        switch settings.method {
        case .clipboardOnly:
            paste.board.clearContents()
            paste.board.setString(text, forType: .string)
            report.result = .copiedToClipboard
            return report
        case .externalScript:
            report.result = await runScript(text)
            return report
        case .automatic:
            break
        }

        for strategy in chain {
            switch strategy {
            case .accessibility:
                let result = await onAXQueue { AccessibilityInserter.insert(text, into: focus()) }
                switch result {
                case .inserted:
                    report.result = .inserted(.accessibility)
                    return report
                case .secureField:
                    report.result = .blockedBySecureInput
                    report.secureFieldFocused = true
                    return report
                case .unverified:
                    report.result = .unverified(.accessibility)
                    report.attempts.append("accessibility: field changed unexpectedly; not retrying to avoid duplicates")
                    return report
                case .noEffect:
                    report.attempts.append("accessibility: no effect")
                case .notApplicable(let why):
                    report.attempts.append("accessibility: \(why)")
                }
            case .paste:
                // Clamped: a bad setting must not stall the paste queue.
                paste.pasteDelay = .milliseconds(min(max(settings.pasteDelayMs, 0), 5_000))
                paste.restoreDelay = .milliseconds(min(max(settings.pasteDelayAfterMs, 0), 5_000))
                let outcome = await paste.insert(text)
                report.paste = paste.lastTiming
                switch outcome {
                case .pasted(receipt: true):
                    report.result = .inserted(.paste)
                    return report
                case .pasted(receipt: false):
                    // Nothing read the clipboard. Don't fall through to typing: a
                    // late read would still paste, and the text would appear twice.
                    report.result = .unverified(.paste)
                    report.attempts.append("paste: the app never read the clipboard")
                    return report
                case .blockedBySecureInput:
                    report.result = .blockedBySecureInput
                    return report
                case .failed(let why):
                    report.attempts.append("paste: \(why)")
                }
            case .typing:
                // Focus may have moved since the chain started: re-check before posting keys.
                if checkSecureInput && secureInputActive() {
                    report.result = .blockedBySecureInput
                    report.attempts.append("secure event input turned on before typing")
                    return report
                }
                if let error = await typer(text) {
                    report.attempts.append("typing: \(error)")
                    if error == TypingInserter.secureInputStoppedTyping {
                        report.result = .blockedBySecureInput
                        report.partiallyTyped = true
                        return report
                    }
                } else {
                    report.result = .inserted(.typing)
                    return report
                }
            }
        }
        return report
    }

    /// Runs the user's script with the text on stdin (`scriptTimeout` limit, off the main thread).
    private func runScript(_ text: String) async -> InsertReport.Result {
        guard let path = settings.externalScriptPath, FileManager.default.isExecutableFile(atPath: path) else {
            return .failed("The insertion script is missing or not executable. Check Settings → Text Insertion.")
        }
        let timeout = scriptTimeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runScriptBlocking(path: path, text: text, timeout: timeout))
            }
        }
    }

    /// Blocking worker for `runScript`. A script that exits without reading
    /// stdin, never reads it, or ignores SIGTERM can neither crash nor hang Utter.
    nonisolated static func runScriptBlocking(path: String, text: String, timeout: TimeInterval) -> InsertReport.Result {
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = URL(fileURLWithPath: path)
        let input = Pipe()
        // Writing to a pipe whose reader has gone must be an error, not SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failed("The insertion script could not be started.")
        }
        // Drop our copy of the read end so the write fails (EPIPE) once the script exits.
        try? input.fileHandleForReading.close()
        let writer = input.fileHandleForWriting
        DispatchQueue(label: "dev.utter.script-stdin").async {
            try? writer.write(contentsOf: Data(text.utf8)) // EPIPE if the script didn't read: fine
            try? writer.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Children (e.g. `sleep` under `sh`) would outlive the shell and keep
            // stdin open, so stop the whole tree. Collect it while the shell
            // still exists: afterwards they are reparented to launchd.
            let shell = process.processIdentifier
            var tree = ([shell] + descendants(of: shell)).compactMap(ProcessIdentity.init)
            for member in tree { member.signal(SIGTERM) }
            let shellExited = exited.wait(timeout: .now() + 1) == .success
            // Anything that ignored SIGTERM goes now, including children forked
            // since. Identity (pid + start time) guards against PID reuse.
            if !shellExited { tree += descendants(of: shell).compactMap(ProcessIdentity.init) }
            for member in tree { member.signal(SIGKILL) }
            if !shellExited { _ = exited.wait(timeout: .now() + 1) }
            let seconds = Int(timeout.rounded(.up))
            return .failed("The insertion script took longer than \(seconds) second\(seconds == 1 ? "" : "s") and was stopped.")
        }
        if process.terminationStatus != 0 {
            return .failed("The insertion script failed (exit code \(process.terminationStatus)).")
        }
        return .handledByScript
    }

    /// A process pinned by its start time, so a signal never reaches a
    /// different process that later reused the PID.
    struct ProcessIdentity {
        let pid: pid_t
        let started: (UInt64, UInt64)

        init?(_ pid: pid_t) {
            guard let started = Self.startTime(of: pid) else { return nil }
            self.pid = pid
            self.started = started
        }

        static func startTime(of pid: pid_t) -> (UInt64, UInt64)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return (info.pbi_start_tvsec, info.pbi_start_tvusec)
        }

        func signal(_ sig: Int32) {
            guard let now = Self.startTime(of: pid), now == started else { return }
            kill(pid, sig)
        }
    }

    /// All descendant PIDs of `pid` (children first found, depth-first).
    nonisolated static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        for child in buffer.prefix(Int(count)) where child > 0 {
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }

    /// Enter / ⌃Enter / ⌘Enter after insertion (chat apps, terminals).
    public static func postSubmitKey(_ key: InsertionSettings.AutoSubmit) {
        let flags: CGEventFlags
        switch key {
        case .off: return
        case .enter: flags = []
        case .controlEnter: flags = .maskControl
        case .commandEnter: flags = .maskCommand
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
