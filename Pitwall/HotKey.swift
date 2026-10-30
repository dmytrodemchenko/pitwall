import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let standard = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey), key: "C")

    var display: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        let names = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_LeftArrow: "←",
                     kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
                     kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
                     kVK_F11: "F11", kVK_F12: "F12"]
        let key = names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(m), key: key.isEmpty ? "#\(event.keyCode)" : key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

@MainActor
final class HotKey {
    static let codeKey = "hotkeyCode", modifiersKey = "hotkeyModifiers", nameKey = "hotkeyName"

    var onPress: () -> Void = {}
    private(set) var combo: KeyCombo?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var defaults = UserDefaults.standard

    var saved: KeyCombo {
        guard let name = defaults.string(forKey: Self.nameKey) else { return .standard }
        return KeyCombo(keyCode: UInt32(defaults.integer(forKey: Self.codeKey)),
                        modifiers: UInt32(defaults.integer(forKey: Self.modifiersKey)), key: name)
    }

    func register(_ new: KeyCombo) throws {
        installHandler()
        if Self.isSystemShortcut(new) {
            throw ActionError("\(new.display) is a macOS shortcut (System Settings → Keyboard → Keyboard Shortcuts). Choose another.")
        }
        let previous = combo
        unregister()
        let status = carbonRegister(new)
        guard status == noErr else {
            if let previous, carbonRegister(previous) == noErr { combo = previous }
            throw ActionError(status == eventHotKeyExistsErr
                ? "\(new.display) is already used by another app. Choose another."
                : "Couldn't register \(new.display) (error \(status)).")
        }
        combo = new
    }

    func change(to new: KeyCombo) throws {
        try register(new)
        defaults.set(Int(new.keyCode), forKey: Self.codeKey)
        defaults.set(Int(new.modifiers), forKey: Self.modifiersKey)
        defaults.set(new.key, forKey: Self.nameKey)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        combo = nil
    }

    private func carbonRegister(_ c: KeyCombo) -> OSStatus {
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(c.keyCode, c.modifiers, EventHotKeyID(signature: 0x434D_4F4E, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &r)
        if status == noErr { ref = r }
        return status
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return entries.contains {
            ($0[kHISymbolicHotKeyEnabled] as? Bool) == true
                && ($0[kHISymbolicHotKeyCode] as? Int).map(UInt32.init) == combo.keyCode
                && ($0[kHISymbolicHotKeyModifiers] as? Int).map { UInt32($0) & mask } == combo.modifiers
        }
    }
}
