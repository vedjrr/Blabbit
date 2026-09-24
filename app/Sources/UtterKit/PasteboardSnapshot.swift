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

    @MainActor
    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(entries: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
        return PasteboardSnapshot(items: items)
    }

    /// Writes the snapshot back. Returns the pasteboard's new change count.
    @MainActor @discardableResult
    public func restore(to pasteboard: NSPasteboard) -> Int {
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
