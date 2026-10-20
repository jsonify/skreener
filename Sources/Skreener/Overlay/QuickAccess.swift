import AppKit
import AVFoundation

/// Floating thumbnails shown after each capture, stacked in the bottom-left corner.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var panels: [QuickAccessPanel] = []
    private var recentlyClosed: [CaptureItem] = []
    private let margin: CGFloat = 16

    var hasRecentlyClosed: Bool { !recentlyClosed.isEmpty }

    func show(_ item: CaptureItem) {
        Task {
            guard let thumb = await Self.thumbnail(for: item) else { return }
            let panel = QuickAccessPanel(item: item, thumbnail: thumb, manager: self)
            let screen = NSScreen.withMouse.visibleFrame
            panel.setFrameOrigin(CGPoint(x: screen.minX - panel.frame.width, y: screen.minY + margin))
            panels.insert(panel, at: 0)
            panel.orderFrontRegardless()
            layout()
            let seconds = Settings.overlayAutoClose
            if seconds > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak panel] in
                    guard let panel, !panel.isHovered else { return }
                    self.close(panel)
                }
            }
        }
    }

    func close(_ panel: QuickAccessPanel, remember: Bool = true) {
        guard let i = panels.firstIndex(of: panel) else { return }
        panels.remove(at: i)
        if remember { recentlyClosed.append(panel.item) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
        layout()
    }

    func closeAll() { panels.forEach { close($0) } }

    func restoreRecentlyClosed() {
        guard let item = recentlyClosed.popLast() else { return }
        if FileManager.default.fileExists(atPath: item.url.path) { show(item) }
    }

    private func layout() {
        let screen = NSScreen.withMouse.visibleFrame
        var y = screen.minY + margin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            for panel in panels {
                var f = panel.frame
                f.origin = CGPoint(x: screen.minX + margin, y: y)
                panel.animator().setFrame(f, display: true)
                y += f.height + 10
            }
        }
    }

    static func thumbnail(for item: CaptureItem) async -> NSImage? {
        switch item.kind {
        case .image:
            guard let (cg, scale) = item.loadImage() else { return nil }
            return ImageIOHelper.nsImage(cg, pixelScale: scale)
        case .video where item.url.pathExtension.lowercased() == "gif":
            guard let (cg, _) = ImageIOHelper.load(item.url) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            guard let cg = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    // MARK: Actions

    func copy(_ item: CaptureItem) {
        if item.kind == .image, let (cg, scale) = item.loadImage() {
            Clipboard.copy(image: cg, pixelScale: scale)
        } else {
            Clipboard.copy(fileURL: item.url)
        }
        Toast.show("Copied to clipboard")
    }

    func save(_ item: CaptureItem) {
        do {
            let url = try item.export()
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func annotate(_ item: CaptureItem) {
        switch item.kind {
        case .image:
            guard let (cg, scale) = item.loadImage() else { return }
            AnnotateWindowController.open(image: cg, pixelScale: scale)
        case .video:
            NSWorkspace.shared.open(item.url)
        }
    }

    func pin(_ item: CaptureItem) {
        guard item.kind == .image, let (cg, scale) = item.loadImage() else { return }
        PinPanel.pin(image: cg, pixelScale: scale)
    }
}

final class QuickAccessPanel: NSPanel {
    let item: CaptureItem
    var isHovered: Bool { (contentView as? QuickAccessView)?.hovered ?? false }

    @MainActor
    init(item: CaptureItem, thumbnail: NSImage, manager: QuickAccessManager) {
        self.item = item
        let width: CGFloat = 220
        let aspect = thumbnail.size.height / max(thumbnail.size.width, 1)
        let height = min(max(width * aspect, 96), 240)
        super.init(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = QuickAccessView(item: item, thumbnail: thumbnail, manager: manager)
    }

    override var canBecomeKey: Bool { true }
}

private final class QuickAccessView: NSView, NSDraggingSource {
    private let item: CaptureItem
    private let thumbnail: NSImage
    private unowned let manager: QuickAccessManager
    private let controls = NSView()
    private var mouseDownEvent: NSEvent?
    private(set) var hovered = false

    @MainActor
    init(item: CaptureItem, thumbnail: NSImage, manager: QuickAccessManager) {
        self.item = item
        self.thumbnail = thumbnail
        self.manager = manager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.black.cgColor

        let imageView = NSImageView(image: thumbnail)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.unregisterDraggedTypes()
        addFilling(imageView)

        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        controls.alphaValue = 0
        addFilling(controls)

        let isImage = item.kind == .image
        let center = NSStackView(views: [
            pill(isImage ? "Copy" : "Copy File", #selector(copyItem)),
            pill("Save", #selector(saveItem)),
        ])
        center.orientation = .vertical
        center.spacing = 8
        controls.addSubview(center)
        center.translatesAutoresizingMaskIntoConstraints = false
        center.centerXAnchor.constraint(equalTo: controls.centerXAnchor).isActive = true
        center.centerYAnchor.constraint(equalTo: controls.centerYAnchor).isActive = true

        corner("xmark", #selector(closeItem), x: .left, y: .top, tip: "Close")
        corner(isImage ? "pencil.tip" : "play.fill", #selector(annotateItem), x: .left, y: .bottom,
               tip: isImage ? "Annotate" : "Open")
        if isImage { corner("pin.fill", #selector(pinItem), x: .right, y: .top, tip: "Pin to screen") }
        if item.kind == .video { corner("video.fill", nil, x: .right, y: .bottom, tip: "Video") }

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addFilling(_ v: NSView) {
        addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func pill(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        b.layer?.cornerRadius = 13
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black,
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 92).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private enum HEdge { case left, right }
    private enum VEdge { case top, bottom }

    private func corner(_ symbol: String, _ action: Selector?, x: HEdge, y: VEdge, tip: String) {
        let b = NSButton(image: NSImage.symbol(symbol, size: 11, weight: .bold) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        b.layer?.cornerRadius = 12
        b.isEnabled = action != nil
        controls.addSubview(b)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 24), b.heightAnchor.constraint(equalToConstant: 24),
            x == .left ? b.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 7)
                : b.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -7),
            y == .top ? b.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7)
                : b.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -7),
        ])
    }

    private var panel: QuickAccessPanel? { window as? QuickAccessPanel }

    @objc private func copyItem() { MainActor.assumeIsolated { manager.copy(item) } ; closeSelf(remember: true) }
    @objc private func saveItem() { MainActor.assumeIsolated { manager.save(item) } ; closeSelf(remember: true) }
    @objc private func annotateItem() { MainActor.assumeIsolated { manager.annotate(item) } ; closeSelf(remember: true) }
    @objc private func pinItem() { MainActor.assumeIsolated { manager.pin(item) } ; closeSelf(remember: true) }
    @objc private func closeItem() { closeSelf(remember: true) }

    private func closeSelf(remember: Bool) {
        guard let panel else { return }
        MainActor.assumeIsolated { manager.close(panel, remember: remember) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; controls.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; controls.animator().alphaValue = 0 }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { annotateItem() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        mouseDownEvent = nil
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        dragItem.setDraggingFrame(bounds, contents: thumbnail)
        beginDraggingSession(with: [dragItem], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { closeSelf(remember: true) }
    }
}
