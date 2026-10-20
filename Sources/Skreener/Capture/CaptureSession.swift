import AppKit

enum CaptureIntent { case screenshot, recording }
enum CaptureTarget {
    case fullscreen, window, area, scrolling

    /// Area and scrolling captures both use the adjustable rectangle selection.
    var usesAreaSelection: Bool { self == .area || self == .scrolling }
}

/// What the user confirmed in a capture session.
struct CaptureRequest {
    let intent: CaptureIntent
    let target: CaptureTarget
    let screen: NSScreen
    /// Global AppKit rect: the area, the window frame, or the whole screen.
    let rect: CGRect
    let window: PickableWindow?
}

/// The ⌘⇧5-style capture experience: a full-screen overlay plus a floating toolbar for
/// choosing screenshot or recording, fullscreen / window / area, options and size presets.
/// Area selections stay adjustable (handles, move, arrow keys) until confirmed.
@MainActor
final class CaptureSession {
    private static var active: CaptureSession?

    private(set) var intent: CaptureIntent
    private(set) var target: CaptureTarget
    private let frozen: FrozenScreens?
    private let completion: (CaptureRequest?) -> Void

    private var windows: [SessionWindow] = []
    private var toolbar: CaptureToolbar?
    private var monitor: Any?
    private let pickable: [PickableWindow]

    private(set) var mouse: CGPoint = NSEvent.mouseLocation
    private(set) var selection: CGRect?
    private(set) var selectionScreen: NSScreen?
    private(set) var hoverWindow: PickableWindow?
    /// Width / height ratio to keep while resizing, or nil for free-form.
    var ratio: CGFloat? { didSet { if let r = ratio, let sel = selection { setSize(width: sel.width, height: sel.width / r) } } }

    private enum Drag {
        case create(start: CGPoint, screen: NSScreen)
        case move(grab: CGPoint, original: CGRect)
        case resize(handle: Handle, original: CGRect)
    }
    private var drag: Drag?

    enum Handle: CaseIterable { case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left }

    static var isActive: Bool { active != nil }

    static func begin(intent: CaptureIntent, target: CaptureTarget, frozen: FrozenScreens?,
                      completion: @escaping (CaptureRequest?) -> Void) {
        active?.finish(nil)
        let session = CaptureSession(intent: intent, target: target, frozen: frozen, completion: completion)
        active = session
        session.show()
    }

