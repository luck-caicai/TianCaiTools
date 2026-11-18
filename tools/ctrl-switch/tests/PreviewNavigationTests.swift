import CoreGraphics
import Foundation

enum PreviewNavigationTests {
    static func run(_ check: (Bool, String) -> Void) {
        for (code, direction) in SwitcherKeyState.arrows {
            var keys = SwitcherKeyState()
            keys.isEnabled = true
            let ordinary = keys.handle(.keyDown, key: code, flags: .maskAlternate, canNavigate: true)
            check(!ordinary.consume && ordinary.action == nil, "arrow \(code) outside chooser stays native")
            _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
            _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
            let beforePanel = keys.handle(.keyDown, key: code, flags: .maskAlternate)
            check(!beforePanel.consume && beforePanel.action == .cancel, "arrows only select after panel appears")

            for flags: CGEventFlags in [.maskAlternate, [.maskAlternate, .maskShift],
                                       [.maskAlternate, .maskNumericPad, .maskSecondaryFn]] {
                keys.reset()
                _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
                _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
                let down = keys.handle(.keyDown, key: code, flags: flags, canNavigate: true)
                check(down.consume && down.action == .navigate(direction), "visible chooser consumes arrow \(code)")
                check(keys.handle(.keyDown, key: code, flags: flags, isRepeat: true, canNavigate: true).action == .navigate(direction),
                      "held arrow repeats navigate")
                check(keys.handle(.flagsChanged, key: 58, flags: []).action == .commit, "Alt release confirms arrow choice")
                check(keys.handle(.keyUp, key: code, flags: []).consume && keys.swallowedKeys.isEmpty,
                      "arrow up stays paired after Alt release")
            }
            for extra: CGEventFlags in [.maskControl, .maskCommand] {
                keys.reset()
                _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
                _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
                let result = keys.handle(.keyDown, key: code, flags: [.maskAlternate, extra], canNavigate: true)
                check(!result.consume && result.action == .cancel, "Control/Command arrow keeps native behavior")
            }
            keys.reset()
            _ = keys.handle(.keyDown, key: 48, flags: .maskAlternate)
            _ = keys.handle(.keyUp, key: 48, flags: .maskAlternate)
            _ = keys.handle(.keyDown, key: code, flags: .maskAlternate, canNavigate: true)
            keys.isEnabled = false
            keys.cancel()
            check(keys.handle(.keyUp, key: code, flags: []).consume, "disabling still pairs arrow release")
        }

        let ids = (0..<10).map(String.init)
        var choice = WindowSelection(ids: ids, currentID: nil, reverse: false)
        choice.move(.left, columns: 4)
        check(choice.selectedID == "9", "left wraps at first card")
        choice.move(.up, columns: 4)
        check(choice.selectedID == "5", "up keeps column across pages")
        choice.move(.up, columns: 4)
        check(choice.selectedID == "1", "up moves to previous row")
        choice.move(.up, columns: 4)
        check(choice.selectedID == "9", "up wraps to last row")
        choice.select("3")
        choice.move(.down, columns: 4)
        check(choice.selectedID == "7", "down keeps column")
        choice.move(.down, columns: 4)
        check(choice.selectedID == "9", "short last row uses nearest available column")
        choice.move(.right, columns: 4)
        check(choice.selectedID == "0", "right wraps at last card")
        check(choice.ids == ids, "navigation preserves frozen MRU order")
        choice.select("9")
        choice.retain(Set(ids.dropLast()))
        choice.move(.up, columns: 4)
        check(choice.selectedID == "4", "navigation remains valid when a selected window closes")
        for count in 0...17 {
            for columns in 0...5 {
                var grid = WindowSelection(ids: (0..<count).map(String.init), currentID: nil, reverse: false)
                for direction in SelectionDirection.allCases {
                    grid.move(direction, columns: columns)
                    check(count == 0 ? grid.selectedID == nil : grid.ids.indices.contains(grid.index),
                          "grid bounds for \(count) windows and \(columns) columns")
                }
            }
        }

        var hover = HoverSelectionState()
        hover.rebase(at: CGPoint(x: 100, y: 100))
        check(!hover.moved(to: CGPoint(x: 100, y: 100)), "stationary pointer on panel appearance cannot steal selection")
        check(!hover.moved(to: CGPoint(x: 100.2, y: 100)), "subpixel tracking noise ignored")
        check(hover.moved(to: CGPoint(x: 101, y: 100)), "actual pointer movement permits hover selection")
        check(!hover.moved(to: CGPoint(x: 101, y: 100)), "same coordinate cannot reselect after a repaint")
        hover.rebase(at: CGPoint(x: 105, y: 110))
        check(!hover.moved(to: CGPoint(x: 105, y: 110)), "keyboard selection wins over stale mouse-enter events")
        check(hover.moved(to: CGPoint(x: 106, y: 111)), "moving mouse after keyboard resumes hover selection")
        hover.reset()
        check(!hover.moved(to: CGPoint(x: 106, y: 111)), "old hover cannot survive closing and reopening")
        check(!hover.moved(to: CGPoint(x: CGFloat.infinity, y: 0)), "invalid mouse coordinates rejected")

        var intent = WindowSelection(ids: ["a", "b", "c", "d"], currentID: "a", reverse: false)
        check(intent.releaseTargetID == "b", "keyboard choice still confirms when Alt is released")
        intent.hover("c")
        check(intent.highlightedID == "c" && intent.selectedID == "b", "hover is visual and preserves keyboard target")
        check(intent.releaseTargetID == nil, "hover plus Alt release cancels instead of entering a window")
        intent.hover("b")
        check(intent.releaseTargetID == nil, "hovering the keyboard-selected card also requires a click")
        intent.move(.right, columns: 2)
        check(intent.highlightedID == "c" && intent.releaseTargetID == "c", "explicit arrow choice resumes keyboard confirmation")
        intent.hover("a")
        intent.cycle(reverse: false)
        check(intent.selectedID == "b" && intent.releaseTargetID == "b", "explicit Tab choice resumes confirmation")
        intent.hover("missing")
        check(intent.releaseTargetID == "b", "stale hover id cannot suppress keyboard confirmation")
        intent.hover("d")
        intent.retain(["a", "b", "c"])
        check(intent.hoveredID == nil && intent.releaseTargetID == nil, "closing the hovered window never confirms another target")

        // A delayed Space transition must not raise an earlier window after a newer selection.
        let focus = WindowFocusGeneration()
        let first = focus.advance()
        let second = focus.advance()
        var callbacks: [String] = []
        for (generation, id) in [(first, "old"), (second, "current"), (first, "late-old")] {
            if focus.contains(generation) { callbacks.append(id) }
        }
        check(callbacks == ["current"], "late cross-Space callbacks cannot override a newer switch")
        focus.advance()
        check(!focus.contains(second), "opening a new chooser or disabling cancels pending focus work")
        for index in 0..<100 {
            let generation = focus.advance()
            check(focus.contains(generation), "fresh focus intent \(index) is accepted")
            focus.advance()
            check(!focus.contains(generation), "canceled focus intent \(index) cannot retry")
        }
    }
}
