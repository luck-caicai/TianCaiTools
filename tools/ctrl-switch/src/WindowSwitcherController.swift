import AppKit

final class WindowSwitcherController {
    private var keys = SwitcherKeyState()
    let inventory = WindowInventory()
    let previews = WindowPreviewProvider()
    private let panel = SwitcherPanel()
    private var ordered: [SwitchableWindow] = []
    private var selection: WindowSelection?
    private var showWork: DispatchWorkItem?
    private var keyboardAvailable = false
    private var closeFixturePID: pid_t?
    private(set) var isEnabled: Bool
    private(set) var previewsEnabled: Bool
    private(set) var committedSwitches = 0
    private(set) var confirmedSwitches = 0
    private(set) var arrowSelections = 0
    private(set) var hoverSelections = 0
    private(set) var closeRequests = 0
    private(set) var acceptedCloseRequests = 0
    private(set) var unconfirmedCloseRequests = 0
    private(set) var failedCloseRequests = 0
    private(set) var lastCloseResult = "none"
    var onChanged: (() -> Void)?
    var onKeyReleasesDrained: (() -> Void)?
    var hasPendingReleases: Bool { !keys.swallowedKeys.isEmpty }
    var isSelecting: Bool { selection != nil }
    var isPanelVisible: Bool { panel.isVisible }
    var panelSurfaceCount: Int { panel.visibleSurfaceCount }

    init(enabled: Bool, previewsEnabled: Bool) {
        isEnabled = enabled
        self.previewsEnabled = previewsEnabled
        keys.isEnabled = enabled
        inventory.onChanged = { [weak self] in self?.inventoryChanged() }
        previews.onImage = { [weak self] id, image in self?.panel.setImage(image, for: id) }
        previews.onEvicted = { [weak self] ids in self?.panel.evict(ids) }
        previews.onStatusChanged = { [weak self] in
            self?.renderIfVisible()
            self?.onChanged?()
        }
        panel.onChoose = { [weak self] id in
            guard let self, self.selection?.ids.contains(id) == true else { return }
            self.keys.cancel()
            self.finish(target: id)
        }
        panel.onHover = { [weak self] id in
            guard let self, self.panel.isVisible, self.selection?.ids.contains(id) == true,
                  self.selection?.hoveredID != id else { return }
            self.selection?.hover(id)
            self.hoverSelections += 1
            self.render()
        }
        panel.onClose = { [weak self] id in
            guard let self, self.selection?.ids.contains(id) == true,
                  let window = self.inventory.windows[id], window.canClose else { return }
            guard self.closeFixturePID == nil || self.closeFixturePID == window.pid else { return }
            self.keys.cancel()
            self.finish(target: nil)
            self.closeRequests += 1
            self.inventory.requestClose(window)
        }
        inventory.onFocusResult = { [weak self] success in
            if success { self?.confirmedSwitches += 1 }
            self?.onChanged?()
        }
        inventory.onCloseResult = { [weak self] result in
            guard let self else { return }
            self.lastCloseResult = result.rawValue
            switch result {
            case .requested: self.acceptedCloseRequests += 1
            case .unconfirmed: self.unconfirmedCloseRequests += 1
            case .stale: self.failedCloseRequests += 1
            case .unavailable, .failed: self.failedCloseRequests += 1
            }
            if result.shouldSignalFailure { NSSound.beep() }
            self.onChanged?()
        }
        previews.configure(enabled: enabled && previewsEnabled)
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value; keys.isEnabled = value
        if !value { cancel(); panel.releaseResources() }
        inventory.setEnabled(value && keyboardAvailable)
        previews.configure(enabled: value && previewsEnabled)
        onChanged?()
    }

    func setPreviewsEnabled(_ value: Bool) {
        previewsEnabled = value
        previews.configure(enabled: value && isEnabled)
        if !value { panel.clearCardImages() }
        renderIfVisible()
        onChanged?()
    }

    func setKeyboardAvailable(_ available: Bool) {
        keyboardAvailable = available
        if !available { cancel(resetKeys: true); panel.releaseResources() }
        inventory.setEnabled(isEnabled && available)
        if !available { previews.endSession(clear: true) }
        else { previews.configure(enabled: isEnabled && previewsEnabled) }
        onChanged?()
    }

    /// Called synchronously by the shared tap: no AX, screenshot, panel layout, or permission calls.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let result = keys.handle(type, key: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            canBegin: !ordered.isEmpty && keyboardAvailable, canNavigate: panel.isVisible)
        if let action = result.action {
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
        if result.consume, type == .keyUp, !isEnabled, !hasPendingReleases {
            DispatchQueue.main.async { [weak self] in self?.onKeyReleasesDrained?() }
        }
        return result.consume
    }

