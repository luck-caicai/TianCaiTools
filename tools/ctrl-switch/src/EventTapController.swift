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
    private var permissionTimer: Timer?
    private var frontmostIsTerminal = false
    private var sessionIsActive = true
    private(set) var status: Status = .disabled
    var onStatusChanged: ((Status) -> Void)?

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
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stopTap() })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconcile() })
    }

    func start() { reconcile() }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopTap()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    func reconcile() {
        guard sessionIsActive else { setStatus(.suspended); return }
        guard transformer.isEnabled else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            // Keep the tap only long enough to deliver matching releases for keys already down.
            if transformer.mappedKeysDown.isEmpty { stopTap() }
            setStatus(.disabled)
            return
        }
        guard AXIsProcessTrusted() else {
            stopTap()
            setStatus(.needsPermission)
            watchForPermission()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            setStatus(.enabled)
            return
        }
        stopTap()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
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
            setStatus(.unavailable)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            setStatus(.unavailable)
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setStatus(.enabled)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            transformer.reset()
            if transformer.isEnabled, sessionIsActive, AXIsProcessTrusted(), let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.reconcile() }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let flags = transformer.transformedFlags(
            type: type, keyCode: keyCode, flags: event.flags, bypass: frontmostIsTerminal
        ) {
            event.flags = flags
        }

        if !transformer.isEnabled, transformer.mappedKeysDown.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
        return Unmanaged.passUnretained(event)
    }

    private func updateFrontmostApplication() {
        let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        frontmostIsTerminal = ShortcutTransformer.isTerminal(bundleIdentifier: identifier)
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChanged?(newStatus)
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
    }
}
