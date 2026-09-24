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
        let inserter = PasteInserter(pasteboard: pb, postKeystroke: false)
        inserter.quietPeriod = .milliseconds(50)

        // Simulate the target app handling ⌘V: it reads the promised string.
        var readByTarget: String?
        Task { @MainActor in
            readByTarget = pb.string(forType: .string)
        }
        let outcome = await inserter.insert("Hello from Utter")
        #expect(readByTarget == "Hello from Utter")
        #expect(outcome == .pasted(receipt: true))
        #expect(pb.string(forType: .string) == "SENTINEL")
    }

    @Test func pasteMarksTranscriptTransientForClipboardManagers() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let inserter = PasteInserter(pasteboard: pb, postKeystroke: false)
        inserter.receiptTimeout = .milliseconds(100)
        var types: [NSPasteboard.PasteboardType] = []
        Task { @MainActor in types = pb.types ?? [] }
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
        let inserter = PasteInserter(pasteboard: pb, postKeystroke: false)
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
        let inserter = PasteInserter(pasteboard: pb, postKeystroke: false)
        inserter.receiptTimeout = .milliseconds(200)
        Task { @MainActor in
            pb.clearContents()
            pb.setString("user copied this meanwhile", forType: .string)
        }
        _ = await inserter.insert("transcript")
        #expect(pb.string(forType: .string) == "user copied this meanwhile")
    }
}