    func cancel(resetKeys: Bool = false) {
        if resetKeys { keys.reset() } else { keys.cancel() }
        finish(target: nil)
    }

    func stop() {
        cancel(resetKeys: true)
        inventory.setEnabled(false)
        previews.endSession(clear: true)
        panel.releaseResources()
    }

    private func perform(_ action: SwitcherKeyState.Action) {
        switch action {
        case .begin(let reverse):
            guard isEnabled, keyboardAvailable, !ordered.isEmpty else { keys.cancel(); return }
            inventory.cancelPendingActivation()
            selection = WindowSelection(ids: ordered.map(\.id), currentID: inventory.focusedID, reverse: reverse)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.selection != nil else { return }
                self.inventory.requestRefresh()
                self.previews.beginSession()
                self.render()
            }
            showWork?.cancel(); showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        case .cycle(let reverse):
            panel.keyboardSelectionChanged()
            selection?.cycle(reverse: reverse)
            renderIfVisible()
        case .navigate(let direction):
            guard panel.isVisible else { return }
            panel.keyboardSelectionChanged()
            let previous = selection?.highlightedID
            selection?.move(direction, columns: panel.columnCount)
            if selection?.selectedID != previous { arrowSelections += 1 }
            renderIfVisible()
        case .commit:
            finish(target: selection?.releaseTargetID)
        case .cancel:
            finish(target: nil)
        }
    }

    private func finish(target: String?) {
        let window = target.flatMap { inventory.windows[$0] }
        showWork?.cancel(); showWork = nil
        selection = nil
        panel.hide()
        previews.endSession(clear: false)
        if let window {
            committedSwitches += 1
            inventory.activate(window)
        }
        onChanged?()
    }

    private func inventoryChanged() {
        ordered = inventory.orderedWindows()
        let live = Set(inventory.windows.keys)
        previews.retain(live)
        if selection != nil {
            selection?.retain(live)
            if selection?.selectedID == nil { cancel() }
            else { renderIfVisible() }
        }
        onChanged?()
    }

    private func renderIfVisible() { if panel.isVisible { render() } }
    private func render() {
        guard let selection else { return }
        let windows = selection.ids.compactMap { inventory.windows[$0] }
        panel.show(windows: windows, selectedID: selection.highlightedID, previewStatus: previews.status,
                   pointerPreview: selection.pointerPreviewActive,
                   image: { [unowned self] in self.previews.image(for: $0) })
        let visible = panel.visibleIDs.compactMap { inventory.windows[$0] }
        let selected = selection.highlightedID
        previews.request(visible.sorted { $0.id == selected && $1.id != selected })
    }

    /// Opt-in local exercise: real panel/capture, 500 selection changes, no global input or window activation.
    func exercise(cycles: Int, completion: @escaping ([String: Any]) -> Void) {
        guard isEnabled, keyboardAvailable, !ordered.isEmpty else {
            completion(["exercised": false, "reason": "keyboard permission or window inventory unavailable"]); return
        }
        selection = WindowSelection(ids: ordered.map(\.id), currentID: inventory.focusedID, reverse: false)
        previews.beginSession()
        render()
        let countBefore = previews.completedCaptures
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var remaining = cycles
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if remaining % 5 == 0 {
                self.selection?.cycle(reverse: remaining % 3 == 0)
            } else {
                self.panel.keyboardSelectionChanged()
                let direction = SelectionDirection.allCases[remaining % 4]
                self.selection?.move(direction, columns: self.panel.columnCount)
            }
            self.render()
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                let count = self.previews.cachedCount, bytes = self.previews.cachedBytes
                let images = self.previews.completedCaptures - countBefore
                self.cancel(resetKeys: true)
                completion(["exercised": true, "selectionCycles": cycles, "cachedImages": count,
                    "cachedBytes": bytes, "newCaptures": images, "panelHiddenAfterCancel": !self.panel.isVisible,
                    "foregroundUnchanged": frontBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Manual integration QA only. Keep a fixed set of explicitly created disposable windows;
    /// the normal close callback cannot affect other apps while this fixture mode is active.
    func showCloseFixture(pid: pid_t) {
        let windows = ordered.filter { $0.pid == pid }
        guard keyboardAvailable, !windows.isEmpty else { return }
        closeFixturePID = pid
        inventory.cancelPendingActivation()
        selection = WindowSelection(ids: windows.map(\.id), currentID: nil, reverse: false)
        previews.beginSession()
        render()
        let timeout = DispatchWorkItem { [weak self] in self?.cancel(resetKeys: true) }
        showWork?.cancel(); showWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }
}
