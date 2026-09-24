import AppKit
import Testing
@testable import UtterKit

/// Simulates a read where macOS (or the source app) withheld some data.
struct FakeReader: PasteboardReading {
    var items: [[(type: String, data: Data?)]]?
    func readItems() -> [[(type: String, data: Data?)]]? { items }
}

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

        let snapshot = PasteboardSnapshot.capture(from: pb)
        #expect(snapshot.items.count == 2)

        pb.clearContents()
        pb.setString("transcript", forType: .string)
        snapshot.restore(to: pb)

        #expect(PasteboardSnapshot.capture(from: pb) == snapshot)
        #expect(pb.pasteboardItems?.first?.string(forType: .string) == "SENTINEL")
        #expect(pb.pasteboardItems?.last?.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
    }

    @Test func emptyClipboardStaysEmpty() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pb)
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
        // Each paste delivered its own text (start order of `async let` is not
        // guaranteed; interleaving would show up as ["second", "second"]).
        #expect(reads.compactMap { $0 }.sorted() == ["first", "second"])
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

    @Test func unreadableSnapshotIsNeverRestored() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("user data we could not read", forType: .string)
        let unreadable = PasteboardSnapshot(items: [], readable: false)
        unreadable.restore(to: pb)
        #expect(pb.string(forType: .string) == "user data we could not read")
    }

    @Test func insertRecordsTimings() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let inserter = PasteInserter(pasteboard: pb, checkSecureInput: false) {
            _ = pb.string(forType: .string)
            return nil
        }
        inserter.quietPeriod = .milliseconds(20)
        _ = await inserter.insert("timed")
        let t = inserter.lastTiming
        #expect(t.pasteSentNs != nil && t.firstReadNs != nil && t.restoredNs != nil)
        #expect(t.reads == 1)
        #expect(t.firstReadNs! >= t.pasteSentNs! || t.firstReadNs! >= t.startedNs)
        #expect(t.restoredNs! > t.firstReadNs!)
    }

    @Test func partialOrDeniedReadsAreUnreadable() {
        #expect(!PasteboardSnapshot.capture(from: FakeReader(items: nil)).readable)
        let partial = FakeReader(items: [[("public.utf8-plain-text", Data("a".utf8)), ("public.rtf", nil)]])
        #expect(!PasteboardSnapshot.capture(from: partial).readable)
        let empty = FakeReader(items: [])
        #expect(PasteboardSnapshot.capture(from: empty).readable)
    }

    @Test func oversizedClipboardIsNotKept() {
        let big = FakeReader(items: [[("public.png", Data(count: 2_000))]])
        #expect(!PasteboardSnapshot.capture(from: big, maxBytes: 1_000).readable)
        #expect(PasteboardSnapshot.capture(from: big, maxBytes: 4_000).readable)
    }

    @Test func declinedReadLeavesTranscriptAsPlainClipboardText() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("user data we could not read", forType: .string)
        var typesSeenByTarget: [NSPasteboard.PasteboardType] = []
        let inserter = PasteInserter(pasteboard: pb, reader: FakeReader(items: [[("public.utf8-plain-text", nil)]]),
                                     checkSecureInput: false) {
            typesSeenByTarget = pb.types ?? []
            _ = pb.string(forType: .string)
            return nil
        }
        inserter.quietPeriod = .milliseconds(20)
        let outcome = await inserter.insert("transcript kept")
        #expect(outcome == .pasted(receipt: true))
        #expect(!inserter.lastTiming.clipboardReadable)
        // Not transient: clipboard managers may keep it, since it stays on the clipboard.
        #expect(!typesSeenByTarget.contains(PasteInserter.transientMarkers[0]))
        // A concrete copy, not a promise tied to the next dictation.
        #expect(pb.string(forType: .string) == "transcript kept")
        _ = await inserter.insert("next dictation")
        #expect(pb.string(forType: .string) == "next dictation")
    }
}
