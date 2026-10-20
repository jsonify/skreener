import AppKit

enum SelectionResult {
    case area(CGRect, NSScreen)
    case window(PickableWindow)
}

/// Full-screen overlay used to pick an area or a window on any display.
/// Space toggles area/window mode (when allowed), Escape cancels.
@MainActor
final class SelectionController {
    enum Mode { case area, window }
    /// What a click without dragging does in area mode.
    enum ClickAction { case none, window, fullscreen }

    private static var active: SelectionController?

    private(set) var mode: Mode
    private let allowWindowMode: Bool
    private let clickAction: ClickAction
    private let frozen: FrozenScreens?
    private let completion: (SelectionResult?) -> Void

    private var windows: [SelectionWindow] = []
    private var monitor: Any?
    private let pickable: [PickableWindow]

    private(set) var mouse: CGPoint = NSEvent.mouseLocation
    private(set) var selection: CGRect?
    private(set) var hoverWindow: PickableWindow?
    private var dragStart: CGPoint?
    private var dragScreen: NSScreen?

    /// With `frozen`, each display shows its snapshot behind the selection UI, so the screen
    /// appears frozen and transient UI (tooltips, menus, hover states) stays selectable.
    static func begin(mode: Mode, allowWindowMode: Bool, clickAction: ClickAction, frozen: FrozenScreens? = nil,
                      completion: @escaping (SelectionResult?) -> Void) {
        active?.finish(nil)
        let controller = SelectionController(mode: mode, allowWindowMode: allowWindowMode,
                                             clickAction: clickAction, frozen: frozen, completion: completion)
        active = controller
        controller.show()
    }

    private init(mode: Mode, allowWindowMode: Bool, clickAction: ClickAction, frozen: FrozenScreens?,
                 completion: @escaping (SelectionResult?) -> Void) {
        self.mode = mode
        self.allowWindowMode = allowWindowMode
        self.clickAction = clickAction
        self.frozen = frozen
        self.completion = completion
        self.pickable = ScreenCapturer.onScreenWindows()
    }

    private func show() {
        for screen in NSScreen.screens {
            let w = SelectionWindow(screen: screen, controller: self, frozenImage: frozen?.image(for: screen))
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screenRef == NSScreen.withMouse } ?? windows.first)?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.mouseMoved()
            return e
        }
        updateHover()
    }

    private func finish(_ result: SelectionResult?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if Self.active === self { Self.active = nil }
        // Let the window server drop the overlay before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [completion] in completion(result) }
    }

    private func redraw() { windows.forEach { $0.selectionView.needsDisplay = true } }

    private func updateHover() {
        hoverWindow = pickable.first { $0.frame.contains(mouse) }
    }

    // MARK: Events (all positions are global AppKit coordinates)

    func mouseMoved() {
        mouse = NSEvent.mouseLocation
        updateHover()
        redraw()
    }

    func mouseDown() {
        mouse = NSEvent.mouseLocation
        if mode == .window {
            if let w = hoverWindow { finish(.window(w)) }
            return
        }
        dragStart = mouse
        dragScreen = NSScreen.withMouse
        selection = nil
    }

    func mouseDragged() {
        mouse = NSEvent.mouseLocation
        guard mode == .area, let start = dragStart, let screen = dragScreen else { return }
        let r = CGRect(x: min(start.x, mouse.x), y: min(start.y, mouse.y),
                       width: abs(mouse.x - start.x), height: abs(mouse.y - start.y))
        selection = r.integral.intersection(screen.frame)
        redraw()
    }

    func mouseUp() {
        guard mode == .area, let screen = dragScreen else { return }
        dragStart = nil
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            finish(.area(sel, screen))
            return
        }
        selection = nil
        switch clickAction {
        case .none: redraw()
        case .window:
            if let w = hoverWindow { finish(.window(w)) } else { redraw() }
        case .fullscreen: finish(.area(screen.frame, screen))
        }
    }

    func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: finish(nil) // Escape
        case 49 where allowWindowMode: // Space
            mode = mode == .area ? .window : .area
            selection = nil
            dragStart = nil
            redraw()
        default: break
        }
    }
}

