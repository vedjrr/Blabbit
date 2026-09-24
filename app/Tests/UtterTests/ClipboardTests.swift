import AppKit
import Testing
@testable import UtterKit

/// Uses private named pasteboards so tests never touch the user's clipboard.
@MainActor @Suite struct ClipboardTests {
    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.utter.test.\(UUID().uuidString)"))
    }

    @Test func snapshotRestoresEveryItemAndType() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("SENTINEL", forType: .string)
        first.setData(Data("{\\rtf1 SENTINEL}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), forType: .png)
        second.setString("file:///tmp/example.txt", forType: .fileURL)
        #expect(pb.writeObjects([first, second]))

        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.items.count == 2)

        pb.clearContents()
        pb.setString("transcript", forType: .string)
        snapshot.restore(to: pb)

        #expect(PasteboardSnapshot.capture(pb) == snapshot)
        #expect(pb.pasteboardItems?.first?.string(forType: .string) == "SENTINEL")
        #expect(pb.pasteboardItems?.last?.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
    }

    @Test func emptyClipboardStaysEmpty() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.setString("transcript", forType: .string)
        snapshot.restore(to: pb)
        #expect((pb.pasteboardItems ?? []).isEmpty)
    }

    @Test func pasteRestoresClipboardAfterTheTargetReadsIt() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL", forType: .string)
        // The "target app" handles ⌘V by reading the promised string.
        var readByTarget: String?
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            readByTarget = pb.string(forType: .string)
            return nil
        }
        inserter.quietPeriod = .milliseconds(50)
        let outcome = await inserter.insert("Hello from Utter")
        #expect(readByTarget == "Hello from Utter")
        #expect(outcome == .pasted(receipt: true))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func pasteMarksTranscriptTransientForClipboardManagers() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            types = pb.types ?? []
            return nil
        }
        inserter.receiptTimeout = .milliseconds(100)
        _ = await inserter.insert("secret-ish")
        for marker in PasteInserter.transientMarkers {
            #expect(types.contains(marker))
        }
    }

    @Test func noReceiptStillRestoresAfterTimeout() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL", forType: .string)
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) { nil }
        inserter.receiptTimeout = .milliseconds(150)
        let outcome = await inserter.insert("nobody reads this")
        #expect(outcome == .pasted(receipt: false))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func doesNotClobberANewerCopy() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL", forType: .string)
        // The user copies something else right after the paste is triggered.
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            pb.clearContents()
            pb.setString("user copied this meanwhile", forType: .string)
            return nil
        }
        inserter.receiptTimeout = .milliseconds(200)
        _ = await inserter.insert("transcript")
        #expect(pb.string(forType: .string) == "user copied this meanwhile")
    }

    @Test func overlappingInsertsAreSerialisedAndRestoreTheOriginal() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL", forType: .string)
        var reads: [String?] = []
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            reads.append(pb.string(forType: .string))
            return nil
        }
        inserter.quietPeriod = .milliseconds(30)
        async let first = inserter.insert("first")
        async let second = inserter.insert("second")
        let outcomes = await [first, second]
        #expect(outcomes == [.pasted(receipt: true), .pasted(receipt: true)])
        // Each paste delivered its own text, in order.
        #expect(reads == ["first", "second"])
        // Had they interleaved, the second snapshot would have captured "first"'s promise.
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func failedKeystrokeRestoresAndReportsFailure() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL", forType: .string)
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) { "Could not create the paste keystroke." }
        let outcome = await inserter.insert("transcript")
        #expect(outcome == .failed("Could not create the paste keystroke."))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }
}
