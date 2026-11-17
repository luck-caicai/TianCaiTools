// Manual UI fixture with synthetic content; not part of headless CI.
import AppKit
import ApplicationServices
@main struct PanelFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = SwitcherPanel()
        let names = ["文稿 · 项目说明", "浏览器 · 工作页面", "终端 · 开发日志", "编辑器 · main.swift", "文件 · 下载", "文稿 · 设计草案"]
        let windows = names.enumerated().map { index, name in
            SwitchableWindow(id: "fixture-\(index)", windowID: nil, pid: getpid(),
                applicationName: name.components(separatedBy: " · ").first!, title: name,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: index == 4,
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
        panel.show(windows: windows, selectedID: "fixture-2", previewStatus: .ready, image: { _ in bitmap })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do { try panel.snapshotPNG()?.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            catch { print(error); exit(1) }
            panel.releaseResources()
            exit(0)
        }
        app.run()
    }
}
