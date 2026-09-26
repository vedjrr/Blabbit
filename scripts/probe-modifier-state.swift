import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .combinedSessionState)!
src.userData = 0x5554_5452 // Say Less's marker: the running app ignores these
func show(_ label: String) {
    usleep(50_000)
    let f = CGEventSource.flagsState(.hidSystemState)
    print(label.padding(toLength: 34, withPad: " ", startingAt: 0),
          "flagsState right⌥ bit:", f.rawValue & 0x40 != 0,
          " keyState(61):", CGEventSource.keyState(.hidSystemState, key: 61))
}
func flags(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: 61, keyDown: down)!
    e.type = .flagsChanged
    e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
    e.post(tap: .cghidEventTap)
}
show("start")
flags(true); show("right ⌥ held")
for d in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 106, keyDown: d)!; e.flags = []; e.post(tap: .cghidEventTap) }
show("after posting F16 with flags []")
flags(false); show("right ⌥ released")