private final class SelectionWindow: NSWindow {
    let screenRef: NSScreen
    let selectionView: SelectionView

    init(screen: NSScreen, controller: SelectionController, frozenImage: CGImage?) {
        screenRef = screen
        selectionView = SelectionView(controller: controller, screen: screen)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        if let frozenImage {
            // The frozen snapshot sits in a layer under the selection drawing.
            let container = FrozenBackdropView(image: frozenImage, frame: selectionView.frame)
            selectionView.autoresizingMask = [.width, .height]
            container.addSubview(selectionView)
            contentView = container
        } else {
            contentView = selectionView
        }
        initialFirstResponder = selectionView
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}

/// Shows the frozen snapshot. Uses updateLayer so a redisplay re-applies the image
/// instead of replacing it with an empty backing store.
private final class FrozenBackdropView: NSView {
    private let image: CGImage

    init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.contents = image
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = image }
}

private final class SelectionView: NSView {
    private unowned let controller: SelectionController
    private let screen: NSScreen

    init(controller: SelectionController, screen: NSScreen) {
        self.controller = controller
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { controller.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller.mouseUp() }
    override func mouseMoved(with event: NSEvent) { controller.mouseMoved() }
    override func keyDown(with event: NSEvent) { controller.keyDown(event) }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.28)
        switch controller.mode {
        case .area:
            if let sel = controller.selection, screen.frame.intersects(sel) {
                let r = local(sel)
                let path = NSBezierPath(rect: bounds)
                path.appendRect(r)
                path.windingRule = .evenOdd
                dim.setFill()
                path.fill()
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
                border.lineWidth = 1
                border.stroke()
                drawLabel("\(Int(sel.width)) × \(Int(sel.height))", near: CGPoint(x: r.maxX, y: r.minY))
            } else if controller.selection == nil {
                NSColor.black.withAlphaComponent(0.12).setFill()
                bounds.fill(using: .sourceOver)
                if screen.frame.contains(controller.mouse) { drawCrosshair(at: local(controller.mouse)) }
            } else {
                dim.setFill()
                bounds.fill(using: .sourceOver)
            }
        case .window:
            NSColor.black.withAlphaComponent(0.12).setFill()
            bounds.fill(using: .sourceOver)
            if let w = controller.hoverWindow, screen.frame.intersects(w.frame) {
                let r = local(w.frame)
                NSColor.systemBlue.withAlphaComponent(0.28).setFill()
                r.fill(using: .sourceOver)
                NSColor.systemBlue.setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                border.lineWidth = 2
                border.stroke()
                drawLabel("\(w.owner)  \(Int(w.frame.width)) × \(Int(w.frame.height))", near: CGPoint(x: r.midX, y: r.midY))
            }
            if screen.frame.contains(controller.mouse) {
                drawLabel("Click a window · Space for area · Esc to cancel",
                          near: CGPoint(x: bounds.midX, y: bounds.maxY - 60))
            }
        }
    }

    private func drawCrosshair(at p: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y + 0.5)); path.line(to: CGPoint(x: bounds.maxX, y: p.y + 0.5))
        path.move(to: CGPoint(x: p.x + 0.5, y: 0)); path.line(to: CGPoint(x: p.x + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        let global = controller.mouse
        drawLabel("\(Int(global.x - screen.frame.minX)), \(Int(screen.frame.maxY - global.y))",
                  near: CGPoint(x: p.x + 14, y: p.y - 14))
    }

    private func drawLabel(_ text: String, near p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var r = CGRect(x: p.x - size.width - 14, y: p.y - size.height - 12, width: size.width + 12, height: size.height + 6)
        if p.x + 14 + r.width < bounds.maxX, r.minX < 0 { r.origin.x = p.x + 6 }
        r.origin.x = min(max(4, r.origin.x), bounds.maxX - r.width - 4)
        r.origin.y = min(max(4, r.origin.y), bounds.maxY - r.height - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
    }
}
