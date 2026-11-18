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
    let fullscreen: Bool
    let canClose: Bool
    let element: AXUIElement
}

enum WindowCloseResult: String { case requested, unavailable, stale, failed }

/// All AX queries run off main with an IPC timeout. Nothing is periodically polled while idle.
final class WindowInventory {
    private struct AppInfo { let pid: pid_t; let name: String }
    private let queryQueue = DispatchQueue(label: "local.ctrlswitch.windows", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "local.ctrlswitch.focus", qos: .userInteractive)
    private let focusGeneration = WindowFocusGeneration()
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
    private(set) var appWindowSources: [pid_t: [String: Any]] = [:]
    private(set) var lastFocusCheck: [String: Any] = [:]
    var onChanged: (() -> Void)?
    var onFocusResult: ((Bool) -> Void)?
    var onCloseResult: ((WindowCloseResult) -> Void)?

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
            focusGeneration.advance()
            workspaceTokens.forEach { center.removeObserver($0) }; workspaceTokens.removeAll()
            refreshWork?.cancel(); refreshWork = nil
            pendingPids.removeAll(); pendingFullScan = false; pendingFocusPID = nil
            windows.removeAll(); focusedID = nil; recency = WindowRecency(); zOrder.removeAll()
            appWindowSources.removeAll(); lastFocusCheck.removeAll()
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
            var discovered: [SwitchableWindow] = []
            var sources: [pid_t: [String: Any]] = [:]
            var focused: String?
            for app in chosen {
                let found = readWindows(app, rows: rows)
                discovered.append(contentsOf: found.windows)
                sources[app.pid] = found.source
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
                appWindowSources = appWindowSources.filter { livePids.contains($0.key) && !replaced.contains($0.key) }
                sources.forEach { appWindowSources[$0.key] = $0.value }
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

    private func readWindows(_ app: AppInfo, rows: [[String: Any]])
        -> (windows: [SwitchableWindow], focused: String?, source: [String: Any]) {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        let observer = observerForApp(app.pid, axApp)
        let published = Self.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let focusedElement = Self.attribute(axApp, kAXFocusedWindowAttribute)
        let mainElement = Self.attribute(axApp, kAXMainWindowAttribute)
        let old = previousElements[app.pid] ?? []
        func windowElement(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let elements = WindowCandidates.merge(published: published, focused: windowElement(focusedElement),
            main: windowElement(mainElement), previous: old.map(\.0), equal: { CFEqual($0, $1) })
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
            let fullscreen = Self.attribute(element, "AXFullScreen") as? Bool ?? false
            let canClose = Self.closeButton(element).map { Self.attribute($0, kAXEnabledAttribute) as? Bool != false } ?? false
            let title = String((Self.attribute(element, kAXTitleAttribute) as? String ?? "").prefix(512))
            guard let frame = Self.frame(element), frame.width >= 40, frame.height >= 25 else { continue }
            let wid = Self.windowID(element) ?? Self.uniqueCGMatch(pid: app.pid, title: title, frame: frame, rows: rows)
            // AX lists windows on inactive Spaces too. CG's isOnscreen is a visibility flag,
            // not a liveness test: filtering by it drops fullscreen and other-desktop windows.
            let id = wid.map { "\(app.pid):\($0)" }
                ?? old.first(where: { CFEqual($0.0, element) })?.1 ?? "\(app.pid):ax:\(UUID().uuidString)"
            tracked.append((element, id))
            result.append(SwitchableWindow(id: id, windowID: wid, pid: app.pid,
                applicationName: app.name, title: title.isEmpty ? app.name : title,
                frame: frame, minimized: minimized, fullscreen: fullscreen, canClose: canClose, element: element))
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
        return (result, focused, ["pid": app.pid, "published": published.count,
            "hasFocused": focusedElement != nil, "hasMain": mainElement != nil,
            "candidates": elements.count, "accepted": result.count,
            "fullscreen": result.filter(\.fullscreen).count])
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
        let generation = focusGeneration.advance()
        guard isEnabled, windows[window.id] != nil, let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            onFocusResult?(false); requestRefresh(); return
        }
        if app.isHidden { app.unhide() }
        // Advance the intended MRU immediately: a second quick Alt+Tab must not wait for the debounced
        // AX focus notification and choose the same destination twice. The next scan reconciles reality.
        focusedID = window.id
        recency.focus(window.id)
        onChanged?()
        focusQueue.async { [weak self] in
            guard let self, self.focusGeneration.contains(generation) else { return }
            let axApp = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            AXUIElementSetMessagingTimeout(window.element, 0.2)
            if window.minimized { AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            guard self.focusGeneration.contains(generation) else { return }
            if !WindowActivation.front(pid: window.pid, windowID: window.windowID) {
                DispatchQueue.main.async { [weak self] in
                    guard self?.focusGeneration.contains(generation) == true else { return }
                    app.activate(options: [])
                }
            }
            self.raise(window, app: axApp, generation: generation)
            // Space/fullscreen transitions are asynchronous. Re-check a small, fixed number of
            // times; retries only raise the already-frontmost app and never re-front a process.
            self.verifyFocus(window, app: axApp, generation: generation, attempt: 0)
        }
    }

    func cancelPendingActivation() { focusGeneration.advance() }

    func requestClose(_ window: SwitchableWindow) {
        guard isEnabled, let live = windows[window.id], CFEqual(live.element, window.element), window.canClose else {
            onCloseResult?(.unavailable); return
        }
        let generation = focusGeneration.advance()
        // One native AX press on this window's own close button. No keyboard shortcut,
        // process termination, predicted removal, or automatic save-dialog response.
        focusQueue.async { [weak self] in
            AXUIElementSetMessagingTimeout(window.element, 0.2)
            var pid: pid_t = 0
            let result: WindowCloseResult
            if AXUIElementGetPid(window.element, &pid) != .success || pid != window.pid
                || Self.attribute(window.element, kAXRoleAttribute) as? String != kAXWindowRole {
                result = .stale
            } else if let expected = window.windowID, let actual = Self.windowID(window.element), expected != actual {
                result = .stale
            } else if let button = Self.closeButton(window.element) {
                AXUIElementSetMessagingTimeout(button, 0.2)
                if Self.attribute(button, kAXEnabledAttribute) as? Bool == false { result = .unavailable }
                else { result = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? .requested : .failed }
            } else { result = .unavailable }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onCloseResult?(result)
                self.requestRefresh(pid: window.pid)
                if result == .requested {
                    self.focusQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self, self.focusGeneration.contains(generation),
                              let children = Self.attribute(window.element, kAXChildrenAttribute) as? [AXUIElement] else { return }
                        var hasSheet = false
                        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
                        for child in children.prefix(12) {
                            guard self.focusGeneration.contains(generation),
                                  ProcessInfo.processInfo.systemUptime < deadline else { return }
                            AXUIElementSetMessagingTimeout(child, 0.1)
                            if Self.attribute(child, kAXRoleAttribute) as? String == kAXSheetRole { hasSheet = true; break }
                        }
                        guard hasSheet else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.focusGeneration.contains(generation) else { return }
                            // Bring a native save/confirmation sheet into view; a newer user choice
                            // cancels this focus intent. We never answer the sheet for the user.
                            self.activate(window)
                        }
                    }
                    // Some apps close asynchronously or first ask whether to save. Keep actual
                    // AX liveness authoritative, including when the user cancels that prompt.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        self?.requestRefresh(pid: window.pid)
                    }
                }
            }
        }
    }

    private static func closeButton(_ window: AXUIElement) -> AXUIElement? {
        guard let value = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func raise(_ window: SwitchableWindow, app: AXUIElement, generation: UInt64) {
        guard focusGeneration.contains(generation) else { return }
        _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard focusGeneration.contains(generation) else { return }
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
        guard focusGeneration.contains(generation) else { return }
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    private func verifyFocus(_ window: SwitchableWindow, app: AXUIElement, generation: UInt64,
                             attempt: Int, keySent: Bool = false, keyAccepted: Bool? = nil) {
        focusQueue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.25 : 0.5)) { [weak self] in
            guard let self, self.focusGeneration.contains(generation) else { return }
            let focused = Self.attribute(app, kAXFocusedWindowAttribute)
            let matched = focused.map { CFEqual($0, window.element) } ?? false
            let visible = window.windowID.map { wid in
                let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]] ?? []
                return rows.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
            } ?? true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusGeneration.contains(generation) else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                self.lastFocusCheck = ["pid": window.pid, "attempt": attempt, "exactWindow": matched,
                    "visible": visible, "frontmost": front, "keySent": keySent,
                    "keyAccepted": keyAccepted.map { $0 as Any } ?? NSNull()]
                if visible && front && !keySent && window.windowID != nil && WindowActivation.canMakeKey {
                    // A key request sent before a fullscreen Space finishes appearing can be dropped.
                    // Send one paired process-targeted record only once the target is visible/front.
                    self.focusQueue.async { [weak self] in
                        guard let self, self.focusGeneration.contains(generation) else { return }
                        let accepted = WindowActivation.makeKey(pid: window.pid, windowID: window.windowID)
                        self.raise(window, app: app, generation: generation)
                        self.verifyFocus(window, app: app, generation: generation, attempt: attempt + 1,
                            keySent: true, keyAccepted: accepted)
                    }
                } else if matched && visible && front {
                    self.requestRefresh(pid: window.pid, focusPID: window.pid)
                    self.onFocusResult?(true)
                } else if attempt < 4 {
                    self.focusQueue.async { [weak self] in
                        guard let self, self.focusGeneration.contains(generation) else { return }
                        if front { self.raise(window, app: app, generation: generation) }
                        self.verifyFocus(window, app: app, generation: generation, attempt: attempt + 1,
                            keySent: keySent, keyAccepted: keyAccepted)
                    }
                } else {
                    self.requestRefresh(pid: window.pid)
                    self.onFocusResult?(false)
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
