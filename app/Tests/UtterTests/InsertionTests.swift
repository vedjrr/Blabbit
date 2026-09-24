import AppKit
import Testing
@testable import UtterKit

/// A text field whose behaviour on write can be scripted.
final class FakeElement: FocusedTextElement, @unchecked Sendable {
    enum OnWrite { case insert, ignore, fail, mangle, failButApply, applyOnSecondRead }
    var role: String? = "AXTextArea"
    var subrole: String?
    private var storedValue: String?
    private var pending: String?
    private var readsSinceWrite = 0
    var value: String? {
        get {
            readsSinceWrite += 1
            if let p = pending, readsSinceWrite >= 2 { storedValue = p; pending = nil }
            return storedValue
        }
        set { storedValue = newValue }
    }
    var selectedRange: NSRange?
    var canSetSelectedText = true
    var onWrite: OnWrite = .insert
    var writes = 0

    init(value: String? = "Hello world", selection: NSRange? = NSRange(location: 5, length: 0)) {
        self.value = value
        self.selectedRange = selection
    }

    func applied(_ text: String) -> String {
        let current = (storedValue ?? "") as NSString
        let range = selectedRange ?? NSRange(location: current.length, length: 0)
        return current.replacingCharacters(in: range, with: text)
    }

    func setSelectedText(_ text: String) -> Bool {
        writes += 1
        readsSinceWrite = 0
        switch onWrite {
        case .fail: return false
        case .ignore: return true
        case .mangle:
            storedValue = (storedValue ?? "") + "?"
            return true
        case .insert:
            storedValue = applied(text)
            return true
        case .failButApply:
            // Reports a timeout, but the app applies the write anyway.
            storedValue = applied(text)
            return false
        case .applyOnSecondRead:
            // Asynchronous AX server: the change shows up a moment later.
            pending = applied(text)
            return true
        }
    }
}

@Suite struct InsertionStrategyTableTests {
    @Test func defaultsByAppClass() {
        let table = AppInsertionTable()
        #expect(table.chain(for: "com.apple.TextEdit") == [.accessibility, .paste, .typing])
        #expect(table.chain(for: "com.apple.Terminal") == [.paste, .typing])
        #expect(table.chain(for: "com.googlecode.iterm2") == [.paste, .typing])
        #expect(table.chain(for: "com.microsoft.VSCode") == [.paste, .typing])
        #expect(table.chain(for: "com.google.Chrome") == [.paste, .typing])
        #expect(table.chain(for: "com.example.unknown") == [.accessibility, .paste, .typing])
        #expect(table.chain(for: nil) == [.accessibility, .paste, .typing])
    }

    @Test func userOverrideWinsAndPersists() throws {
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var table = AppInsertionTable()
        table.overrides["com.apple.Terminal"] = [.typing]
        table.save(to: defaults)
        let loaded = AppInsertionTable.load(from: defaults)
        #expect(loaded.chain(for: "com.apple.Terminal") == [.typing])
        #expect(loaded.chain(for: "com.apple.TextEdit") == [.accessibility, .paste, .typing])
    }

    @Test func emptyOverrideFallsBackToDefault() {
        let table = AppInsertionTable(overrides: ["com.apple.Terminal": []])
        #expect(table.chain(for: "com.apple.Terminal") == [.paste, .typing])
    }
}

@Suite struct AccessibilityInserterTests {
    @Test func insertsAtCaretAndVerifies() {
        let field = FakeElement()
        #expect(AccessibilityInserter.insert(", dear", into: field, settle: {}) == .inserted)
        #expect(field.value == "Hello, dear world")
    }

    @Test func replacesSelection() {
        let field = FakeElement(selection: NSRange(location: 6, length: 5))
        #expect(AccessibilityInserter.insert("there", into: field) == .inserted)
        #expect(field.value == "Hello there")
    }

    @Test func refusesPasswordFields() {
        let field = FakeElement()
        field.subrole = "AXSecureTextField"
        #expect(AccessibilityInserter.insert("secret", into: field) == .secureField)
        #expect(field.writes == 0)
    }

    @Test func notApplicableCasesNeverWrite() {
        #expect(AccessibilityInserter.insert("x", into: nil) == .notApplicable("no focused element"))
        let button = FakeElement(); button.role = "AXButton"
        let readOnly = FakeElement(); readOnly.canSetSelectedText = false
        let opaque = FakeElement(value: nil)
        for element in [button, readOnly, opaque] {
            if case .notApplicable = AccessibilityInserter.insert("x", into: element) {} else { Issue.record("expected notApplicable") }
            #expect(element.writes == 0)
        }
    }

    @Test func silentNoOpIsDetectedSoPasteCanTakeOver() {
        let field = FakeElement(); field.onWrite = .ignore
        var settled = 0
        #expect(AccessibilityInserter.insert("text", into: field, settle: { settled += 1 }) == .noEffect)
        #expect(settled == 1, "waits once before concluding no effect")
    }

