import AppKit

/// What happened when inserting one transcript.
public struct InsertReport: Sendable {
    public enum Result: Equatable, Sendable {
        case inserted(InsertionStrategy)
        /// AX changed the field but not as expected; the text is probably there.
        case unverified(InsertionStrategy)
        /// Secure input or a password field: nothing was inserted.
        case blockedBySecureInput
        case failed(String)
    }

    public var result: Result
    public var bundleID: String?
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
    public let paste: PasteInserter
    private let focus: FocusProvider
    private let typer: Typer
    private let checkSecureInput: Bool
    /// All Accessibility calls go here, never on the main thread (ADR-008).
    private let axQueue = DispatchQueue(label: "dev.utter.ax", qos: .userInitiated)

    public init(table: AppInsertionTable = .load(),
                paste: PasteInserter = PasteInserter(),
                checkSecureInput: Bool = true,
                focus: @escaping FocusProvider = { AXFocusedElement.current() },
                typer: @escaping Typer = { await TypingInserter.type($0) }) {
        self.table = table
        self.paste = paste
        self.checkSecureInput = checkSecureInput
        self.focus = focus
        self.typer = typer
    }

    private func onAXQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: work()) }
        }
    }

    public func insert(_ text: String, bundleID: String?) async -> InsertReport {
        var report = InsertReport(result: .failed("No insertion method worked for this app."), bundleID: bundleID)
        if checkSecureInput && PasteInserter.secureInputActive {
            report.result = .blockedBySecureInput
            report.attempts.append("secure event input is on")
            return report
        }
        let focus = self.focus
        let secureField = await onAXQueue { focus().map(AccessibilityInserter.isSecure) ?? false }
        if secureField {
            report.result = .blockedBySecureInput
            report.attempts.append("focused field is a password field")
            return report
        }

        for strategy in table.chain(for: bundleID) {
            switch strategy {
            case .accessibility:
                let result = await onAXQueue { AccessibilityInserter.insert(text, into: focus()) }
                switch result {
                case .inserted:
                    report.result = .inserted(.accessibility)
                    return report
                case .secureField:
                    report.result = .blockedBySecureInput
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
                let outcome = await paste.insert(text)
                report.paste = paste.lastTiming
                switch outcome {
                case .pasted:
                    report.result = .inserted(.paste)
                    return report
                case .blockedBySecureInput:
                    report.result = .blockedBySecureInput
                    return report
                case .failed(let why):
                    report.attempts.append("paste: \(why)")
                }
            case .typing:
                if let error = await typer(text) {
                    report.attempts.append("typing: \(error)")
                } else {
                    report.result = .inserted(.typing)
                    return report
                }
            }
        }
        return report
    }
}
