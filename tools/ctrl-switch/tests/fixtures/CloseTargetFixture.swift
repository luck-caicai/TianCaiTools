// Manual native integration fixture only. Contains no user data and is excluded from headless CI.
import AppKit

private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var closed = Set<String>()
    private var approved = Set<String>()
    private var events: [String] = []
    private let report = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("close-target-report.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出关闭测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        NSApp.mainMenu = menu
        for (index, id) in ["A", "B", "C"].enumerated() {
            let window = NSWindow(contentRect: CGRect(x: 100 + index * 65, y: 200 - index * 35, width: 540, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier(id)
            window.title = id == "C" ? "关闭测试 C · 取消后保留" : "关闭测试 \(id) · 合成窗口"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let label = NSTextField(wrappingLabelWithString: id == "C"
                ? "这是合成的未保存文稿测试。\n点击预览卡片的 × 后，选择“取消”，此窗口应继续保留。"
                : "这是合成测试窗口 \(id)，不含用户数据。\n只关闭 A 时，对照窗口 B 和 C 应继续保留。")
            label.frame = CGRect(x: 30, y: 80, width: 480, height: 150)
            label.font = .systemFont(ofSize: 18)
            window.contentView?.addSubview(label)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        writeReport()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = sender.identifier?.rawValue, id == "C", !approved.contains(id) else { return true }
        guard sender.attachedSheet == nil else { return false }
        events.append("confirmationPresented")
        let alert = NSAlert()
        alert.messageText = "未保存的测试文稿"
        alert.informativeText = "本窗口只含合成测试内容。选择“取消”后应保留窗口。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "关闭测试文稿")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.approved.insert(id)
                sender?.performClose(nil)
            } else { self.events.append("confirmationCancelled") }
            self.writeReport()
        }
        // A disconnected UI automation client must not leave the disposable alert up indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak sender] in
            guard let self, let sender, sender.attachedSheet == alert.window else { return }
            self.events.append("confirmationTimeoutCancelled")
            alert.buttons.first?.performClick(nil)
        }
        writeReport()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        closed.insert(id); events.append("closed:" + id)
        writeReport()
    }

    private func writeReport() {
        let value: [String: Any] = ["closed": closed.sorted(), "alive": ["A", "B", "C"].filter { !closed.contains($0) },
            "events": events, "pid": getpid()]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
    }
}

@main private struct CloseTargetFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
