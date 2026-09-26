import AppKit

/// Source of pasteboard contents, injectable so tests can simulate denied or
/// partial reads.
public protocol PasteboardReading {
    /// Every item as (type, data) pairs; `nil` data means that type could not be read.
    /// Returns `nil` if the pasteboard itself could not be read.
    func readItems() -> [[(type: String, data: Data?)]]?
}

extension NSPasteboard: PasteboardReading {
    public func readItems() -> [[(type: String, data: Data?)]]? {
        pasteboardItems?.map { item in item.types.map { ($0.rawValue, item.data(forType: $0)) } }
    }
}

/// Whether Blabbit may read the general pasteboard without macOS asking the user
/// each time (macOS 15.4+ pasteboard privacy).
public enum ClipboardAccess: Equatable, Sendable {
    case allowed
    /// Reading would show a system alert ("ask"/never-decided) — don't read per dictation.
    case wouldAsk
    case denied

    public static func current(for pasteboard: NSPasteboard) -> ClipboardAccess {
        guard #available(macOS 15.4, *), pasteboard == .general else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return .wouldAsk
        }
    }
}

/// Every item and every type on a pasteboard, so it can be put back exactly
/// (text, RTF, images, file URLs, multiple items).
public struct PasteboardSnapshot: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var entries: [(type: String, data: Data)]
        public static func == (a: Item, b: Item) -> Bool {
            a.entries.map(\.type) == b.entries.map(\.type) && a.entries.map(\.data) == b.entries.map(\.data)
        }
    }

    /// Snapshots larger than this are not kept (and so not restored).
    public static let maxBytes = 64 * 1024 * 1024

    public var items: [Item]
    /// False when the snapshot is incomplete (access denied, a type returned no
    /// data, or too large). An unreadable snapshot is never restored, so a
    /// failed read can't wipe the user's clipboard.
    public var readable: Bool

    public init(items: [Item], readable: Bool = true) {
        self.items = items
        self.readable = readable
    }

    public static let unreadable = PasteboardSnapshot(items: [], readable: false)

    public static func capture(from reader: PasteboardReading, maxBytes: Int = PasteboardSnapshot.maxBytes) -> PasteboardSnapshot {
        guard let raw = reader.readItems() else { return .unreadable }
        var total = 0
        var items: [Item] = []
        for rawItem in raw {
            var entries: [(type: String, data: Data)] = []
            for (type, data) in rawItem {
                guard let data else { return .unreadable }
                total += data.count
                if total > maxBytes { return .unreadable }
                entries.append((type, data))
            }
            items.append(Item(entries: entries))
        }
        return PasteboardSnapshot(items: items, readable: true)
    }

    /// Writes the snapshot back. Returns the pasteboard's new change count.
    @MainActor @discardableResult
    public func restore(to pasteboard: NSPasteboard) -> Int {
        guard readable else {
            Log.error("clipboard could not be read before pasting, so it was not restored")
            return pasteboard.changeCount
        }
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { item in
            let pbItem = NSPasteboardItem()
            for entry in item.entries {
                pbItem.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return pbItem
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
        return pasteboard.changeCount
    }
}
