import AppKit

private final class SwitcherHUD: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowCard: NSView {
    let id: String
    private let picture = CALayer()
    private let placeholder = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    var onClick: ((String) -> Void)?
    var onHover: ((String) -> Void)?

    init(window: SwitchableWindow, icon: NSImage?, frame: NSRect) {
        id = window.id
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 2
        picture.frame = CGRect(x: 10, y: 53, width: frame.width - 20, height: frame.height - 63)
        picture.contentsGravity = .resizeAspect
        picture.cornerRadius = 6
        picture.masksToBounds = true
        picture.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        placeholder.frame = CGRect(x: (frame.width - 44) / 2, y: 88, width: 44, height: 44)
        placeholder.image = icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholder)
        let appIcon = NSImageView(frame: CGRect(x: 12, y: 15, width: 24, height: 24))
        appIcon.image = icon
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(appIcon)
        let title = NSTextField(labelWithString: window.title)
        title.frame = CGRect(x: 43, y: 26, width: frame.width - 54, height: 17)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(title)
        let app = NSTextField(labelWithString: window.applicationName)
        app.frame = CGRect(x: 43, y: 10, width: frame.width - 54, height: 15)
        app.font = .systemFont(ofSize: 10)
        app.textColor = .secondaryLabelColor
        app.lineBreakMode = .byTruncatingTail
        addSubview(app)
        stateLabel.stringValue = window.minimized ? "已最小化" : (window.fullscreen ? "全屏" : "")
        stateLabel.frame = CGRect(x: 14, y: 58, width: 68, height: 15)
        stateLabel.font = .systemFont(ofSize: 9)
        stateLabel.textColor = .white
        stateLabel.drawsBackground = true
        stateLabel.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        stateLabel.isHidden = !window.minimized && !window.fullscreen
        addSubview(stateLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(window.applicationName)，\(window.title)")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(id) }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(id) }
    override func mouseMoved(with event: NSEvent) { onHover?(id) }
    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.13) : .clear).cgColor
        layer?.borderColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
        setAccessibilityValue(selected ? "已选中" : "")
    }
    func setImage(_ image: CGImage?) {
        picture.contents = image
        placeholder.isHidden = image != nil
    }
}

final class SwitcherPanel {
    private var panel: SwitcherHUD?
    private var root: NSVisualEffectView?
    private var cards: [String: WindowCard] = [:]
    private var footer: NSTextField?
    private var countLabel: NSTextField?
    private var lastVisibleIDs: [String] = []
    private var lastColumns = 0
    private var icons: [pid_t: NSImage] = [:]
    private var hover = HoverSelectionState()
    var onChoose: ((String) -> Void)?
    var onHover: ((String) -> Void)?
    private(set) var columnCount = 1
    var isVisible: Bool { panel?.isVisible == true }
    var visibleIDs: [String] { lastVisibleIDs }

