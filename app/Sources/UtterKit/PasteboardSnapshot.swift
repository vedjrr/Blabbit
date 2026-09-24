import AppKit

/// Every item and every type on a pasteboard, so it can be put back exactly
/// (text, RTF, images, file URLs, multiple items).
public struct PasteboardSnapshot: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var entries: [(type: String, data: Data)]
        public static func == (a: Item, b: Item) -> Bool {
            a.entries.map(\.type) == b.entries.map(\.type) && a.entries.map(\.data) == b.entries.map(\.data)
        }
    }

    public var items: [Item]
    /// False when the read failed (e.g. pasteboard access denied on macOS 15.4+).
    /// An unreadable snapshot is never restored, so a failed read can't wipe the clipboard.
    public var readable: Bool

    public init(items: [Item], readable: Bool = true) {
        self.items = items
        self.readable = readable
    }

    @MainActor
    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        if #available(macOS 15.4, *), pasteboard == .general, pasteboard.accessBehavior == .alwaysDeny {
            return PasteboardSnapshot(items: [], readable: false)
        }
        guard let pbItems = pasteboard.pasteboardItems else {
            return PasteboardSnapshot(items: [], readable: false)
        }
        let items = pbItems.map { item in
            Item(entries: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
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
