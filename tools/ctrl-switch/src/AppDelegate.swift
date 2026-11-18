import AppKit
import ApplicationServices
import ServiceManagement
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private var controller: EventTapController!
    private var switcher: WindowSwitcherController!
    private var statusItem: NSStatusItem!
    private var contextualMenu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var startupMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var altTabMenuItem: NSMenuItem!
    private var previewsMenuItem: NSMenuItem!
    private var screenPermissionMenuItem: NSMenuItem!
    private var diagnosticObserver: NSObjectProtocol?
    private var exerciseResult: [String: Any]?
    private var startupStatus = SMAppService.mainApp.status
    private var appearanceKey = ""
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
        defaults.register(defaults: ["shortcutsEnabled": true, "altTabEnabled": true, "windowPreviewsEnabled": true])
        controller = EventTapController(enabled: defaults.bool(forKey: "shortcutsEnabled"))
        switcher = WindowSwitcherController(enabled: defaults.bool(forKey: "altTabEnabled"),
            previewsEnabled: defaults.bool(forKey: "windowPreviewsEnabled"))
        controller.onStatusChanged = { [weak self] _ in self?.updateAppearance() }
        controller.onAvailabilityChanged = { [weak self] available in
            self?.switcher.setKeyboardAvailable(available)
            self?.updateAppearance()
        }
        controller.onKeyboardEvent = { [weak self] type, event in self?.switcher.handle(type: type, event: event) ?? false }
        controller.hasPendingSwitcherReleases = { [weak self] in self?.switcher.hasPendingReleases ?? false }
        controller.onInputInterrupted = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.switcher.cancel(resetKeys: true) }
        }
        switcher.onKeyReleasesDrained = { [weak self] in self?.controller.reconcile() }
        switcher.onChanged = { [weak self] in self?.updateAppearance() }
        makeStatusItem()
        makeMenu()
        if !preview { controller.switcherEnabled = switcher.isEnabled; controller.start() }
        installReadOnlyDiagnostics()
        updateAppearance()
        if !preview, (controller.isEnabled || switcher.isEnabled), !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.permissionHelpPresentedThisRun else { return }
                self.showPermissionHelp()
            }
        }
        if CommandLine.arguments.contains("--exercise-switcher") { scheduleExercise(attempt: 0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher?.stop()
        controller?.stop()
        if let diagnosticObserver { DistributedNotificationCenter.default().removeObserver(diagnosticObserver) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switcher.stop()
        controller.stop()
        guard switcher.previews.hasInFlightRequest else { return .terminateNow }
        let deadline = Date().addingTimeInterval(2)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            if self?.switcher.previews.hasInFlightRequest != true || Date() >= deadline {
                timer.invalidate()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        switcher?.previews.refreshPermission()
        controller?.reconcile()
    }

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

        altTabMenuItem = NSMenuItem(title: "启用 Alt+Tab 窗口切换", action: #selector(toggleAltTab), keyEquivalent: "")
        altTabMenuItem.target = self
        contextualMenu.addItem(altTabMenuItem)
        previewsMenuItem = NSMenuItem(title: "显示窗口预览", action: #selector(toggleWindowPreviews), keyEquivalent: "")
        previewsMenuItem.target = self
        contextualMenu.addItem(previewsMenuItem)
        screenPermissionMenuItem = NSMenuItem(title: "允许窗口截图…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        screenPermissionMenuItem.target = self
        contextualMenu.addItem(screenPermissionMenuItem)
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
        startupStatus = SMAppService.mainApp.status
        switcher.cancel()
        switcher.previews.refreshPermission()
        if !preview { controller.reconcile() }
        updateAppearance()
    }

    private func updateAppearance() {
        guard statusItem != nil, contextualMenu != nil else { return }
        let actualStatus = preview && controller.isEnabled ? EventTapController.Status.enabled : controller.status
        let key = "\(actualStatus.rawValue)|\(controller.isEnabled)|\(controller.isAvailable)|\(switcher.isEnabled)|\(switcher.previewsEnabled)|\(switcher.previews.status.rawValue)|\(startupStatus.rawValue)"
        guard key != appearanceKey else { return }
        appearanceKey = key
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
        permissionMenuItem.isHidden = !needsAttention && (!switcher.isEnabled || controller.isAvailable)
        altTabMenuItem.state = switcher.isEnabled ? .on : .off
        altTabMenuItem.title = switcher.isEnabled && !controller.isAvailable
            ? "启用 Alt+Tab 窗口切换（等待辅助功能授权）" : "启用 Alt+Tab 窗口切换"
        previewsMenuItem.state = switcher.previewsEnabled ? .on : .off
        previewsMenuItem.isEnabled = switcher.isEnabled
        switch switcher.previews.status {
        case .needsPermission: previewsMenuItem.title = "显示窗口预览（需要授权）"
        case .unsupported: previewsMenuItem.title = "显示窗口预览（需 macOS 26 或更新版本）"
        case .paused: previewsMenuItem.title = "显示窗口预览（截图暂时暂停）"
        default: previewsMenuItem.title = "显示窗口预览"
        }
        screenPermissionMenuItem.isHidden = switcher.previews.status != .needsPermission
        switch startupStatus {
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
        alert.messageText = "允许使用快捷键与窗口切换"
        alert.informativeText = "请在系统设置打开的权限列表中开启「CtrlSwitch.app」。\n\n用于七组 Ctrl 快捷键转换与 Alt+Tab 窗口切换，按键位置保持原样。\n\n更新后仍提示未授权时，请先用「－」移除旧记录，再用「＋」重新添加「应用程序」里的 CtrlSwitch.app。"
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

    @objc private func toggleAltTab() {
        switcher.setEnabled(!switcher.isEnabled)
        defaults.set(switcher.isEnabled, forKey: "altTabEnabled")
        controller.switcherEnabled = switcher.isEnabled
        if switcher.isEnabled, !AXIsProcessTrusted() { showPermissionHelp() }
    }

    @objc private func toggleWindowPreviews() {
        switcher.setPreviewsEnabled(!switcher.previewsEnabled)
        defaults.set(switcher.previewsEnabled, forKey: "windowPreviewsEnabled")
        if switcher.previewsEnabled, switcher.previews.status == .needsPermission { openScreenRecordingSettings() }
    }

    @objc private func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        switcher.previews.refreshPermission()
    }

    private func installReadOnlyDiagnostics() {
        diagnosticObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.ctrlswitch.statusRequest"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let request = notification.userInfo?["request"] as? String,
                  UUID(uuidString: request) != nil,
                  let data = try? JSONSerialization.data(withJSONObject: self.diagnosticValues(), options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.ctrlswitch.statusResponse"), object: request,
                userInfo: ["json": json], deliverImmediately: true)
        }
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
        startupStatus = SMAppService.mainApp.status
        updateAppearance()
    }

    private func diagnosticValues() -> [String: Any] {
        var values: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "accessibilityGranted": AXIsProcessTrusted(), "keyboardTapActive": controller.isAvailable,
            "ctrlEnabled": controller.isEnabled, "altTabEnabled": switcher.isEnabled,
            "previewsEnabled": switcher.previewsEnabled, "previewStatus": switcher.previews.status.rawValue,
            "windowCount": switcher.inventory.windows.count,
            "fullscreenWindowCount": switcher.inventory.windows.values.filter(\.fullscreen).count,
            "targetedActivationAvailable": WindowActivation.isAvailable, "panelVisible": switcher.isPanelVisible,
            "targetedKeyFocusAvailable": WindowActivation.canMakeKey,
            "panelSurfaceCount": switcher.panelSurfaceCount,
            "windowSources": switcher.inventory.appWindowSources.values.sorted {
                ($0["pid"] as? pid_t ?? 0) < ($1["pid"] as? pid_t ?? 0)
            },
            "lastFocusCheck": switcher.inventory.lastFocusCheck,
            "cachedImages": switcher.previews.cachedCount, "cachedBytes": switcher.previews.cachedBytes,
            "captureInFlight": switcher.previews.hasInFlightRequest,
            "completedCaptures": switcher.previews.completedCaptures, "failedCaptures": switcher.previews.failedCaptures,
            "committedSwitches": switcher.committedSwitches, "confirmedSwitches": switcher.confirmedSwitches,
            "arrowSelections": switcher.arrowSelections, "hoverSelections": switcher.hoverSelections
        ]
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { values["physicalFootprintBytes"] = memory.phys_footprint }
        if let exerciseResult { values["exercise"] = exerciseResult }
        return values
    }

    private func scheduleExercise(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.switcher.inventory.windows.isEmpty, attempt < 20 {
                self.scheduleExercise(attempt: attempt + 1)
                return
            }
            self.switcher.exercise(cycles: 500) { [weak self] result in
                self?.exerciseResult = result
            }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
