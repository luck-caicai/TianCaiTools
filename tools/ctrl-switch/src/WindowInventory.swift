import AppKit
import ApplicationServices
import Darwin

struct SwitchableWindow {
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let applicationName: String
    let title: String
    let frame: CGRect
    let minimized: Bool
    let element: AXUIElement
}

/// All AX queries run off main with an IPC timeout. Nothing is periodically polled while idle.
final class WindowInventory {
    private struct AppInfo { let pid: pid_t; let name: String }
    private let queryQueue = DispatchQueue(label: "local.ctrlswitch.windows", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "local.ctrlswitch.focus", qos: .userInteractive)
    private var observers: [pid_t: AXObserver] = [:]
    private var previousElements: [pid_t: [(AXUIElement, String)]] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingPids = Set<pid_t>()
    private var pendingFullScan = false
    private var pendingFocusPID: pid_t?
    private var refreshWork: DispatchWorkItem?
    private var scanning = false
    private var epoch = 0
    private var recency = WindowRecency()
    private var zOrder: [CGWindowID] = []
    private(set) var isEnabled = false
    private(set) var windows: [String: SwitchableWindow] = [:]
    private(set) var focusedID: String?
    var onChanged: (() -> Void)?
    var onFocusResult: ((Bool) -> Void)?