    func show(windows: [SwitchableWindow], selectedID: String?, previewStatus: WindowPreviewProvider.Status,
              pointerPreview: Bool = false,
              image: (String) -> CGImage?) {
        guard !windows.isEmpty else { hide(); return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width: CGFloat = 210, height: CGFloat = 181, gap: CGFloat = 10, padding: CGFloat = 18
        let columns = min(windows.count, max(1, min(4, Int((available.width - padding * 2 + gap) / (width + gap)))))
        columnCount = columns
        if !isVisible { hover.rebase(at: NSEvent.mouseLocation) }
        let maxRows = max(1, min(2, Int((available.height - 100) / (height + gap))))
        let capacity = columns * maxRows
        let selected = selectedID.flatMap { id in windows.firstIndex { $0.id == id } } ?? 0
        let pageStart = (selected / capacity) * capacity
        let visible = Array(windows.dropFirst(pageStart).prefix(capacity))
        let ids = visible.map(\.id)
        let rows = (visible.count + columns - 1) / columns
        let panelSize = CGSize(width: CGFloat(columns) * (width + gap) - gap + padding * 2,
                               height: CGFloat(rows) * (height + gap) - gap + 75)
        if panel == nil {
            let hud = SwitcherHUD(contentRect: CGRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hud.isReleasedWhenClosed = false
            hud.level = .floating
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            hud.isOpaque = false
            hud.backgroundColor = .clear
            hud.hasShadow = true
            hud.hidesOnDeactivate = false
            hud.animationBehavior = .none
            hud.acceptsMouseMovedEvents = true
            let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: panelSize))
            content.material = .hudWindow
            content.blendingMode = .behindWindow
            content.state = .active
            content.wantsLayer = true
            content.layer?.cornerRadius = 17
            content.layer?.masksToBounds = true
            hud.contentView = content
            root = content
            panel = hud
        }
        guard let panel, let root else { return }
        if ids != lastVisibleIDs || columns != lastColumns || root.frame.size != panelSize {
            clearCardImages()
            root.subviews.forEach { $0.removeFromSuperview() }
            cards.removeAll()
            for (index, window) in visible.enumerated() {
                let column = index % columns, row = index / columns
                let frame = CGRect(x: padding + CGFloat(column) * (width + gap),
                    y: panelSize.height - 18 - height - CGFloat(row) * (height + gap), width: width, height: height)
                let icon: NSImage?
                if let cached = icons[window.pid] { icon = cached }
                else {
                    icon = NSRunningApplication(processIdentifier: window.pid)?.icon.map { Self.smallIcon($0) }
                    if icons.count >= 24 { icons.removeAll() }
                    if let icon { icons[window.pid] = icon }
                }
                let card = WindowCard(window: window, icon: icon, frame: frame)
                card.onClick = { [weak self] id in self?.onChoose?(id) }
                card.onHover = { [weak self] id in self?.hovered(id) }
                root.addSubview(card)
                cards[window.id] = card
            }
            let instructions = NSTextField(labelWithString: "")
            instructions.frame = CGRect(x: padding + 2, y: 17, width: panelSize.width - 100, height: 16)
            instructions.font = .systemFont(ofSize: 10.5)
            instructions.textColor = .secondaryLabelColor
            instructions.lineBreakMode = .byTruncatingTail
            root.addSubview(instructions)
            footer = instructions
            let count = NSTextField(labelWithString: "")
            count.frame = CGRect(x: panelSize.width - 78, y: 17, width: 58, height: 16)
            count.alignment = .right
            count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            root.addSubview(count)
            countLabel = count
            lastVisibleIDs = ids
            lastColumns = columns
        }
        let hint: String
        switch previewStatus {
        case .needsPermission: hint = "右键菜单允许屏幕录制后可显示预览"
        case .paused: hint = "预览暂时暂停，窗口切换仍可使用"
        default: hint = pointerPreview ? "单击切换 · 松开 Alt 取消 · Esc 关闭"
            : "方向键 / Tab 选择 · 松开 Alt 切换 · Esc 取消"
        }
        footer?.stringValue = hint
        countLabel?.stringValue = "\(selected + 1) / \(windows.count)"
        for window in visible {
            cards[window.id]?.setSelected(window.id == selectedID)
            cards[window.id]?.setImage(image(window.id))
        }
        panel.setFrame(CGRect(x: available.midX - panelSize.width / 2, y: available.midY - panelSize.height / 2,
                              width: panelSize.width, height: panelSize.height), display: true)
        root.frame = CGRect(origin: .zero, size: panelSize)
        panel.orderFrontRegardless()
    }

    func setImage(_ image: CGImage, for id: String) { cards[id]?.setImage(image) }
    func keyboardSelectionChanged() { hover.rebase(at: NSEvent.mouseLocation) }
    private func hovered(_ id: String) {
        guard isVisible, pointerInside(id), hover.moved(to: NSEvent.mouseLocation) else { return }
        onHover?(id)
    }
    private func pointerInside(_ id: String) -> Bool {
        guard let panel, let card = cards[id] else { return false }
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return card.visibleRect.contains(card.convert(point, from: nil))
    }
    func evict(_ ids: Set<String>) { ids.forEach { cards[$0]?.setImage(nil) } }
    func clearCardImages() { cards.values.forEach { $0.setImage(nil) } }
    func hide() {
        panel?.orderOut(nil)
        clearCardImages()
        root?.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll(); lastVisibleIDs.removeAll(); footer = nil; countLabel = nil
        hover.reset()
        columnCount = 1
        lastColumns = 0
    }
    func releaseResources() {
        hide()
        panel?.close()
        panel = nil; root = nil; icons.removeAll()
    }
    #if UI_FIXTURE
    func snapshotPNG() -> Data? {
        guard let root, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
    #endif
    private static func smallIcon(_ image: NSImage) -> NSImage {
        let small = NSImage(size: NSSize(width: 48, height: 48))
        small.lockFocus()
        image.draw(in: CGRect(x: 0, y: 0, width: 48, height: 48),
                   from: .zero, operation: .sourceOver, fraction: 1)
        small.unlockFocus()
        return small
    }
}
