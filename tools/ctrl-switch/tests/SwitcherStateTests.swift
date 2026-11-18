import CoreGraphics
import Foundation

enum SwitcherStateTests {
    static func run(_ check: (Bool, String) -> Void) {
        var keys = SwitcherKeyState()
        keys.isEnabled = true
        keys.cancel()
        check(keys.handle(.flagsChanged, key: 58, flags: .maskAlternate).action == nil, "idle cancellation leaves modifier identity unchanged")
        let first = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
        check(first.consume && first.action == .begin(reverse: false), "Alt+Tab starts a session")
        check(keys.handle(.keyUp, key: 48, flags: .maskAlternate).consume, "matched Tab release consumed")
        check(keys.handle(.keyDown, key: 48, flags: [.maskAlternate, .maskShift]).action == .cycle(reverse: true), "reverse cycling")
        check(keys.handle(.flagsChanged, key: 58, flags: .maskShift).action == .commit, "Option release commits")
        check(keys.handle(.keyUp, key: 48, flags: []).consume, "Tab release after Option still paired")
        check(keys.swallowedKeys.isEmpty, "session leaves no held Tab")
        check(!keys.handle(.flagsChanged, key: 58, flags: .maskAlternate).consume, "physical Option identity retained")
        _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
        let escape = keys.handle(.keyDown, key: 53, flags: .maskAlternate)
        check(escape.consume && escape.action == .cancel, "Escape cancels")
        check(keys.handle(.keyUp, key: 53, flags: .maskAlternate).consume, "Escape release paired")
        _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == nil, "cancel waits for Option release")
        _ = keys.handle(.flagsChanged, key: 58, flags: [])
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == .begin(reverse: false), "new session after cancel")
        let other = keys.handle(.keyDown, key: 0, flags: .maskAlternate)
        check(!other.consume && other.action == .cancel, "unrelated Option+A passes and dismisses")
        keys.reset()
        check(keys.swallowedKeys.isEmpty && !keys.isSelecting, "interrupted tap clears state")
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate, isRepeat: true).action == nil, "held ordinary Tab never starts on a repeat")
        for extra: CGEventFlags in [.maskControl, .maskCommand, .maskSecondaryFn] {
            keys.reset()
            let flags = extra.union(.maskAlternate)
            let result = keys.handle(.keyDown, key: 48, flags: flags)
            check(!result.consume && result.action == nil, "extra modifier shortcut unchanged")
            _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
            check(keys.handle(.flagsChanged, key: 55, flags: flags).action == .cancel, "extra modifier cancels active chooser")
            check(keys.handle(.keyUp, key: 48, flags: flags).consume, "release paired after extra modifier")
        }
        for code in CGKeyCode(0)...127 where code != 48 {
            keys.reset()
            let ordinary = keys.handle(.keyDown, key: code, flags: .maskAlternate)
            check(!ordinary.consume && ordinary.action == nil, "unrelated Option key \(code) untouched")
        }
        keys.reset()
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate, canBegin: false).action == nil, "empty inventory passes through")
        keys.isEnabled = false
        check(!keys.handle(.keyDown, key: 48, flags: .maskAlternate).consume, "disabled feature restores Option+Tab")
        keys.isEnabled = true
        _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
        keys.isEnabled = false
        keys.cancel()
        check(keys.handle(.keyUp, key: 48, flags: []).consume, "disabling mid-hold still consumes matched up")

        keys.reset(); keys.isEnabled = true
        _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
        keys.pinAfterClose()
        check(keys.isSelecting && keys.isPinned, "close retains a selectable pinned chooser")
        check(keys.handle(.flagsChanged, key: 58, flags: []).action == nil && keys.isSelecting,
              "Option release after close neither dismisses nor activates a window")
        check(keys.handle(.keyUp, key: 48, flags: []).consume && keys.swallowedKeys.isEmpty,
              "pinning still pairs the original held Tab release")
        let pinnedTab = keys.handle(.keyDown, key: 48, flags: [], canNavigate: true)
        check(pinnedTab.consume && pinnedTab.action == .cycle(reverse: false), "pinned chooser accepts Tab without Option")
        check(keys.handle(.keyUp, key: 48, flags: []).consume, "pinned Tab release is paired")
        check(keys.handle(.keyDown, key: 48, flags: .maskShift, canNavigate: true).action == .cycle(reverse: true),
              "pinned chooser accepts Shift+Tab without Option")
        _ = keys.handle(.keyUp, key: 48, flags: [])
        for (key, direction) in SwitcherKeyState.arrows {
            let result = keys.handle(.keyDown, key: key, flags: [], canNavigate: true)
            check(result.consume && result.action == .navigate(direction), "pinned chooser accepts arrow \(key) without Option")
            check(keys.handle(.keyUp, key: key, flags: []).consume, "pinned arrow \(key) release paired")
        }
        check(keys.handle(.flagsChanged, key: 58, flags: .maskAlternate).action == nil, "repressing Option does not finish pinned chooser")
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate, canNavigate: true).action == .cycle(reverse: false),
              "Alt+Tab continues the same pinned chooser")
        _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
        _ = keys.handle(.flagsChanged, key: 58, flags: [])
        let confirm = keys.handle(.keyDown, key: 36, flags: [], canNavigate: true)
        check(confirm.consume && confirm.action == .confirm && !keys.isPinned && !keys.isSelecting,
              "Return explicitly confirms the highlighted card even after a mouse close")
        check(keys.handle(.keyUp, key: 36, flags: []).consume, "confirmation release paired")
        check(!keys.handle(.keyDown, key: 36, flags: []).consume, "ordinary Return remains native")
        keys.pinAfterClose()
        let pinnedEscape = keys.handle(.keyDown, key: 53, flags: [], canNavigate: true)
        check(pinnedEscape.consume && pinnedEscape.action == .cancel && !keys.isPinned, "Escape without Option exits pinned chooser")
        check(keys.handle(.keyUp, key: 53, flags: []).consume, "pinned Escape release paired")
        keys.pinAfterClose()
        let pinnedOther = keys.handle(.keyDown, key: 0, flags: [], canNavigate: true)
        check(!pinnedOther.consume && pinnedOther.action == .cancel && !keys.isPinned, "ordinary typing exits pinned chooser and passes through")
        keys.pinAfterClose(); keys.cancel()
        check(!keys.isSelecting && !keys.isPinned, "feature shutdown or final window removal clears pinned state")
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == .begin(reverse: false),
              "dismissing a pinned chooser with Option already up does not block the next Alt+Tab")
        keys.pinAfterClose(); keys.cancel()
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == nil,
              "dismissing while Option is held still waits for the physical release")
        check(keys.handle(.keyUp, key: 48, flags: .maskAlternate).consume, "pinned dismissal preserves held-key release pairing")
        _ = keys.handle(.flagsChanged, key: 58, flags: [])
        check(keys.handle(.keyDown, key: 48, flags: .maskAlternate).action == .begin(reverse: false),
              "next session starts normally after a held Option is released")
        keys.reset()
        for (code, direction) in SwitcherKeyState.arrows {
            keys.pinAfterClose()
            let arrow = keys.handle(.keyDown, key: code, flags: [], canNavigate: true)
            check(arrow.consume && arrow.action == .navigate(direction), "pinned arrow selects without Option")
            check(keys.handle(.keyUp, key: code, flags: []).consume && keys.swallowedKeys.isEmpty,
                  "pinned arrow release remains paired")
        }
        for code: CGKeyCode in [36, 76] {
            keys.pinAfterClose()
            let enter = keys.handle(.keyDown, key: code, flags: [], canNavigate: true)
            check(enter.consume && enter.action == .confirm && !keys.isSelecting && !keys.isPinned,
                  "Return explicitly confirms the pinned highlight")
            check(keys.handle(.keyUp, key: code, flags: []).consume, "pinned Return release remains paired")
        }
        check(!keys.handle(.keyDown, key: 36, flags: [], canNavigate: true).consume,
              "Return outside a pinned chooser retains its native behavior")
        keys.pinAfterClose()
        let controlTab = keys.handle(.keyDown, key: 48, flags: .maskControl, canNavigate: true)
        check(!controlTab.consume && controlTab.action == .cancel, "pinned chooser preserves native Control+Tab")
        keys.pinAfterClose()
        let hiddenArrow = keys.handle(.keyDown, key: 124, flags: [], canNavigate: false)
        check(!hiddenArrow.consume && hiddenArrow.action == .cancel, "hidden pinned panel cannot consume ordinary arrows")
        keys.reset()

        var selection = WindowSelection(ids: ["a", "b", "c"], currentID: "a", reverse: false)
        check(selection.selectedID == "b", "quick tap selects previous MRU window")
        selection.cycle(reverse: false)
        check(selection.selectedID == "c", "forward selection")
        selection.cycle(reverse: false)
        check(selection.selectedID == "a", "wrap forward")
        selection.cycle(reverse: true)
        check(selection.selectedID == "c", "wrap backward")
        selection.retain(["b", "c"])
        check(selection.ids == ["b", "c"] && selection.selectedID == "c", "removal preserves chosen identity")
        selection.retain(["b"])
        check(selection.selectedID == "b", "closed selected window has bounded fallback")
        selection.retain([])
        check(selection.selectedID == nil, "all windows closed cancels safely")
        selection.cycle(reverse: true)
        check(selection.selectedID == nil, "empty selection cannot divide by zero")
        check(WindowSelection(ids: ["a", "b", "c"], currentID: "a", reverse: true).selectedID == "c", "reverse initial selection")
        check(WindowSelection(ids: ["a"], currentID: "a", reverse: false).selectedID == "a", "one window")

        var recency = WindowRecency()
        recency.focus("b"); recency.focus("a"); recency.focus("b")
        check(recency.sorted(["a", "b", "c"]) == ["b", "a", "c"], "window-level MRU is stable and unique")
        recency.retain(["a", "c"])
        check(recency.sorted(["a", "c"]) == ["a", "c"], "closed MRU entries pruned")

        var budget = ImageBudget<Int>(countLimit: 3, byteLimit: 10)
        budget.insert(1, for: "a", cost: 4)
        budget.insert(2, for: "b", cost: 4)
        _ = budget.value(for: "a")
        check(budget.insert(3, for: "c", cost: 4) == ["b"], "decoded byte limit evicts least recently used")
        check(budget.bytes == 8 && budget.count == 2, "byte accounting after eviction")
        budget.insert(5, for: "a", cost: 2)
        check(budget.bytes == 6 && budget.value(for: "a") == 5, "replacement removes previous cost")
        budget.insert(6, for: "huge", cost: 11)
        check(budget.value(for: "huge") == nil && budget.bytes == 6, "oversized frame rejected")
        budget.insert(7, for: "zero", cost: 0)
        check(budget.count == 2, "invalid frame cost rejected")
        check(budget.remove("a") && !budget.remove("a") && budget.bytes == 4, "removal idempotent")
        var countBudget = ImageBudget<Int>(countLimit: 2, byteLimit: 100)
        for index in 0..<20 { countBudget.insert(index, for: "\(index)", cost: 1) }
        check(countBudget.count == 2 && countBudget.keys == ["18", "19"], "count cap enforced independently")

        var gate = CaptureAdmission()
        let session = gate.newSession()
        let request = gate.begin()!
        check(gate.begin() == nil, "one true request in flight")
        gate.invalidateSession()
        check(!gate.finish(request, session: session), "late image cannot update a closed session")
        let nextSession = gate.newSession()
        let next = gate.begin()!
        check(!gate.finish(request, session: session) && gate.inFlight == next, "duplicate callback cannot release another slot")
        gate.timeout(next)
        check(gate.paused && gate.inFlight == next && gate.begin() == nil, "timeout retains real OS slot and stops admission")
        gate.retry()
        check(gate.paused, "retry cannot overlap timed-out OS request")
        check(!gate.finish(next, session: nextSession) && gate.inFlight == nil, "timed-out result is discarded")
        gate.retry()
        let fresh = gate.newSession(), request3 = gate.begin()!
        check(gate.finish(request3, session: fresh), "explicit recovery after actual completion")
        check(!gate.finish(request3, session: fresh), "callback completion exactly once")

        for size in [CGSize(width: 7680, height: 4320), CGSize(width: 500, height: 6000),
                     CGSize(width: 100, height: 100), CGSize(width: 1, height: 1)] {
            let output = PreviewSizing.pixels(for: size)!
            check(output.width <= 480 && output.height <= 300, "pixel size bounded independently of display DPI")
            check(output.width >= 1 && output.height >= 1, "nonzero image dimensions")
        }
        check(PreviewSizing.pixels(for: .zero) == nil, "zero geometry rejected")
        check(PreviewSizing.pixels(for: CGSize(width: CGFloat.infinity, height: 100)) == nil, "invalid geometry rejected")
        // Repeated actual state transitions, including cancellation and unusual release order.
        for index in 0..<500 {
            keys.reset(); keys.isEnabled = true
            let down = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
            if index % 2 == 0 {
                _ = keys.handle(.flagsChanged, key: 58, flags: [])
            } else {
                _ = keys.handle(.keyDown, key: 53, flags: .maskAlternate)
                _ = keys.handle(.keyUp, key: 53, flags: .maskAlternate)
            }
            let up = keys.handle(.keyUp, key: 48, flags: [])
            check(down.consume && up.consume && keys.swallowedKeys.isEmpty && !keys.isSelecting, "cycle \(index) releases all swallowed keys")
        }
    }
}
