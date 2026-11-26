import CoreGraphics
import Foundation

enum RemoteInputTests {
    static func run(_ check: (Bool, String) -> Void) {
        let remote = ShortcutTransformer.isRemoteControl(bundleIdentifier: "com.netease.uuremote")
        check(remote, "installed UU Remote uses native input")
        for identifier in ["", "com.apple.TextEdit", "com.apple.Terminal", "com.quark.desktop",
                           "cn.qwenwork.desktop.mac", "com.netease.uuremote.helper",
                           "com.netease.uuremote.updater", "com.netease.uuremote.fake"] {
            check(!ShortcutTransformer.isRemoteControl(bundleIdentifier: identifier),
                  "remote policy matches exact application identities: \(identifier)")
        }

        for code in ShortcutTransformer.shortcutKeys {
            for deviceBits: UInt64 in [0, 1, 0x2000, 0x2001] {
                var transformer = ShortcutTransformer()
                let flags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue
                    | CGEventFlags.maskAlphaShift.rawValue | deviceBits)
                let down = transformer.transformedFlags(type: .keyDown, keyCode: code, flags: flags, bypass: remote)
                check(down == nil, "UU Ctrl shortcut retains all physical modifier bits")
                check(transformer.transformedFlags(type: .keyDown, keyCode: code, flags: flags, bypass: false) == nil,
                      "a UU-held key cannot become a local mapped repeat during focus change")
                check(transformer.transformedFlags(type: .keyUp, keyCode: code, flags: [], bypass: false) == nil,
                      "UU key release stays native after returning to a local app")
                check(transformer.transformedFlags(type: .keyDown, keyCode: code, flags: flags, bypass: false)?.contains(.maskCommand) == true,
                      "fresh local Ctrl shortcut resumes automatically")
                check(transformer.transformedFlags(type: .keyUp, keyCode: code, flags: [], bypass: true)?.contains(.maskCommand) == true,
                      "a previously mapped local down retains its matching up when entering UU")
                check(transformer.mappedKeysDown.isEmpty, "focus changes leave no held mapped shortcut")
            }
        }

        var keys = SwitcherKeyState()
        keys.isEnabled = true
        keys.setInputBypassed(true)
        for code: CGKeyCode in [48, 53, 123, 124, 125, 126, 36, 76, 0, 8] {
            for flags: CGEventFlags in [[], .maskAlternate, [.maskAlternate, .maskShift], .maskControl, .maskCommand] {
                let down = keys.handle(.keyDown, key: code, flags: flags, canBegin: true, canNavigate: true)
                check(!down.consume && down.action == nil, "new remote navigation/shortcut down passes through")
                let up = keys.handle(.keyUp, key: code, flags: flags)
                check(!up.consume && up.action == nil, "new remote navigation/shortcut up passes through")
            }
        }
        check(keys.isEnabled && !keys.isSelecting, "passthrough keeps the user's global feature setting")
        keys.reset()
        check(keys.inputBypassed && !keys.handle(.keyDown, key: 48, flags: .maskAlternate).consume,
              "tap interruption reset retains the remote application policy")

        keys.setInputBypassed(false)
        keys.reset()
        let start = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
        check(start.consume && start.action == .begin(reverse: false), "returning local restores Alt+Tab")
        _ = keys.handle(.keyDown, key: 124, flags: .maskAlternate, canNavigate: true)
        keys.setInputBypassed(true)
        check(!keys.isSelecting, "entering UU cancels the old local selection")
        check(keys.handle(.flagsChanged, key: 58, flags: []).action == nil,
              "late Option release cannot activate an old local selection in UU")
        check(keys.handle(.keyUp, key: 124, flags: []).consume, "old local arrow release is still paired")
        check(keys.handle(.keyUp, key: 48, flags: []).consume, "old local Tab release is still paired")
        check(keys.swallowedKeys.isEmpty, "remote transition drains all swallowed local keys")
        check(!keys.handle(.keyDown, key: 48, flags: .maskAlternate).consume, "new remote Alt+Tab stays native after draining")
        keys.setInputBypassed(false)
        check(!keys.handle(.keyDown, key: 48, flags: .maskAlternate, isRepeat: true).consume,
              "a held remote Tab cannot start a local chooser on repeat")
        check(!keys.handle(.keyUp, key: 48, flags: .maskAlternate).consume,
              "a remote Tab up is not swallowed by the local app")
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == .begin(reverse: false),
              "fresh local Alt+Tab works after a remote-held key ends")
        keys.isEnabled = false
        keys.setInputBypassed(true)
        keys.setInputBypassed(false)
        check(!keys.isEnabled, "leaving UU cannot enable a user-disabled feature")

        check(ShortcutTransformer.isTerminal(bundleIdentifier: "com.apple.Terminal"), "terminal Ctrl rule is preserved")
        var terminalKeys = SwitcherKeyState()
        terminalKeys.isEnabled = true
        terminalKeys.setInputBypassed(ShortcutTransformer.isRemoteControl(bundleIdentifier: "com.apple.Terminal"))
        check(terminalKeys.handle(.keyDown, key: 48, flags: .maskAlternate).consume,
              "terminal Ctrl exception still allows local Alt+Tab")
    }
}
