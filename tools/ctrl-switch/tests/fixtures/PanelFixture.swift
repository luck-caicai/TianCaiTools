// Manual UI fixture with synthetic content; not part of headless CI.
import AppKit
import ApplicationServices
@main struct PanelFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = CommandLine.arguments.dropFirst().first
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("panel-fixture.png").path
        let panel = SwitcherPanel()
        let names = ["文稿 · 项目说明", "浏览器 · 工作页面", "终端 · 开发日志", "编辑器 · main.swift", "文件 · 下载", "文稿 · 设计草案"]
        let windows = names.enumerated().map { index, name in
            SwitchableWindow(id: "fixture-\(index)", windowID: nil, pid: getpid(),
                applicationName: name.components(separatedBy: " · ").first!, title: name,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: index == 4, fullscreen: index == 1,
                canClose: index != 5,
                element: AXUIElementCreateApplication(getpid()))
        }
        let image = NSImage(size: NSSize(width: 480, height: 300))
        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 480, height: 300)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: CGRect(x: 22, y: 246, width: 200, height: 18), xRadius: 4, yRadius: 4).fill()
        for row in 0..<7 {
            NSColor(calibratedWhite: 0.8, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: 22, y: 216 - row * 24, width: 430 - (row % 3) * 45, height: 9)).fill()
        }
        image.unlockFocus()
        var frame = CGRect(x: 0, y: 0, width: 480, height: 300)
        let bitmap = image.cgImage(forProposedRect: &frame, context: nil, hints: nil)!
        let lifecycle = CommandLine.arguments.contains("--lifecycle")
        let interactive = CommandLine.arguments.contains("--interactive")
            || Bundle.main.object(forInfoDictionaryKey: "PanelFixtureInteractive") as? Bool == true
        var remainingWindows = windows
        if interactive {
            panel.onChoose = { id in
                panel.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                    let own = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() }
                    let report: [String: Any] = ["clicked": id, "panelVisible": panel.isVisible,
                        "onscreenOwnWindows": own.count,
                        "visibleAppWindows": app.windows.filter(\.isVisible).count]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("panel-click-report.json"))
                    }
                }
            }
            panel.onClose = { id in
                remainingWindows.removeAll { $0.id == id }
                panel.show(windows: remainingWindows, selectedID: remainingWindows.first?.id, previewStatus: .ready,
                    pointerPreview: true, image: { _ in bitmap })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let report: [String: Any] = ["closed": id, "panelVisible": panel.isVisible,
                        "remaining": panel.visibleIDs, "surfaceCount": panel.visibleSurfaceCount]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("panel-close-report.json"))
                    }
                }
            }
        }
        panel.show(windows: windows, selectedID: "fixture-2", previewStatus: .ready, image: { _ in bitmap })
        if lifecycle {
            var chosen: [String] = []
            var closed: [String] = []
            var checks: [String: Bool] = [:]
            panel.onChoose = { id in chosen.append(id); panel.hide() }
            panel.onClose = { id in
                closed.append(id)
                remainingWindows.removeAll { $0.id == id }
                panel.show(windows: remainingWindows, selectedID: remainingWindows.first?.id, previewStatus: .ready,
                    pointerPreview: true, image: { _ in bitmap })
            }
            func finish() {
                let passed = checks.values.allSatisfy { $0 }
                let report: [String: Any] = ["passed": passed, "checks": checks,
                    "scope": "production accessibility actions and window lifecycle; no global input or user-window focus"]
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: output))
                    print(String(decoding: data, as: UTF8.self))
                } catch { print(error); exit(1) }
                panel.releaseResources()
                exit(passed ? 0 : 1)
            }
            checks["firstActionQueued"] = panel.chooseForFixture("fixture-0")
            panel.hide()
            panel.show(windows: windows, selectedID: "fixture-2", previewStatus: .ready, image: { _ in bitmap })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                checks["oldClickCannotChooseNewSession"] = chosen.isEmpty && panel.isVisible
                checks["newActionQueued"] = panel.chooseForFixture("fixture-1")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    checks["chosenExactlyOnce"] = chosen == ["fixture-1"]
                    checks["closedAfterChoose"] = !panel.isVisible && panel.visibleSurfaceCount == 0
                    panel.show(windows: windows, selectedID: "fixture-3", previewStatus: .ready, image: { _ in bitmap })
                    checks["reopened"] = panel.isVisible && panel.visibleIDs.count == windows.count
                    panel.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        checks["closedAfterCancel"] = !panel.isVisible && panel.visibleSurfaceCount == 0
                        panel.show(windows: windows, selectedID: "fixture-0", previewStatus: .ready, image: { _ in bitmap })
                        checks["unavailableCloseDisabled"] = !panel.closeForFixture("fixture-5")
                        checks["disabledCloseCannotChoose"] = chosen == ["fixture-1"] && closed.isEmpty && panel.isVisible
                        checks["oldCloseQueued"] = panel.queueCloseForFixture("fixture-0")
                        panel.hide()
                        panel.show(windows: windows, selectedID: "fixture-1", previewStatus: .ready, image: { _ in bitmap })
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            checks["oldCloseCannotAffectNewSession"] = closed.isEmpty && panel.isVisible
                            checks["currentCloseDispatched"] = panel.closeForFixture("fixture-2")
                            checks["closeDeliveredBeforeReturn"] = closed == ["fixture-2"]
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                checks["closeTargetsExactCard"] = closed == ["fixture-2"]
                                checks["closeDoesNotChoose"] = chosen == ["fixture-1"]
                                checks["closeKeepsPanelOpen"] = panel.isVisible && panel.visibleSurfaceCount == 1
                                checks["closedCardRemoved"] = !panel.visibleIDs.contains("fixture-2") && panel.visibleIDs.count == windows.count - 1
                                checks["secondCloseQueued"] = panel.closeForFixture("fixture-3")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    checks["canCloseAgainWithoutReopening"] = closed == ["fixture-2", "fixture-3"] && panel.isVisible
                                    checks["remainingCardsStillSelectable"] = panel.chooseForFixture("fixture-0")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        checks["chooseAfterCloseDismissesCleanly"] = chosen == ["fixture-1", "fixture-0"] && !panel.isVisible && panel.visibleSurfaceCount == 0
                                        var releaseKeys = SwitcherKeyState()
                                        releaseKeys.isEnabled = true
                                        _ = releaseKeys.handle(.keyDown, key: 48, flags: .maskAlternate)
                                        panel.show(windows: remainingWindows, selectedID: "fixture-1", previewStatus: .ready, image: { _ in bitmap })
                                        checks["releaseCloseDispatched"] = panel.closeForFixture("fixture-1")
                                        checks["heldCloseKeepsPanelVisible"] = releaseKeys.isSelecting && panel.isVisible
                                        let release = releaseKeys.handle(.flagsChanged, key: 58, flags: [])
                                        checks["optionReleaseEndsCloseSession"] = release.action == .commit
                                        if release.action == .commit { panel.hide() }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            checks["optionReleaseDismissesCleanly"] = !panel.isVisible && panel.visibleSurfaceCount == 0
                                            checks["closeSurvivesImmediateOptionRelease"] = closed.contains("fixture-1")
                                            remainingWindows = windows.filter { $0.id == "fixture-4" }
                                            panel.show(windows: remainingWindows, selectedID: "fixture-4", previewStatus: .ready, pointerPreview: true, image: { _ in bitmap })
                                            checks["lastCloseDispatched"] = panel.closeForFixture("fixture-4")
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                checks["lastCloseDismissesCleanly"] = closed.last == "fixture-4" && !panel.isVisible && panel.visibleSurfaceCount == 0
                                                finish()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            app.run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (interactive ? 600 : 0.5)) {
            do { try panel.snapshotPNG()?.write(to: URL(fileURLWithPath: output)) }
            catch { print(error); exit(1) }
            panel.releaseResources()
            exit(0)
        }
        app.run()
    }
}