    // Optional identity bridge; screenshots themselves use public ScreenCaptureKit.
    // If unavailable, public CG metadata is matched only when unambiguous.
    private static let getWindowID: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32).self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let function = getWindowID, function(element, &id) == 0, id != 0 else { return nil }
        return id
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        epoch += 1
        let center = NSWorkspace.shared.notificationCenter
        if enabled {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.activeSpaceDidChangeNotification] {
                workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.requestRefresh()
                })
            }
            workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.requestRefresh(pid: app?.processIdentifier, focusPID: app?.processIdentifier)
                })
            requestRefresh()
        } else {
            workspaceTokens.forEach { center.removeObserver($0) }; workspaceTokens.removeAll()
            refreshWork?.cancel(); refreshWork = nil
            pendingPids.removeAll(); pendingFullScan = false; pendingFocusPID = nil
            windows.removeAll(); focusedID = nil; recency = WindowRecency(); zOrder.removeAll()
            queryQueue.async { [self] in
                for observer in observers.values {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                observers.removeAll(); previousElements.removeAll()
            }
            onChanged?()
        }
    }

    func orderedWindows() -> [SwitchableWindow] {
        let positions = Dictionary(uniqueKeysWithValues: zOrder.enumerated().map { ($0.element, $0.offset) })
        let fallback = windows.values.sorted {
            let a = $0.windowID.flatMap { positions[$0] } ?? Int.max
            let b = $1.windowID.flatMap { positions[$0] } ?? Int.max
            if a != b { return a < b }
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.id < $1.id
        }.map(\.id)
        return recency.sorted(fallback).compactMap { windows[$0] }
    }

    func requestRefresh(pid: pid_t? = nil, focusPID: pid_t? = nil) {
        guard isEnabled else { return }
        if let pid { pendingPids.insert(pid) } else { pendingFullScan = true }
        if let focusPID { pendingFocusPID = focusPID }
        guard refreshWork == nil, !scanning else { return }
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scan() {
        refreshWork = nil
        guard isEnabled, !scanning, AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
        }.map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "应用") }
        let all = pendingFullScan
        let pids = pendingPids
        let focusPID = pendingFocusPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        pendingFullScan = false; pendingPids.removeAll(); pendingFocusPID = nil
        let chosen = all ? apps : apps.filter { pids.contains($0.pid) }
        let currentEpoch = epoch
        scanning = true
        queryQueue.async { [self] in
            let livePids = Set(apps.map(\.pid))
            for pid in Array(observers.keys) where !livePids.contains(pid) {
                if let observer = observers.removeValue(forKey: pid) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                previousElements[pid] = nil
            }
            let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let visible = Set(rows.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            var discovered: [SwitchableWindow] = []
            var focused: String?
            for app in chosen {
                let found = readWindows(app, visible: visible, rows: rows, frontmostPID: focusPID)
                discovered.append(contentsOf: found.windows)
                if app.pid == focusPID { focused = found.focused }
            }
            let order = rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            DispatchQueue.main.async { [self] in
                scanning = false
                guard isEnabled, epoch == currentEpoch else {
                    if isEnabled { requestRefresh() }
                    return
                }
                let replaced = Set(chosen.map(\.pid))
                windows = windows.filter { livePids.contains($0.value.pid) && !replaced.contains($0.value.pid) }
                for window in discovered { windows[window.id] = window }
                zOrder = order
                recency.retain(Set(windows.keys))
                if let focused, focusPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                    focusedID = focused; recency.focus(focused)
                } else if let id = focusedID, windows[id] == nil { focusedID = nil }
                onChanged?()
                if pendingFullScan || !pendingPids.isEmpty { requestRefresh(pid: pendingFullScan ? nil : pendingPids.first) }
            }
        }
    }

    private func readWindows(_ app: AppInfo, visible: Set<CGWindowID>, rows: [[String: Any]],
                             frontmostPID: pid_t?) -> (windows: [SwitchableWindow], focused: String?) {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        let observer = observerForApp(app.pid, axApp)
        guard let elements = Self.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return ([], nil) }
        let focusedElement = Self.attribute(axApp, kAXFocusedWindowAttribute)
        let old = previousElements[app.pid] ?? []
        var tracked: [(AXUIElement, String)] = []
        var result: [SwitchableWindow] = []
        var focused: String?
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        for element in elements.prefix(160) {
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            AXUIElementSetMessagingTimeout(element, 0.12)
            let role = Self.attribute(element, kAXRoleAttribute) as? String
            let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
            guard role == kAXWindowRole,
                  subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            let minimized = Self.attribute(element, kAXMinimizedAttribute) as? Bool ?? false
            let title = String((Self.attribute(element, kAXTitleAttribute) as? String ?? "").prefix(512))
            guard let frame = Self.frame(element), frame.width >= 40, frame.height >= 25 else { continue }
            let wid = Self.windowID(element) ?? Self.uniqueCGMatch(pid: app.pid, title: title, frame: frame, rows: rows)
            let onScreen = wid.map { visible.contains($0) } ?? false
            // AX exposes no Space for minimized windows. Enumerate those, but exclude ordinary off-Space windows.
            guard onScreen || minimized || (wid == nil && app.pid == frontmostPID) else { continue }
            let id = wid.map { "\(app.pid):\($0)" }
                ?? old.first(where: { CFEqual($0.0, element) })?.1 ?? "\(app.pid):ax:\(UUID().uuidString)"
            tracked.append((element, id))
            result.append(SwitchableWindow(id: id, windowID: wid, pid: app.pid,
                applicationName: app.name, title: title.isEmpty ? app.name : title,
                frame: frame, minimized: minimized, element: element))
            if let focusedElement, CFEqual(element, focusedElement) { focused = id }
            if let observer {
                for notification in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                                     kAXMovedNotification, kAXResizedNotification] {
                    AXObserverAddNotification(observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
        previousElements[app.pid] = tracked
        return (result, focused)
    }

    private func observerForApp(_ pid: pid_t, _ app: AXUIElement) -> AXObserver? {
        if let observer = observers[pid] { return observer }
        var created: AXObserver?
        let error = AXObserverCreate(pid, { observer, _, _, context in
            guard let context else { return }
            let inventory = Unmanaged<WindowInventory>.fromOpaque(context).takeUnretainedValue()
            // A destroyed AX node may no longer answer its PID. Resolve the observer instead.
            inventory.queryQueue.async { [weak inventory] in
                guard let inventory, let pid = inventory.observers.first(where: { CFEqual($0.value, observer) })?.key else { return }
                DispatchQueue.main.async { [weak inventory] in inventory?.requestRefresh(pid: pid) }
            }
        }, &created)
        guard error == .success, let observer = created else { return nil }
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                             kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(observer, app, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    func activate(_ window: SwitchableWindow) {
        guard isEnabled, windows[window.id] != nil, let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            onFocusResult?(false); requestRefresh(); return
        }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        focusQueue.async { [weak self] in
            let axApp = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            AXUIElementSetMessagingTimeout(window.element, 0.2)
            if window.minimized { AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window.element)
            _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            self?.focusQueue.asyncAfter(deadline: .now() + (window.minimized ? 0.75 : 0.15)) { [weak self] in
                let focused = Self.attribute(axApp, kAXFocusedWindowAttribute)
                let matched = focused.map { CFEqual($0, window.element) } ?? false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.requestRefresh(pid: window.pid, focusPID: window.pid)
                    self.onFocusResult?(matched && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid)
                }
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func uniqueCGMatch(pid: pid_t, title: String, frame: CGRect, rows: [[String: Any]]) -> CGWindowID? {
        let matching = rows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(cgFrame.minX - frame.minX) < 3, abs(cgFrame.minY - frame.minY) < 3,
                  abs(cgFrame.width - frame.width) < 3, abs(cgFrame.height - frame.height) < 3 else { return false }
            if let cgTitle = row[kCGWindowName as String] as? String, !cgTitle.isEmpty { return cgTitle == title }
            return true
        }
        return matching.count == 1 ? (matching[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
    }
}