    init(intent: CaptureIntent, target: CaptureTarget, frozen: FrozenScreens?,
                 completion: @escaping (CaptureRequest?) -> Void) {
        self.intent = intent
        self.target = target
        self.frozen = frozen
        self.completion = completion
        pickable = ScreenCapturer.onScreenWindows()
        if Settings.rememberSelection, let last = Settings.lastSelection,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(last) }) {
            selection = last
            selectionScreen = screen
        }
    }

    // MARK: Lifecycle

    private func show() {
        for screen in NSScreen.screens {
            let w = SessionWindow(screen: screen, session: self, frozenImage: frozen?.image(for: screen))
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screenRef == NSScreen.withMouse } ?? windows.first)?.makeKey()
        let bar = CaptureToolbar(session: self, screen: NSScreen.withMouse)
        bar.orderFrontRegardless()
        toolbar = bar
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            if !(e.window is CaptureToolbar) { self?.mouseMoved() }
            return e
        }
        stateChanged()
        mouseMoved()
    }

    private func finish(_ request: CaptureRequest?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        if Self.active === self { Self.active = nil }
        // Let the window server drop the overlay before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [completion] in completion(request) }
    }

    func cancel() { finish(nil) }

    /// Gives keyboard focus back to the overlay (Esc, Return, arrows) after toolbar edits.
    func focusOverlay() {
        (windows.first { $0.screenRef == (selectionScreen ?? NSScreen.withMouse) } ?? windows.first)?.makeKey()
    }

    var canConfirm: Bool {
        switch target {
        case .area, .scrolling: return (selection?.width ?? 0) >= 4 && (selection?.height ?? 0) >= 4
        case .fullscreen: return true
        case .window: return false // a window is confirmed by clicking it
        }
    }

    func confirm() {
        switch target {
        case .area, .scrolling:
            guard canConfirm, let sel = selection, let screen = selectionScreen else { return NSSound.beep() }
            if Settings.rememberSelection { Settings.lastSelection = sel }
            finish(CaptureRequest(intent: intent, target: target, screen: screen, rect: sel, window: nil))
        case .fullscreen:
            let screen = NSScreen.withMouse
            finish(CaptureRequest(intent: intent, target: .fullscreen, screen: screen, rect: screen.frame, window: nil))
        case .window:
            guard let w = hoverWindow else { return NSSound.beep() }
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) } ?? NSScreen.withMouse
            finish(CaptureRequest(intent: intent, target: .window, screen: screen, rect: w.frame, window: w))
        }
    }

    func set(intent: CaptureIntent, target: CaptureTarget) {
        self.intent = intent
        self.target = target
        drag = nil
        stateChanged()
    }

    /// Re-applies anything that depends on mode or options (frozen backdrop, toolbar, drawing).
    func stateChanged() {
        // Scrolling capture needs the live screen.
        let showFrozen = intent == .screenshot && target != .scrolling
        windows.forEach { $0.setBackdropVisible(showFrozen) }
        toolbar?.refresh()
        updateCursor()
        redraw()
    }

    /// Sets the selection size from the toolbar fields, keeping its center.
    func setSize(width: CGFloat, height: CGFloat) {
        let screen = selectionScreen ?? NSScreen.withMouse
        let f = screen.frame
        let w = min(max(8, width.rounded()), f.width)
        let h = min(max(8, height.rounded()), f.height)
        let center = selection.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: f.midX, y: f.midY)
        var r = CGRect(x: (center.x - w / 2).rounded(), y: (center.y - h / 2).rounded(), width: w, height: h)
        r.origin.x = min(max(r.minX, f.minX), f.maxX - w)
        r.origin.y = min(max(r.minY, f.minY), f.maxY - h)
        selection = r
        selectionScreen = screen
        if !target.usesAreaSelection { target = .area }
        stateChanged()
    }

    private func redraw() { windows.forEach { $0.sessionView.needsDisplay = true } }

    // MARK: Hit testing

    static let handleRadius: CGFloat = 6

    func handlePoints(for r: CGRect) -> [(Handle, CGPoint)] {
        [(.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
         (.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    private func handle(at p: CGPoint) -> Handle? {
        guard target.usesAreaSelection, let sel = selection else { return nil }
        return handlePoints(for: sel).first { hypot($0.1.x - p.x, $0.1.y - p.y) <= Self.handleRadius + 5 }?.0
    }

    private func updateCursor() {
        switch target {
        case .window, .fullscreen:
            Self.cameraCursor.set()
        case .area, .scrolling:
            if let h = handle(at: mouse) {
                switch h {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                default: NSCursor.crosshair.set()
                }
            } else if let sel = selection, sel.contains(mouse) {
                (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    static let cameraCursor: NSCursor = {
        let size = NSSize(width: 26, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 2
            shadow.set()
            if let symbol = NSImage.symbol("camera.fill", size: 16, weight: .semibold) {
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }()

    // MARK: Events (global AppKit coordinates)

    func mouseMoved() {
        mouse = NSEvent.mouseLocation
        hoverWindow = pickable.first { $0.frame.contains(mouse) }
        updateCursor()
        redraw()
    }

    func mouseDown(clickCount: Int) {
        mouse = NSEvent.mouseLocation
        switch target {
        case .window:
            if hoverWindow != nil { confirm() }
        case .fullscreen:
            confirm()
        case .area, .scrolling:
            if let h = handle(at: mouse), let sel = selection {
                drag = .resize(handle: h, original: sel)
            } else if let sel = selection, sel.contains(mouse) {
                if clickCount == 2 { return confirm() }
                drag = .move(grab: mouse, original: sel)
            } else {
                drag = .create(start: mouse, screen: NSScreen.withMouse)
            }
            updateCursor()
        }
    }

    func mouseDragged(shift: Bool) {
        mouse = NSEvent.mouseLocation
        guard target.usesAreaSelection, let drag else { return }
        switch drag {
        case .create(let start, let screen):
            var dx = mouse.x - start.x, dy = mouse.y - start.y
            let lock = ratio ?? (shift ? 1 : nil)
            if let lock {
                let w = max(abs(dx), abs(dy) * lock)
                dx = dx < 0 ? -w : w
                dy = (dy < 0 ? -1 : 1) * w / lock
            }
            let r = CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
            selection = r.integral.intersection(screen.frame)
            selectionScreen = screen
        case .move(let grab, let original):
            guard let screen = selectionScreen else { return }
            var r = original.offsetBy(dx: (mouse.x - grab.x).rounded(), dy: (mouse.y - grab.y).rounded())
            r.origin.x = min(max(r.minX, screen.frame.minX), screen.frame.maxX - r.width)
            r.origin.y = min(max(r.minY, screen.frame.minY), screen.frame.maxY - r.height)
            selection = r
        case .resize(let handle, let original):
            guard let screen = selectionScreen else { return }
            selection = resized(original, handle: handle, to: mouse, keep: ratio ?? (shift ? original.width / max(original.height, 1) : nil))
                .integral.intersection(screen.frame)
        }
        toolbar?.refresh()
        redraw()
    }

    func mouseUp() {
        if case .create = drag, let sel = selection, sel.width < 4 || sel.height < 4 { selection = nil }
        drag = nil
        toolbar?.refresh()
        updateCursor()
        redraw()
    }

    private func resized(_ r: CGRect, handle: Handle, to p: CGPoint, keep ratio: CGFloat?) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .left: minX = min(p.x, maxX - 8)
        case .right: maxX = max(p.x, minX + 8)
        case .bottom: minY = min(p.y, maxY - 8)
        case .top: maxY = max(p.y, minY + 8)
        case .bottomLeft: minX = min(p.x, maxX - 8); minY = min(p.y, maxY - 8)
        case .bottomRight: maxX = max(p.x, minX + 8); minY = min(p.y, maxY - 8)
        case .topLeft: minX = min(p.x, maxX - 8); maxY = max(p.y, minY + 8)
        case .topRight: maxX = max(p.x, minX + 8); maxY = max(p.y, minY + 8)
        }
        guard let ratio else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        var w = maxX - minX, h = maxY - minY
        switch handle {
        case .left, .right:
            h = w / ratio
            return CGRect(x: minX, y: r.midY - h / 2, width: w, height: h)
        case .top, .bottom:
            w = h * ratio
            return CGRect(x: r.midX - w / 2, y: minY, width: w, height: h)
        default:
            h = w / ratio
            // Anchor the corner opposite the dragged one.
            let anchoredBottom = handle == .topLeft || handle == .topRight
            return CGRect(x: minX, y: anchoredBottom ? r.minY : r.maxY - h, width: w, height: h)
        }
    }

    func keyDown(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let step: CGFloat = shift ? 10 : 1
        switch Int(event.keyCode) {
        case 53: cancel() // Escape
        case 36, 76: confirm() // Return
        case 49: // Space cycles fullscreen → window → area
            let next: CaptureTarget = target == .fullscreen ? .window : target == .window ? .area : .fullscreen
            if next == .fullscreen, target == .area, intent == .screenshot { return set(intent: intent, target: .scrolling) }
            set(intent: intent, target: next)
        case 123, 124, 125, 126: // arrows: move, ⌥ resizes
            guard target.usesAreaSelection, var r = selection, let screen = selectionScreen else { return }
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            if option {
                r.size.width = max(8, r.width + dx)
                r.size.height = max(8, r.height + dy)
                r.origin.y -= dy
            } else {
                r = r.offsetBy(dx: dx, dy: dy)
            }
            selection = r.intersection(screen.frame)
            toolbar?.refresh()
            redraw()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": set(intent: .recording, target: target)
            case "s": set(intent: .screenshot, target: target)
            default: break
            }
        }
    }
}

// MARK: - Overlay windows

private final class SessionWindow: NSWindow {
    let screenRef: NSScreen
    let sessionView: SessionView
    private var backdrop: NSView?

    init(screen: NSScreen, session: CaptureSession, frozenImage: CGImage?) {
        screenRef = screen
        sessionView = SessionView(session: session, screen: screen)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        if let frozenImage {
            let b = FrozenImageView(image: frozenImage, frame: container.bounds)
            b.autoresizingMask = [.width, .height]
            container.addSubview(b)
            backdrop = b
        }
        sessionView.frame = container.bounds
        sessionView.autoresizingMask = [.width, .height]
        container.addSubview(sessionView)
        contentView = container
        initialFirstResponder = sessionView
        makeFirstResponder(sessionView)
    }

    func setBackdropVisible(_ visible: Bool) { backdrop?.isHidden = !visible }

    override var canBecomeKey: Bool { true }
}

/// Frozen snapshot behind the overlay; re-applies its image on every redisplay.
final class FrozenImageView: NSView {
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

final class SessionView: NSView {
    private unowned let session: CaptureSession
    private let screen: NSScreen

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { session.mouseDown(clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { session.mouseDragged(shift: event.modifierFlags.contains(.shift)) }
    override func mouseUp(with event: NSEvent) { session.mouseUp() }
    override func mouseMoved(with event: NSEvent) { session.mouseMoved() }
    override func keyDown(with event: NSEvent) { session.keyDown(event) }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        let recording = session.intent == .recording
        let dim = NSColor.black.withAlphaComponent(0.35)
        switch session.target {
        case .area, .scrolling:
            if let sel = session.selection, screen.frame.intersects(sel) {
                let r = local(sel)
                let path = NSBezierPath(rect: bounds)
                path.appendRect(r)
                path.windingRule = .evenOdd
                dim.setFill()
                path.fill()
                drawSelection(r, global: sel, recording: recording)
            } else {
                NSColor.black.withAlphaComponent(session.selection == nil ? 0.18 : 0.35).setFill()
                bounds.fill(using: .sourceOver)
                if session.selection == nil, screen.frame.contains(session.mouse) {
                    drawCrosshair(at: local(session.mouse))
                    let prompt = recording ? "Drag to record a part of the screen"
                        : session.target == .scrolling ? "Drag to capture the scrolling part of the screen"
                        : "Drag to select an area"
                    OverlayLabel.draw(prompt,
                                      centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 70), in: self, large: true)
                }
            }
        case .window:
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill(using: .sourceOver)
            if let w = session.hoverWindow, screen.frame.intersects(w.frame) {
                let r = local(w.frame)
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
                r.fill(using: .sourceOver)
                NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
                border.lineWidth = 3
                border.stroke()
                let title = w.title.isEmpty ? w.owner : "\(w.owner) — \(w.title)"
                OverlayLabel.draw(title, detail: "\(Int(w.frame.width)) × \(Int(w.frame.height))", icon: w.appIcon,
                                  centeredAt: CGPoint(x: r.midX, y: r.midY), in: self, large: true)
            } else if screen.frame.contains(session.mouse) {
                OverlayLabel.draw(recording ? "Click a window to record it" : "Click a window to capture it",
                                  centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 70), in: self, large: true)
            }
        case .fullscreen:
            let hovered = screen.frame.contains(session.mouse)
            (hovered ? NSColor.systemBlue.withAlphaComponent(0.16) : dim).setFill()
            bounds.fill(using: .sourceOver)
            if hovered {
                OverlayLabel.draw(recording ? "Click to record this screen" : "Click to capture this screen",
                                  detail: "\(Int(screen.frame.width)) × \(Int(screen.frame.height))", icon: nil,
                                  centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), in: self, large: true)
            }
        }
    }

    private func drawSelection(_ r: CGRect, global: CGRect, recording: Bool) {
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.black.withAlphaComponent(0.4).setStroke()
        border.stroke()
        let dashed = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        dashed.lineWidth = 1
        dashed.setLineDash([6, 4], count: 2, phase: 0)
        (recording ? NSColor.systemRed : NSColor.white).setStroke()
        dashed.stroke()

        // Rule-of-thirds guides while adjusting larger areas.
        if r.width > 160, r.height > 120 {
            let guides = NSBezierPath()
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                guides.move(to: CGPoint(x: x, y: r.minY)); guides.line(to: CGPoint(x: x, y: r.maxY))
                guides.move(to: CGPoint(x: r.minX, y: y)); guides.line(to: CGPoint(x: r.maxX, y: y))
            }
            guides.lineWidth = 0.5
            NSColor.white.withAlphaComponent(0.25).setStroke()
            guides.stroke()
        }

        let radius = CaptureSession.handleRadius
        for (_, p) in session.handlePoints(for: r) {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3
            shadow.set()
            NSColor.white.setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
        }

        let size = "\(Int(global.width)) × \(Int(global.height))"
        let below = CGPoint(x: r.midX, y: r.minY - 22)
        let inside = CGPoint(x: r.midX, y: r.minY + 22)
        OverlayLabel.draw(size, centeredAt: below.y > 30 ? below : inside, in: self, large: false)
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
    }
}

/// Rounded dark label used by the capture overlays.
enum OverlayLabel {
    static func draw(_ text: String, detail: String? = nil, icon: NSImage? = nil, centeredAt c: CGPoint,
                     in view: NSView, large: Bool) {
        let font = NSFont.systemFont(ofSize: large ? 14 : 11, weight: large ? .semibold : .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let maxWidth = min(520, view.bounds.width - 40)
        var textSize = (text as NSString).size(withAttributes: attrs)
        textSize.width = min(textSize.width, maxWidth)
        let detailSize = detail.map { ($0 as NSString).size(withAttributes: detailAttrs) } ?? .zero
        let iconSide: CGFloat = icon == nil ? 0 : 36
        let padX: CGFloat = large ? 14 : 7, padY: CGFloat = large ? 9 : 4
        let textBlockW = max(textSize.width, detailSize.width)
        let textBlockH = textSize.height + (detail == nil ? 0 : detailSize.height + 2)
        let w = padX * 2 + textBlockW + (icon == nil ? 0 : iconSide + 10)
        let h = padY * 2 + max(textBlockH, iconSide)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        r.origin.x = min(max(8, r.minX), view.bounds.maxX - w - 8)
        r.origin.y = min(max(8, r.minY), view.bounds.maxY - h - 8)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: large ? 10 : 5, yRadius: large ? 10 : 5).fill()
        var x = r.minX + padX
        if let icon {
            icon.draw(in: CGRect(x: x, y: r.midY - iconSide / 2, width: iconSide, height: iconSide))
            x += iconSide + 10
        }
        let top = r.midY + textBlockH / 2
        (text as NSString).draw(with: CGRect(x: x, y: top - textSize.height, width: textSize.width, height: textSize.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        if let detail {
            (detail as NSString).draw(at: CGPoint(x: x, y: top - textSize.height - 2 - detailSize.height), withAttributes: detailAttrs)
        }
    }
}