    @Test func errorThatStillAppliesIsNotRetried() {
        let field = FakeElement(); field.onWrite = .failButApply
        #expect(AccessibilityInserter.insert(" there", into: field, settle: {}) == .inserted)
    }

    @Test func lateAsynchronousApplyIsSeenAfterSettling() {
        let field = FakeElement(); field.onWrite = .applyOnSecondRead
        #expect(AccessibilityInserter.insert(" there", into: field, settle: {}) == .inserted)
        #expect(field.value == "Hello there world")
    }

    @Test func failedWriteWithNoChangeFallsThrough() {
        let field = FakeElement(); field.onWrite = .fail
        if case .notApplicable = AccessibilityInserter.insert("text", into: field, settle: {}) {} else { Issue.record("expected fall-through") }
    }

    @Test func unexpectedChangeIsNotRetried() {
        let field = FakeElement(); field.onWrite = .mangle
        #expect(AccessibilityInserter.insert("text", into: field) == .unverified)
    }

    @Test func handlesEmojiAndNonLatinUTF16Lengths() {
        let field = FakeElement(value: "", selection: NSRange(location: 0, length: 0))
        #expect(AccessibilityInserter.insert("Café 👋🏽 日本語", into: field) == .inserted)
    }
}

@Suite struct TypingInserterTests {
    @Test func chunksAtTwentyUnitsWithoutSplittingGraphemes() {
        let text = String(repeating: "a", count: 19) + "👋🏽" + "bc"
        let pieces = TypingInserter.pieces(for: text)
        for case .text(let units) in pieces { #expect(units.count <= 20) }
        let rebuilt = pieces.compactMap { if case .text(let u) = $0 { return String(utf16CodeUnits: u, count: u.count) } else { return nil } }.joined()
        #expect(rebuilt == text)
        #expect(pieces.first == .text(Array(String(repeating: "a", count: 19).utf16)))
    }

    @Test func oversizedGraphemeIsSplitOnScalarBoundaries() {
        // 👍 plus 20 combining accents: one grapheme, 22 UTF-16 units, starting with a surrogate pair.
        let family = "👍" + String(repeating: "\u{0301}", count: 20)
        #expect(family.count == 1)
        #expect(Array(family.utf16).count > 20)
        let pieces = TypingInserter.pieces(for: "a" + family + "b")
        var rebuilt: [UInt16] = []
        for case .text(let units) in pieces {
            #expect(units.count <= 20)
            // No chunk starts with a low surrogate or ends with a high surrogate.
            #expect(!(0xDC00...0xDFFF).contains(units.first!))
            #expect(!(0xD800...0xDBFF).contains(units.last!))
            rebuilt += units
        }
        #expect(String(utf16CodeUnits: rebuilt, count: rebuilt.count) == "a" + family + "b")
    }

    @Test func newlinesBecomeReturnKeys() {
        #expect(TypingInserter.pieces(for: "a\nb") == [.text([97]), .newline, .text([98])])
        #expect(TypingInserter.pieces(for: "\n\n") == [.newline, .newline])
        #expect(TypingInserter.pieces(for: "") == [])
    }
}

@MainActor @Suite struct TextInserterTests {
    func makePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("dev.utter.test.\(UUID().uuidString)")) }

    func inserter(field: FakeElement?, pb: NSPasteboard, pasteRead: Bool = true, secure: Bool = false,
                  settings: InsertionSettings = InsertionSettings(), typed: @escaping (String) -> Void = { _ in }) -> TextInserter {
        let paste = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            if pasteRead { _ = pb.string(forType: .string) }
            return nil
        }
        paste.quietPeriod = .milliseconds(10)
        paste.receiptTimeout = .milliseconds(100)
        nonisolated(unsafe) let field = field
        return TextInserter(settings: settings, paste: paste, checkSecureInput: true, secureInputActive: { secure },
                            focus: { field }, typer: { text in typed(text); return nil })
    }

    @Test func nativeAppUsesAccessibilityAndLeavesClipboardAlone() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        let changeCount = pb.changeCount
        let field = FakeElement()
        let report = await inserter(field: field, pb: pb).insert(" there", bundleID: "com.apple.TextEdit")
        #expect(report.result == .inserted(.accessibility))
        #expect(field.value == "Hello there world")
        #expect(pb.changeCount == changeCount) // clipboard never touched
    }

    @Test func accessibilityNoOpFallsThroughToPaste() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        let field = FakeElement(); field.onWrite = .ignore
        let report = await inserter(field: field, pb: pb).insert("text", bundleID: "com.apple.TextEdit")
        #expect(report.result == .inserted(.paste))
        #expect(report.attempts == ["accessibility: no effect"])
    }

    @Test func terminalSkipsAccessibility() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        let field = FakeElement()
        let report = await inserter(field: field, pb: pb).insert("ls -la", bundleID: "com.apple.Terminal")
        #expect(report.result == .inserted(.paste))
        #expect(field.writes == 0)
    }

    @Test func passwordFieldBlocksEveryStrategy() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        let field = FakeElement(); field.subrole = "AXSecureTextField"
        var typed = false
        let report = await inserter(field: field, pb: pb, typed: { _ in typed = true }).insert("hunter2", bundleID: "com.google.Chrome")
        #expect(report.result == .blockedBySecureInput)
        #expect(!typed && field.writes == 0)
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func overrideToTypingIsHonoured() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var typedText: String?
        let ins = inserter(field: nil, pb: pb, typed: { typedText = $0 })
        ins.table.overrides["com.apple.Terminal"] = [.typing]
        let report = await ins.insert("echo hi", bundleID: "com.apple.Terminal")
        #expect(report.result == .inserted(.typing))
        #expect(typedText == "echo hi")
    }

    @Test func unverifiedAccessibilityIsNotRetried() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        let field = FakeElement(); field.onWrite = .mangle
        let report = await inserter(field: field, pb: pb).insert("text", bundleID: "com.apple.TextEdit")
        #expect(report.result == .unverified(.accessibility))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test(arguments: [InsertionSettings.Method.automatic, .clipboardOnly, .externalScript])
    func globalSecureInputBlocksEveryMethod(method: InsertionSettings.Method) async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        let field = FakeElement()
        var typed = false
        var settings = InsertionSettings(); settings.method = method; settings.externalScriptPath = "/usr/bin/true"
        let report = await inserter(field: field, pb: pb, secure: true, settings: settings, typed: { _ in typed = true })
            .insert("never typed", bundleID: "com.apple.TextEdit")
        #expect(report.result == .blockedBySecureInput)
        #expect(!report.secureFieldFocused)
        #expect(!typed && field.writes == 0)
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func passwordFieldIsReportedAsSuch() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        let field = FakeElement(); field.subrole = "AXSecureTextField"
        let report = await inserter(field: field, pb: pb).insert("x", bundleID: "com.example.app")
        #expect(report.result == .blockedBySecureInput)
        #expect(report.secureFieldFocused)
    }

    @Test func autoSubmitSkippedWhenUnverified() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        let field = FakeElement(); field.onWrite = .mangle
        var settings = InsertionSettings(); settings.autoSubmit = .enter
        var submitted = false
        let paste = PasteInserter(pasteboard: pb, checkSecureInput: false) { nil }
        nonisolated(unsafe) let f = field
        let ins = TextInserter(settings: settings, paste: paste, keys: { _ in submitted = true }, checkSecureInput: false,
                               focus: { f }, typer: { _ in nil })
        let report = await ins.insert("text", bundleID: "com.apple.TextEdit")
        #expect(report.result == .unverified(.accessibility))
        #expect(!submitted)
    }
}

