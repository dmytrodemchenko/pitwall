import Carbon.HIToolbox
import XCTest
@testable import Pitwall

@MainActor
final class HotKeyTests: XCTestCase {
    /// ⌃⌥⇧⌘F19: nobody else uses it.
    private let rare = KeyCombo(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F19")

    func testDefaultIsOptionCommandC() {
        XCTAssertEqual(KeyCombo.standard.display, "⌥⌘C")
        let hotKey = HotKey()
        hotKey.defaults = UserDefaults(suiteName: "test-\(UUID())")!
        XCTAssertEqual(hotKey.saved, .standard)
    }

    func testRecordedFromAKeyEvent() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ chars: String, _ code: Int) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: UInt16(code))!
        }
        let combo = try XCTUnwrap(KeyCombo(event: event([.control, .shift], "k", kVK_ANSI_K)))
        XCTAssertEqual(combo.display, "⌃⇧K")
        XCTAssertEqual(combo.modifiers, UInt32(controlKey | shiftKey))
        XCTAssertEqual(KeyCombo(event: event([.command], " ", kVK_Space))?.display, "⌘Space")
        XCTAssertNil(KeyCombo(event: event([.shift], "k", kVK_ANSI_K))) // would swallow typing
    }

    func testTakenComboIsRefusedAndTheCurrentOneStays() throws {
        let first = HotKey(), second = HotKey()
        defer { first.unregister(); second.unregister() }
        try first.register(rare)
        let mine = KeyCombo(keyCode: UInt32(kVK_F18), modifiers: rare.modifiers, key: "F18")
        try second.register(mine)
        XCTAssertThrowsError(try second.register(rare)) {
            XCTAssertTrue($0.localizedDescription.contains("already used"), $0.localizedDescription)
        }
        XCTAssertEqual(second.combo, mine)
        XCTAssertEqual(first.combo, rare)
    }

    func testMacOSShortcutIsRefused() throws {
        let spotlight = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), key: "Space")
        try XCTSkipUnless(HotKey.isSystemShortcut(spotlight), "⌘Space is turned off on this Mac")
        XCTAssertThrowsError(try HotKey().register(spotlight)) {
            XCTAssertTrue($0.localizedDescription.contains("macOS shortcut"))
        }
        XCTAssertFalse(HotKey.isSystemShortcut(rare))
    }

    func testSessionCountPlurals() {
        XCTAssertEqual(String(localized: "\(1) sessions"), "1 session")
        XCTAssertEqual(String(localized: "\(3) sessions"), "3 sessions")
    }
}
