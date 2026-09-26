import AppKit
import Testing
@testable import SayLessKit

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
        let suite = "dev.sayless.test.\(UUID().uuidString)"
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
    func makePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("dev.sayless.test.\(UUID().uuidString)")) }

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let script = dir.appendingPathComponent("insert.sh")
        try "#!/bin/sh\ncat > '\(out.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pb = makePasteboard(); defer { pb.releaseGlobally() }
        var s = InsertionSettings(); s.method = .externalScript; s.externalScriptPath = script.path
        let report = await inserter(s, pb: pb).insert("héllo from Say Less", bundleID: nil)
        #expect(report.result == .handledByScript)
        #expect(try String(contentsOf: out, encoding: .utf8) == "héllo from Say Less")
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
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-hang-\(UUID().uuidString).sh")
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
        // Worst case by design: 0.3 s limit + 1 s after SIGTERM + 1 s after SIGKILL
        // = 2.3 s. Under the full parallel suite the exit callback has arrived up
        // to ~0.7 s late (3.04 s seen twice), so allow scheduling slack.
        #expect(Date().timeIntervalSince(started) < 4)
    }
}

/// Blocking script-runner tests. Not on the main actor: they block for
/// seconds, which would stall the async main-actor tests running alongside.
@Suite struct ScriptRunnerTests {
    @Test func timedOutScriptTakesItsChildrenWithIt() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let parent = try script("sleep 30 &\necho $! > '\(pidFile.path)'\nwait")
        defer { try? FileManager.default.removeItem(at: parent) }
        // Long enough for the shell to start and write the PID while other suites run in parallel.
        let result = TextInserter.runScriptBlocking(path: parent.path, text: "x", timeout: 1.5)
        #expect(result == .failed("The insertion script took longer than 2 seconds and was stopped."))
        let child = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Reaped by launchd shortly after SIGKILL.
        var alive = true
        for _ in 0..<50 where alive {
            alive = kill(child, 0) == 0
            if alive { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(!alive, "the script's child \(child) outlived the timeout")
    }

    func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sayless-script-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func scriptThatIgnoresStdinCannotCrashOrHangSayLess() throws {
        let quits = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: quits) }
        let big = String(repeating: "dictated text ", count: 20_000) // ~280 KB, far above the pipe buffer
        #expect(TextInserter.runScriptBlocking(path: quits.path, text: big, timeout: 5) == .handledByScript)
        let neverReads = try script("sleep 0.3; exit 0")
        defer { try? FileManager.default.removeItem(at: neverReads) }
        #expect(TextInserter.runScriptBlocking(path: neverReads.path, text: big, timeout: 5) == .handledByScript)
    }

    @Test func scriptIgnoringSigtermIsKilled() throws {
        let stubborn = try script("trap '' TERM\nwhile true; do sleep 0.05; done")
        defer { try? FileManager.default.removeItem(at: stubborn) }
        let started = Date()
        let result = TextInserter.runScriptBlocking(path: stubborn.path, text: "x", timeout: 0.3)
        #expect(result == .failed("The insertion script took longer than 1 second and was stopped."))
        // Worst case by design: 0.3 s limit + 1 s after SIGTERM + 1 s after SIGKILL
        // = 2.3 s. Under the full parallel suite the exit callback has arrived up
        // to ~0.7 s late (3.04 s seen twice), so allow scheduling slack.
        #expect(Date().timeIntervalSince(started) < 4)
    }
}

@MainActor @Suite struct InsertionPreferenceTests {
    @Test func newlinesCanBecomeSpaces() {
        var s = InsertionSettings()
        #expect(s.finalText("first\nsecond") == "first\nsecond")
        s.newlines = .spaces
        #expect(s.finalText("first\n\nsecond\nthird") == "first second third")
        s.appendTrailingSpace = true
        #expect(s.finalText("a\nb") == "a b ")
    }

    @Test func clipboardPreservationCanBeTurnedOff() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.sayless.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        let paste = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            _ = pb.string(forType: .string)
            return nil
        }
        paste.quietPeriod = .milliseconds(20)
        paste.restoreClipboard = false
        #expect(await paste.insert("keep me") == .pasted(receipt: true))
        #expect(pb.string(forType: .string) == "keep me", "the transcript stays on the clipboard")
        paste.restoreClipboard = true
        pb.clearContents(); pb.setString("SENTINEL", forType: .string)
        #expect(await paste.insert("restore") == .pasted(receipt: true))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func newSettingsDecodeFromOldData() throws {
        let old = try JSONDecoder().decode(InsertionSettings.self, from: Data(#"{"method":"automatic","copyToClipboard":true}"#.utf8))
        #expect(old.restoreClipboard && old.newlines == .keep && old.copyToClipboard)
    }
}

/// PARITY F23: an administrator's UpdateChecksDisabled turns update checks off.
@Suite struct UpdatePolicyTests {
    @Test func lockFollowsTheDefault() throws {
        let suite = "dev.sayless.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!UpdatePolicy.isLocked(defaults))
        defaults.set(true, forKey: UpdatePolicy.key)
        #expect(UpdatePolicy.isLocked(defaults))
        #expect(!UpdatePolicy.isManaged(defaults), "set by the user, not a profile")
    }
}