@Suite struct DictationPolicyTests {
    @Test func watchdogRules() {
        var checks = 0
        #expect(WatchdogPolicy.releaseReason(elapsed: 600, maxSeconds: 600, source: .menu, keyDown: false, secureInput: false, keyUpChecks: &checks) == "max_length")
        #expect(WatchdogPolicy.releaseReason(elapsed: 1, maxSeconds: 600, source: .menu, keyDown: false, secureInput: true, keyUpChecks: &checks) == nil)
        #expect(WatchdogPolicy.releaseReason(elapsed: 1, maxSeconds: 600, source: .tap, keyDown: true, secureInput: true, keyUpChecks: &checks) == "secure_input")
        // Carbon recordings survive secure input (that's why they exist).
        checks = 0
        #expect(WatchdogPolicy.releaseReason(elapsed: 1, maxSeconds: 600, source: .carbon, keyDown: true, secureInput: true, keyUpChecks: &checks) == nil)
        // Key-up is only trusted after two consecutive observations.
        #expect(WatchdogPolicy.releaseReason(elapsed: 1, maxSeconds: 600, source: .tap, keyDown: false, secureInput: false, keyUpChecks: &checks) == nil)
        #expect(WatchdogPolicy.releaseReason(elapsed: 1.25, maxSeconds: 600, source: .tap, keyDown: false, secureInput: false, keyUpChecks: &checks) == "key_not_down")
        checks = 1
        #expect(WatchdogPolicy.releaseReason(elapsed: 1, maxSeconds: 600, source: .carbon, keyDown: true, secureInput: false, keyUpChecks: &checks) == nil)
        #expect(checks == 0)
    }

    @Test func secureInputFallback() {
        let global = SecureInputFallback.action(secureFieldFocused: false)
        #expect(global.copyToClipboard)
        let password = SecureInputFallback.action(secureFieldFocused: true)
        #expect(!password.copyToClipboard)
        #expect(password.message == "A password field is focused, so Utter didn't type anything.")
    }
}
