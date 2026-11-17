import CoreGraphics
import Foundation

@main
struct ShortcutTransformerTests {
    static var assertions = 0

    static func writeReport(failed: Int, message: String? = nil) {
        guard let index = CommandLine.arguments.firstIndex(of: "--report"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        var report: [String: Any] = ["passed": assertions - failed, "failed": failed]
        if let message { report["message"] = message }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        } catch {
            fputs("Cannot write self-test report: \(error)\n", stderr)
            exit(2)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            writeReport(failed: 1, message: message)
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func send(_ transformer: inout ShortcutTransformer, _ type: CGEventType,
                     _ key: CGKeyCode, _ flags: CGEventFlags, bypass: Bool = false) -> CGEventFlags? {
        transformer.transformedFlags(type: type, keyCode: key, flags: flags, bypass: bypass)
    }

    static func main() {
        let expectedKeys: [CGKeyCode] = [8, 9, 1, 0, 7, 3, 6]
        check(ShortcutTransformer.shortcutKeys == Set(expectedKeys), "exactly C, V, S, A, X, F, Z")
        for key in expectedKeys {
            for deviceBits: UInt64 in [0, 0x1, 0x2000, 0x2001] {
                var transformer = ShortcutTransformer()
                let input = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | deviceBits)
                let down = send(&transformer, .keyDown, key, input)
                check(down?.contains(.maskCommand) == true, "Ctrl+\(key) maps to Command")
                check(down?.contains(.maskControl) == false, "Control is removed on matched key only")
                check((down!.rawValue & 0x2001) == 0, "left/right physical control bits removed")
                let up = send(&transformer, .keyUp, key, input)
                check(up?.contains(.maskCommand) == true, "paired key release")
                check(transformer.mappedKeysDown.isEmpty, "no lingering mapped keys")
            }
        }

        // All other letter keys and all unmodified keys must retain their original events.
        for code in CGKeyCode(0)...CGKeyCode(127) where !expectedKeys.contains(code) {
            var transformer = ShortcutTransformer()
            check(send(&transformer, .keyDown, code, .maskControl) == nil, "other Ctrl key \(code) passes through")
            check(send(&transformer, .keyUp, code, .maskControl) == nil, "other release \(code) passes through")
        }

        for key in expectedKeys {
            for modifiers: CGEventFlags in [[], .maskCommand, .maskShift, .maskAlternate,
                [.maskControl, .maskShift], [.maskControl, .maskAlternate],
                [.maskControl, .maskCommand], [.maskControl, .maskSecondaryFn],
                [.maskControl, .maskShift, .maskAlternate, .maskCommand]] {
                var transformer = ShortcutTransformer()
                check(send(&transformer, .keyDown, key, modifiers) == nil, "nonmatching modifiers pass through")
                check(send(&transformer, .keyUp, key, modifiers) == nil, "unmodified paired release")
            }
        }

        var transformer = ShortcutTransformer()
        check(send(&transformer, .flagsChanged, 59, .maskControl) == nil, "Ctrl key identity is unchanged")
        check(send(&transformer, .flagsChanged, 55, .maskCommand) == nil, "Command key identity is unchanged")
        check(send(&transformer, .flagsChanged, 0, .maskControl) == nil, "modifier-only event is unchanged")

        let withCaps: CGEventFlags = [.maskControl, .maskAlphaShift]
        let capsResult = send(&transformer, .keyDown, 8, withCaps)
        check(capsResult?.contains(.maskAlphaShift) == true, "Caps Lock state is preserved")
        check(capsResult?.contains(.maskCommand) == true, "Caps Lock still permits copy")
        _ = send(&transformer, .keyUp, 8, withCaps)

        // Key-up must still pair correctly when the user releases Ctrl before C.
        _ = send(&transformer, .keyDown, 8, .maskControl)
        check(send(&transformer, .keyUp, 8, [])?.contains(.maskCommand) == true, "Ctrl released before C")

        // Disabling while a key is held affects new presses without leaving an unpaired Command key.
        _ = send(&transformer, .keyDown, 8, .maskControl)
        transformer.isEnabled = false
        check(send(&transformer, .keyDown, 9, .maskControl) == nil, "new paste after disabling passes through")
        check(send(&transformer, .keyUp, 8, [])?.contains(.maskCommand) == true, "old copy still gets matching release")
        _ = send(&transformer, .keyUp, 9, .maskControl)
        check(transformer.mappedKeysDown.isEmpty, "disabled mode has no mapped keys left")

        transformer = ShortcutTransformer()
        check(send(&transformer, .keyDown, 8, .maskControl, bypass: true) == nil, "terminal Ctrl+C preserved")
        check(send(&transformer, .keyUp, 8, .maskControl, bypass: true) == nil, "terminal key-up preserved")
        for identifier in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            check(ShortcutTransformer.isTerminal(bundleIdentifier: identifier), "terminal exclusion \(identifier)")
        }
        check(!ShortcutTransformer.isTerminal(bundleIdentifier: "com.apple.TextEdit"), "TextEdit is enabled")
        check(ShortcutTransformer.isTerminal(bundleIdentifier: "KingToolbox.WindTerm"), "installed WindTerm retains terminal controls")

        transformer = ShortcutTransformer()
        check(send(&transformer, .keyDown, 0, []) == nil, "plain A is unchanged")
        check(send(&transformer, .keyDown, 0, .maskControl) == nil, "holding ordinary A cannot become Ctrl+A on repeat")
        _ = send(&transformer, .keyUp, 0, [])
        check(send(&transformer, .keyDown, 0, .maskControl) != nil, "a fresh Ctrl+A works")
        check(send(&transformer, .keyDown, 0, .maskControl) != nil, "valid shortcut repeats work")
        check(send(&transformer, .keyDown, 0, [.maskControl, .maskShift]) == nil, "repeat with added Shift stays unchanged")
        _ = send(&transformer, .keyUp, 0, [])

        transformer.isEnabled = false
        _ = send(&transformer, .keyDown, 6, .maskControl)
        transformer.isEnabled = true
        check(send(&transformer, .keyDown, 6, .maskControl) == nil, "enabling mid-hold does not convert a repeat")
        _ = send(&transformer, .keyUp, 6, .maskControl)
        check(send(&transformer, .keyDown, 6, .maskControl) != nil, "fresh undo works after enabling")

        transformer.reset()
        check(transformer.mappedKeysDown.isEmpty, "session reset clears held shortcuts")
        check(send(&transformer, .keyUp, 6, []) == nil, "no stale mapping after reset")
        SwitcherStateTests.run { condition, message in check(condition, message) }
        PreviewNavigationTests.run { condition, message in check(condition, message) }
        writeReport(failed: 0)
        print("PASS: \(assertions) assertions; Ctrl mappings, terminal exclusions, Alt+Tab selection, key releases, preview budget and timeout admission.")
    }
}
