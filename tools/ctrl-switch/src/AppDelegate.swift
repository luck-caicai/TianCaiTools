import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var controller: EventTapController!
    private var statusItem: NSStatusItem!
    private var contextualMenu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var startupMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var showingPermissionHelp = false
    private var permissionHelpPresentedThisRun = false
    private let preview = CommandLine.arguments.contains("--preview")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.ctrlswitch.mac")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        defaults.register(defaults: ["shortcutsEnabled": true])
        controller = EventTapController(enabled: defaults.bool(forKey: "shortcutsEnabled"))
        controller.onStatusChanged = { [weak self] _ in self?.updateAppearance() }
        makeStatusItem()
        makeMenu()
        if !preview { controller.start() }
        updateAppearance()
        if !preview, controller.isEnabled, !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.permissionHelpPresentedThisRun else { return }
                self.showPermissionHelp()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controller?.status == .needsPermission, !permissionHelpPresentedThisRun { showPermissionHelp() }
        return false
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "Mac Ctrl"
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Ctrl 快捷键开关")
    }

    private func makeMenu() {
        contextualMenu = NSMenu()
        contextualMenu.delegate = self
        contextualMenu.autoenablesItems = false

        let title = NSMenuItem(title: "Ctrl 开关", action: nil, keyEquivalent: "")
        title.isEnabled = false
        contextualMenu.addItem(title)
        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        contextualMenu.addItem(statusMenuItem)
        contextualMenu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "启用 Windows 常用快捷键", action: #selector(toggleShortcuts), keyEquivalent: "")
        toggleMenuItem.target = self
        contextualMenu.addItem(toggleMenuItem)

        let keys = NSMenuItem(title: "C 复制 · V 粘贴 · S 保存 · A 全选", action: nil, keyEquivalent: "")
        keys.isEnabled = false
        contextualMenu.addItem(keys)
        let moreKeys = NSMenuItem(title: "X 剪切 · F 查找 · Z 撤销", action: nil, keyEquivalent: "")
        moreKeys.isEnabled = false
        contextualMenu.addItem(moreKeys)

        permissionMenuItem = NSMenuItem(title: "打开辅助功能设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionMenuItem.target = self
        contextualMenu.addItem(permissionMenuItem)
        contextualMenu.addItem(.separator())

        startupMenuItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        startupMenuItem.target = self
        contextualMenu.addItem(startupMenuItem)

        let quit = NSMenuItem(title: "退出 Ctrl 开关", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        contextualMenu.addItem(quit)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if controller.status == .needsPermission || controller.status == .unavailable {
            showPermissionHelp()
        } else {
            toggleShortcuts()
        }
    }

    @objc private func toggleShortcuts() {
        controller.isEnabled.toggle()
        defaults.set(controller.isEnabled, forKey: "shortcutsEnabled")
        updateAppearance()
        if controller.status == .needsPermission || controller.status == .unavailable {
            showPermissionHelp()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        updateAppearance()
        statusItem.menu = contextualMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !preview { controller.reconcile() }
        updateAppearance()
    }

    private func updateAppearance() {
        guard statusItem != nil, contextualMenu != nil else { return }
        let actualStatus = preview && controller.isEnabled ? EventTapController.Status.enabled : controller.status
        let isOn = actualStatus == .enabled
        let needsAttention = actualStatus == .needsPermission || actualStatus == .unavailable
        statusItem.button?.title = isOn ? "Win Ctrl" : "Mac Ctrl"
        statusItem.button?.image = switchImage(isOn: isOn, needsAttention: needsAttention)
        statusItem.button?.setAccessibilityValue(isOn ? "已开启" : (needsAttention ? "需要辅助功能授权" : "已关闭"))
        let description: String
        switch actualStatus {
        case .enabled: description = "已开启 · 点击恢复 Mac 原生快捷键"
        case .disabled: description = "已关闭 · 点击启用 Ctrl 常用快捷键"
        case .needsPermission: description = "等待辅助功能授权 · 点击查看"
        case .unavailable: description = "键盘转换暂未就绪 · 点击重试"
        case .suspended: description = "会话已暂停"
        }
        statusItem.button?.toolTip = "Ctrl 开关：\(description)\n右键：登录时启动 / 退出\n终端应用保留原快捷键"
        statusMenuItem.title = description
        toggleMenuItem.state = controller.isEnabled ? .on : .off
        permissionMenuItem.isHidden = !needsAttention
        switch SMAppService.mainApp.status {
        case .enabled:
            startupMenuItem.state = .on
            startupMenuItem.title = "登录时启动"
        case .requiresApproval:
            startupMenuItem.state = .mixed
            startupMenuItem.title = "登录时启动（等待系统批准）…"
        default:
            startupMenuItem.state = .off
            startupMenuItem.title = "登录时启动"
        }
    }

    private func switchImage(isOn: Bool, needsAttention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 29, height: 18), flipped: false) { _ in
            let track = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 26, height: 14), xRadius: 7, yRadius: 7)
            let color: NSColor = needsAttention ? .systemOrange : (isOn ? .systemGreen : .systemGray)
            color.setFill()
            track.fill()
            NSColor.white.setFill()
            let knob = NSBezierPath(ovalIn: NSRect(x: isOn ? 15 : 3, y: 4, width: 10, height: 10))
            knob.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = isOn ? "开启" : "关闭"
        return image
    }

    private func showPermissionHelp() {
        guard !showingPermissionHelp else { return }
        showingPermissionHelp = true
        permissionHelpPresentedThisRun = true
        defer { showingPermissionHelp = false }
        if AXIsProcessTrusted() {
            controller.reconcile()
            if controller.status == .enabled { updateAppearance(); return }
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "让 Ctrl 快捷键生效"
        alert.informativeText = "请在系统设置打开的权限列表中开启「CtrlSwitch.app」。\n\n只处理 Ctrl+C / V / S / A / X / F / Z，按键位置保持原样。授权后自动生效。\n\n如果列表中没有本程序，点「＋」选择「应用程序」里的 CtrlSwitch.app。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        controller.reconcile()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "暂时无法设置登录启动"
            alert.informativeText = "请将程序放在「应用程序」文件夹后重试。\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
        updateAppearance()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
