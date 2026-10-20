import AppKit

/// A screenshot pinned above all windows. Drag to move, scroll to resize, right-click for options.
final class PinPanel: NSPanel {
    @MainActor private static var open: [PinPanel] = []

    private let image: CGImage
    private let pixelScale: CGFloat

    @MainActor
    static func pin(image: CGImage, pixelScale: CGFloat) {
        let panel = PinPanel(image: image, pixelScale: pixelScale)
        open.append(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private init(image: CGImage, pixelScale: CGFloat) {
        self.image = image
        self.pixelScale = pixelScale
        var size = CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale)
        let screen = NSScreen.withMouse.visibleFrame
        let fit = min(1, screen.width * 0.6 / size.width, screen.height * 0.6 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        contentView = PinView(image: ImageIOHelper.nsImage(image, pixelScale: pixelScale))
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "w": closePin(); return true
        case "c": copyImage(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func closePin() {
        orderOut(nil)
        MainActor.assumeIsolated { PinPanel.open.removeAll { $0 === self } }
    }

    @objc func copyImage() {
        Clipboard.copy(image: image, pixelScale: pixelScale)
        MainActor.assumeIsolated { Toast.show("Copied to clipboard") }
    }

    @objc func annotate() {
        MainActor.assumeIsolated { AnnotateWindowController.open(image: image, pixelScale: pixelScale) }
        closePin()
    }

    @objc func saveImage() {
        MainActor.assumeIsolated {
            guard let data = ImageIOHelper.pngData(image, pixelScale: pixelScale) else { return }
            let url = HistoryStore.uniqueURL(in: Settings.saveDirectory, name: Settings.fileName(ext: "png"))
            do {
                try data.write(to: url)
                Toast.show("Saved", symbol: "square.and.arrow.down.fill")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }

    @objc func resetSize() {
        let size = CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale)
        resize(to: size)
    }

    func resize(to size: CGSize) {
        let f = frame
        let new = CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        setFrame(new, display: true)
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c")
        m.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "")
        m.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "")
        m.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 75, 50, 25] {
            let item = sub.addItem(withTitle: "\(v)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = v
            item.state = Int((alphaValue * 100).rounded()) == v ? .on : .off
        }
        opacity.submenu = sub
        m.addItem(opacity)
        m.addItem(withTitle: "Actual Size", action: #selector(resetSize), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w")
        m.items.forEach { $0.target = self; $0.submenu?.items.forEach { $0.target = self } }
        return m
    }
}

private final class PinView: NSView {
    private let image: NSImage
    private let closeButton: NSButton

    init(image: NSImage) {
        self.image = image
        closeButton = NSButton(image: NSImage.symbol("xmark", size: 10, weight: .bold) ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.action = #selector(PinPanel.closePin)
        closeButton.isHidden = true
        addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 20), closeButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { closeButton.target = window }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? { (window as? PinPanel)?.menu() }

    override func scrollWheel(with event: NSEvent) {
        guard let panel = window as? PinPanel else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let factor = max(0.5, min(1.5, 1 + delta * 0.01))
        let size = panel.frame.size
        let newWidth = max(60, size.width * factor)
        panel.resize(to: CGSize(width: newWidth, height: newWidth * size.height / size.width))
    }
}
