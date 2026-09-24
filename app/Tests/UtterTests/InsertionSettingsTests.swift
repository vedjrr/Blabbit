import AppKit
import Testing
@testable import UtterKit

@Suite struct InsertionSettingsTests {
    @Test func trailingSpaceOnlyWhenEnabledAndNeeded() {
        var s = InsertionSettings()
        #expect(s.finalText("Hi.") == "Hi.")
        s.appendTrailingSpace = true
        #expect(s.finalText("Hi.") == "Hi. ")
        #expect(s.finalText("Hi. ") == "Hi. ")
        #expect(s.finalText("") == "")
    }

    @Test func decodingToleratesMissingAndNewKeys() throws {
        let partial = Data(#"{"autoSubmit":"enter","unknownFutureKey":1}"#.utf8)
        let s = try JSONDecoder().decode(InsertionSettings.self, from: partial)
        #expect(s.autoSubmit == .enter)
        #expect(s.method == .automatic)
        #expect(!s.appendTrailingSpace)
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let suite = "dev.utter.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var s = InsertionSettings()
        s.method = .externalScript
        s.externalScriptPath = "/usr/local/bin/x"
        s.pasteDelayMs = 40
        s.save(to: defaults)
        #expect(InsertionSettings.load(from: defaults) == s)
    }
}

@MainActor @Suite struct InsertionSettingsBehaviourTests {
    func makePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("dev.utter.test.\(UUID().uuidString)")) }

    func inserter(_ settings: InsertionSettings, pb: NSPasteboard, keys: @escaping TextInserter.KeyPoster = { _ in }) -> TextInserter {
        let paste = PasteInserter(pasteboard: pb, checkSecureInput: false) { _ = pb.string(forType: .string); return nil }
        paste.quietPeriod = .milliseconds(10)
        return TextInserter(settings: settings, paste: paste, keys: keys, checkSecureInput: false,
                            focus: { nil }, typer: { _ in nil })
    }

    @Test func clipboardOnlyNeverInserts() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.method = .clipboardOnly
        var submitted = false
        let report = await inserter(s, pb: pb, keys: { _ in submitted = true }).insert("just copy", bundleID: "com.apple.TextEdit")
        #expect(report.result == .copiedToClipboard)
        #expect(pb.string(forType: .string) == "just copy")
        #expect(!submitted)
    }

    @Test func copyToClipboardLeavesTranscriptAfterPaste() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        var s = InsertionSettings(); s.copyToClipboard = true
        let report = await inserter(s, pb: pb).insert("keep me", bundleID: "com.apple.Terminal")
        #expect(report.result == .inserted(.paste))
        #expect(pb.string(forType: .string) == "keep me")
    }

    @Test func autoSubmitFiresOnceAfterInsertion() async {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.autoSubmit = .commandEnter
        var keys: [InsertionSettings.AutoSubmit] = []
        _ = await inserter(s, pb: pb, keys: { keys.append($0) }).insert("send it", bundleID: "com.apple.Terminal")
        #expect(keys == [.commandEnter])
    }

    @Test func externalScriptReceivesTextOnStdin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utter-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let script = dir.appendingPathComponent("insert.sh")
        try "#!/bin/sh\ncat > '\(out.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.method = .externalScript; s.externalScriptPath = script.path
        let report = await inserter(s, pb: pb).insert("héllo from Utter", bundleID: nil)
        #expect(report.result == .handledByScript)
        #expect(try String(contentsOf: out, encoding: .utf8) == "héllo from Utter")
    }

    @Test func externalScriptFailuresArePlainEnglish() async throws {
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.method = .externalScript; s.externalScriptPath = "/nonexistent/script"
        let missing = await inserter(s, pb: pb).insert("x", bundleID: nil)
        #expect(missing.result == .failed("The insertion script is missing or not executable. Check Settings → Text Insertion."))
        s.externalScriptPath = "/usr/bin/false"
        let failing = await inserter(s, pb: pb).insert("x", bundleID: nil)
        #expect(failing.result == .failed("The insertion script failed (exit code 1)."))
    }

    @Test func hungScriptIsStopped() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("utter-hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.method = .externalScript; s.externalScriptPath = script.path
        let ins = inserter(s, pb: pb)
        ins.scriptTimeout = 0.3
        let started = Date()
        let report = await ins.insert("text", bundleID: nil)
        #expect(report.result == .failed("The insertion script took longer than 1 second and was stopped."))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
