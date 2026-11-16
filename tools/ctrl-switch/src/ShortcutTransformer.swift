import CoreGraphics
import Foundation

/// Only keyboard events for the seven explicitly requested Ctrl combinations are changed.
/// Modifier-key events are never rewritten, so the physical Ctrl/Command keys keep their identity.
struct ShortcutTransformer {
    static let shortcutKeys: Set<CGKeyCode> = [0, 1, 6, 7, 8, 9, 3] // A, S, Z, X, C, V, F
    static let modifierMask: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
    private static let deviceControlMask: UInt64 = 0x00000001 | 0x00002000
    private static let deviceLeftCommandMask: UInt64 = 0x00000008

    var isEnabled = true
    private(set) var mappedKeysDown: Set<CGKeyCode> = []
    private var bypassedKeysDown: Set<CGKeyCode> = []

    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "dev.warp.Warp", "com.mitchellh.ghostty",
        "KingToolbox.WindTerm", "com.kingToolbox.WindTerm", "com.kingToolbox.WindTerm.WindTerm"
    ]

    static func isTerminal(bundleIdentifier: String) -> Bool {
        terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    mutating func transformedFlags(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        bypass: Bool
    ) -> CGEventFlags? {
        guard Self.shortcutKeys.contains(keyCode) else { return nil }

        if type == .keyUp {
            bypassedKeysDown.remove(keyCode)
            guard mappedKeysDown.remove(keyCode) != nil else { return nil }
            // Pair a remapped key-down even if Ctrl was released or the switch changed meanwhile.
            return Self.commandFlags(from: flags)
        }

        guard type == .keyDown else { return nil }
        let modifiers = flags.intersection(Self.modifierMask)

        // An ordinary held key must not start producing shortcuts on an auto-repeat
        // just because the user turned the switch on or pressed Ctrl midway.
        if bypassedKeysDown.contains(keyCode) { return nil }
        if mappedKeysDown.contains(keyCode) {
            guard modifiers == .maskControl else { return nil }
            return Self.commandFlags(from: flags)
        }

        guard isEnabled, !bypass, modifiers == .maskControl else {
            bypassedKeysDown.insert(keyCode)
            return nil
        }

        mappedKeysDown.insert(keyCode)
        return Self.commandFlags(from: flags)
    }

    mutating func reset() {
        mappedKeysDown.removeAll()
        bypassedKeysDown.removeAll()
    }

    private static func commandFlags(from flags: CGEventFlags) -> CGEventFlags {
        let cleared = flags.rawValue & ~CGEventFlags.maskControl.rawValue & ~deviceControlMask
        return CGEventFlags(rawValue: cleared | CGEventFlags.maskCommand.rawValue | deviceLeftCommandMask)
    }
}
