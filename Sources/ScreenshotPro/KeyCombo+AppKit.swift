import AppKit
import Carbon.HIToolbox
import ScreenshotProCore

/// AppKit helpers for `KeyCombo`: menu key equivalents, display names for keys Core does not
/// name (F17-F20), and the rules for which combos may be global hotkeys.
extension KeyCombo {
    /// Function keys allowed as a hotkey without Command or Control.
    static let standaloneKeyCodes: Set<UInt32> = [
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].reduce(into: Set<UInt32>()) { $0.insert(UInt32($1)) }

    private static let extraKeyNames: [UInt32: String] = [
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    /// Function key codes mapped to their number, for the NSF<n>FunctionKey characters.
    private static let functionKeyNumbers: [UInt32: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ].reduce(into: [UInt32: Int]()) { $0[UInt32($1.key)] = $1.value }

    private static let specialKeyCharacters: [UInt32: Int] = [
        kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
        kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
        kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
    ].reduce(into: [UInt32: Int]()) { $0[UInt32($1.key)] = $1.value }

    /// Like `displayString`, but also names F17-F20.
    var label: String {
        guard let name = KeyCombo.extraKeyNames[keyCode] else { return displayString }
        let modifierPart = String(displayString.prefix { "⌃⌥⇧⌘".contains($0) })
        return modifierPart + name
    }

    /// Key equivalent string for an NSMenuItem (function keys use their private-use characters).
    var menuKeyEquivalent: String {
        if let n = KeyCombo.functionKeyNumbers[keyCode], let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return String(Character(scalar))
        }
        if let code = KeyCombo.specialKeyCharacters[keyCode], let scalar = UnicodeScalar(code) {
            return String(Character(scalar))
        }
        return keyEquivalent ?? ""
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// Since macOS 15 hotkeys need Command or Control; F13-F20 work on their own.
    var isAllowedAsGlobalHotkey: Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || KeyCombo.standaloneKeyCodes.contains(keyCode)
    }

    /// Builds a combo from a key-down event (device-independent modifiers only).
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}

extension NSMenuItem {
    /// Shows `combo` as the item's shortcut hint, or clears it.
    func setShortcutHint(_ combo: KeyCombo?) {
        if let combo, !combo.menuKeyEquivalent.isEmpty {
            keyEquivalent = combo.menuKeyEquivalent
            keyEquivalentModifierMask = combo.menuModifierMask
        } else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
        }
    }
}
