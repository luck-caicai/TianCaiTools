import AppKit
import ApplicationServices
import CoreGraphics

final class EventTapController {
    enum Status: String {
        case enabled, disabled, needsPermission, unavailable, suspended
    }

    private var transformer = ShortcutTransformer()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var frontmostBypassesCtrl = false
    private(set) var remoteInputPassthrough = false
    private var sessionIsActive = true
    private var systemIsAwake = true
    private var screenIsLocked = false
    private(set) var status: Status = .disabled
    var onStatusChanged: ((Status) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?
    var onKeyboardEvent: ((CGEventType, CGEvent) -> Bool)?
    var onInputInterrupted: (() -> Void)?
    var onRemotePassthroughChanged: ((Bool) -> Void)?
    var hasPendingSwitcherReleases: (() -> Bool)?
    private(set) var isAvailable = false
    var switcherEnabled = false { didSet { reconcile() } }

    var isEnabled: Bool {
        get { transformer.isEnabled }
        set {
            transformer.isEnabled = newValue
            reconcile()
        }
    }

    init(enabled: Bool) {
        transformer.isEnabled = enabled
        updateFrontmostApplication()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFrontmostApplication() })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionIsActive = false
            self?.stopTap()
            self?.setStatus(.suspended)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionIsActive = true
            self?.reconcile()
        })
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.screenIsLocked = locked
                self.reconcile()
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemIsAwake = false
            self?.stopTap()
            self?.setStatus(.suspended)
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemIsAwake = true
            self?.reconcile()
        })
    }

    func start() { reconcile() }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopTap()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers.removeAll()
    }

    func reconcile() {
        guard sessionIsActive, systemIsAwake, !screenIsLocked else {
            permissionTimer?.invalidate(); permissionTimer = nil
            stopTap(); setStatus(.suspended); return
        }
        guard transformer.isEnabled || switcherEnabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            // Keep the tap only long enough to deliver matching releases for keys already down.
            if transformer.mappedKeysDown.isEmpty && hasPendingSwitcherReleases?() != true { stopTap() }
            setStatus(.disabled)
            return
        }
        guard AXIsProcessTrusted() else {
            stopTap()
            setStatus(transformer.isEnabled ? .needsPermission : .disabled)
            watchForPermission()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            setStatus(transformer.isEnabled ? .enabled : .disabled)
            setAvailable(true)
            return
        }
        stopTap()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<EventTapController>.fromOpaque(context).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            setStatus(transformer.isEnabled ? .unavailable : .disabled)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            setStatus(transformer.isEnabled ? .unavailable : .disabled)
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setStatus(transformer.isEnabled ? .enabled : .disabled)
        setAvailable(true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            transformer.reset()
            onInputInterrupted?()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopTap()
                self.reconcile()
            }
            return Unmanaged.passUnretained(event)
        }

        if onKeyboardEvent?(type, event) == true { return nil }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let flags = transformer.transformedFlags(
            type: type, keyCode: keyCode, flags: event.flags, bypass: frontmostBypassesCtrl
        ) {
            event.flags = flags
        }

        if !transformer.isEnabled, !switcherEnabled, transformer.mappedKeysDown.isEmpty,
           hasPendingSwitcherReleases?() != true {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
        return Unmanaged.passUnretained(event)
    }

    private func updateFrontmostApplication() {
        let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let remote = ShortcutTransformer.isRemoteControl(bundleIdentifier: identifier)
        frontmostBypassesCtrl = remote || ShortcutTransformer.isTerminal(bundleIdentifier: identifier)
        guard remote != remoteInputPassthrough else { return }
        remoteInputPassthrough = remote
        onRemotePassthroughChanged?(remote)
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChanged?(newStatus)
    }

    private func setAvailable(_ value: Bool) {
        guard isAvailable != value else { return }
        isAvailable = value
        onAvailabilityChanged?(value)
    }

    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() { self.reconcile() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        transformer.reset()
        setAvailable(false)
    }
}
