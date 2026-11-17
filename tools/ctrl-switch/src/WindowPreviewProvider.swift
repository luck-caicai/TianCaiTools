import AppKit
import ScreenCaptureKit

/// Main owns state/cache; a serial worker prepares screenshots and copies small owned bitmaps.
/// No SCStream, audio, files, network, or background screenshot polling.
final class WindowPreviewProvider {
    enum Status: String { case disabled, ready, needsPermission, unsupported, paused }
    private let worker = DispatchQueue(label: "local.ctrlswitch.previews", qos: .userInitiated)
    private var cache = ImageBudget<CGImage>(countLimit: 12, byteLimit: 8 * 1024 * 1024)
    private var admission = CaptureAdmission()
    private var active = false
    private var pending: [SwitchableWindow] = []
    private var attempted = Set<String>()
    private var liveIDs = Set<String>()
    private var timeout: DispatchWorkItem?
    private var expiry: DispatchWorkItem?
    private var pressure: DispatchSourceMemoryPressure?
    private var scWindows: [CGWindowID: SCWindow] = [:] // main only
    private var discoveryAt: TimeInterval = 0
    private(set) var isEnabled = true
    private(set) var status: Status = .disabled
    private(set) var completedCaptures = 0
    private(set) var failedCaptures = 0
    var onImage: ((String, CGImage) -> Void)?
    var onEvicted: ((Set<String>) -> Void)?
    var onStatusChanged: (() -> Void)?
    var cachedCount: Int { cache.count }
    var cachedBytes: Int { cache.bytes }
    var hasInFlightRequest: Bool { admission.inFlight != nil }
    var generation: UInt64 { admission.generation }

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.endSession(clear: true) }
        source.resume()
        pressure = source
    }

    func configure(enabled: Bool) {
        isEnabled = enabled
        if !enabled { endSession(clear: true) }
        else { admission.retry() }
        refreshPermission()
    }

    func refreshPermission() {
        guard isEnabled else { setStatus(.disabled); return }
        guard #available(macOS 26, *) else { setStatus(.unsupported); return }
        guard CGPreflightScreenCaptureAccess() else {
            endSession(clear: true)
            setStatus(.needsPermission)
            return
        }
        setStatus(admission.paused ? .paused : .ready)
    }

    func beginSession() {
        expiry?.cancel(); expiry = nil
        _ = admission.newSession()
        active = true
        pending.removeAll(); attempted.removeAll()
        refreshPermission()
    }

    func image(for id: String) -> CGImage? { cache.value(for: id) }

    func endSession(clear: Bool) {
        active = false
        admission.invalidateSession()
        pending.removeAll(); attempted.removeAll()
        expiry?.cancel(); expiry = nil
        if clear {
            clearImages()
            scWindows.removeAll(); discoveryAt = 0
        } else if cache.count > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.clearImages()
                self?.scWindows.removeAll()
                self?.discoveryAt = 0
            }
            expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    private func clearImages() {
        let removed = cache.keys
        cache = ImageBudget(countLimit: 12, byteLimit: 8 * 1024 * 1024)
        scWindows.removeAll(); discoveryAt = 0
        if !removed.isEmpty { onEvicted?(removed) }
    }

    func request(_ windows: [SwitchableWindow]) {
        guard active, status == .ready else { return }
        // Replacing the waiting set makes an old viewport disposable before submitting to macOS.
        pending = windows.filter { !attempted.contains($0.id) && $0.windowID != nil && !$0.minimized }
        drain()
    }

    private func drain() {
        guard active, status == .ready, !pending.isEmpty, let lease = admission.begin() else { return }
        let window = pending.removeFirst()
        attempted.insert(window.id)
        let session = admission.generation
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.admission.inFlight == lease else { return }
            self.admission.timeout(lease)
            self.pending.removeAll()
            self.setStatus(.paused)
        }
        timeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: watchdog)
        guard #available(macOS 26, *) else { finish(lease, session, window.id, nil); return }
        if ProcessInfo.processInfo.systemUptime - discoveryAt > 10 { scWindows.removeAll() }
        if let wid = window.windowID, let known = scWindows[wid], known.owningApplication?.processID == window.pid {
            capture(known, window, lease, session)
        } else {
            discoverAndCapture(window, lease, session)
        }
    }

    @available(macOS 26, *)
    private func discoverAndCapture(_ window: SwitchableWindow, _ lease: UInt64, _ session: UInt64) {
        worker.async { [weak self] in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.active, !self.admission.paused, self.admission.generation == session,
                          let content, error == nil else { self.finish(lease, session, window.id, nil); return }
                    self.scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { _, new in new })
                    self.discoveryAt = ProcessInfo.processInfo.systemUptime
                    guard let wid = window.windowID, let known = self.scWindows[wid],
                          known.owningApplication?.processID == window.pid else {
                        self.finish(lease, session, window.id, nil); return
                    }
                    self.capture(known, window, lease, session)
                }
            }
        }
    }

    func retain(_ live: Set<String>) {
        liveIDs = live
        let removed = cache.keys.subtracting(live)
        removed.forEach { cache.remove($0) }
        if !removed.isEmpty { onEvicted?(removed) }
        pending.removeAll { !live.contains($0.id) }
    }

    func stop() {
        endSession(clear: true)
        pressure?.cancel(); pressure = nil
        // An outstanding screenshot has no cancel API; late callbacks remain generation guarded.
    }

    @available(macOS 26, *)
    private func capture(_ scWindow: SCWindow, _ window: SwitchableWindow, _ requestID: UInt64, _ session: UInt64) {
        guard active, admission.generation == session, !admission.paused,
              let pixels = PreviewSizing.pixels(for: scWindow.frame.size) else {
            finish(requestID, session, window.id, nil); return
        }
        worker.async { [weak self] in
            let configuration = SCScreenshotConfiguration()
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            configuration.ignoreShadows = true
            configuration.includeChildWindows = false
            configuration.dynamicRange = .sdr
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { [weak self] output, error in
                guard let self else { return }
                self.worker.async { [weak self] in
                    // Copy only the tiny output to release any OS-owned backing surface promptly.
                    let bitmap = error == nil ? output?.sdrImage.flatMap(Self.ownedThumbnail) : nil
                    DispatchQueue.main.async { [weak self] in self?.finish(requestID, session, window.id, bitmap) }
                }
            }
        }
    }

    private static func ownedThumbnail(_ image: CGImage) -> CGImage? {
        guard let size = PreviewSizing.pixels(for: CGSize(width: image.width, height: image.height)) else { return nil }
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func finish(_ requestID: UInt64, _ session: UInt64, _ id: String, _ image: CGImage?) {
        guard admission.inFlight == requestID else { return }
        timeout?.cancel(); timeout = nil
        let accepted = admission.finish(requestID, session: session)
        if accepted, active, isEnabled, liveIDs.contains(id) {
            guard CGPreflightScreenCaptureAccess() else {
                endSession(clear: true); setStatus(.needsPermission); return
            }
            if let image {
                let removed = cache.insert(image, for: id, cost: image.bytesPerRow * image.height)
                if !removed.isEmpty { onEvicted?(removed) }
                if cache.keys.contains(id) { onImage?(id, image); completedCaptures += 1 }
            } else { failedCaptures += 1 }
        }
        drain()
    }

    private func setStatus(_ value: Status) {
        guard status != value else { return }
        status = value
        onStatusChanged?()
    }
}
