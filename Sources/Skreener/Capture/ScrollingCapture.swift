import AppKit

/// Scrolling capture: after an area is selected, press Start and scroll (or use Auto-Scroll).
/// Frames are captured continuously and stitched into one tall (or wide) screenshot, with a
/// live preview beside the area.
@MainActor
final class ScrollingCaptureController {
    private static var active: ScrollingCaptureController?

    static func begin(rect: CGRect, screen: NSScreen) {
        active?.cancel()
        let c = ScrollingCaptureController(rect: rect, screen: screen)
        active = c
        c.showReady()
    }

    private enum Phase { case ready, capturing, autoScrolling, done }

    private let rect: CGRect
    private let screen: NSScreen
    private var phase = Phase.ready
    /// Until the first movement both directions are tried; the first to match locks the axis.
    private var candidates: [ScrollStitcher] = []
    private var stitcher: ScrollStitcher?
    private let border: RecordingBorder
    private let controls: ScrollControlsPanel
    private let preview: ScrollPreviewPanel
    private var pauseHint: NSPanel?
    private var timer: Timer?
    private var busy = false
    private var keyMonitors: [Any] = []
    private var autoTask: Task<Void, Never>?

    private init(rect: CGRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
        border = RecordingBorder(rect: rect, color: .controlAccentColor)
        controls = ScrollControlsPanel(around: rect, screen: screen)
        preview = ScrollPreviewPanel(beside: rect, screen: screen)
        controls.onStart = { [weak self] in self?.start() }
        controls.onDone = { [weak self] in self?.finish() }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.onAutoScroll = { [weak self] axis in self?.toggleAutoScroll(axis) }
        let esc: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancel() } }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { keyMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { esc($0); return $0 }) { keyMonitors.append(m) }
    }

    private var ignoreEdge: Int { Int(16 * screen.backingScaleFactor) }

    private func showReady() {
        controls.show(phase: .ready)
        preview.window.orderFrontRegardless()
    }

    // MARK: Capturing

    private func start() {
        guard phase == .ready else { return }
        phase = .capturing
        candidates = [ScrollStitcher(axis: .vertical, ignoreEdge: ignoreEdge),
                      ScrollStitcher(axis: .horizontal, ignoreEdge: ignoreEdge)]
        controls.show(phase: .capturing)
        controls.setStatus("Scroll slowly… or use Auto-Scroll")
        Task { await captureAndCompare() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .capturing else { return }
                Task { await self.captureAndCompare() }
            }
        }
    }

    @discardableResult
    private func captureAndCompare() async -> ScrollStitcher.Outcome? {
        guard !busy, phase == .capturing || phase == .autoScrolling else { return nil }
        busy = true
        defer { busy = false }
        guard let (image, _) = try? await ScreenCapturer.capture(rect: rect, on: screen),
              phase == .capturing || phase == .autoScrolling else { return nil }

        if let stitcher {
            let outcome = stitcher.add(image)
            handle(outcome, from: stitcher)
            return outcome
        }
        // Direction detection: feed both until one sees real movement.
        var result: ScrollStitcher.Outcome = .noMovement
        for candidate in candidates {
            let outcome = candidate.add(image)
            if case .appended = outcome {
                stitcher = candidate
                candidates = []
                preview.axis = candidate.axis
                handle(outcome, from: candidate)
                return outcome
            }
            if outcome == .started { preview.update(with: candidate) }
            if outcome == .tooFast || outcome == .backwards { result = outcome }
        }
        handle(result, from: nil)
        return result
    }

    private func handle(_ outcome: ScrollStitcher.Outcome, from stitcher: ScrollStitcher?) {
        switch outcome {
        case .appended, .started:
            preview.update(with: stitcher)
            if let stitcher {
                let along = stitcher.length
                let across = stitcher.axis == .vertical ? Int(rect.width * screen.backingScaleFactor) : Int(rect.height * screen.backingScaleFactor)
                let (w, h) = stitcher.axis == .vertical ? (across, along) : (along, across)
                controls.setStatus("\(w) × \(h) px")
            }
        case .tooFast:
            controls.flash("Please slow down…")
        case .backwards:
            controls.flash("Scroll in one direction only")
        case .tooLarge:
            controls.flash("Screenshot is very large")
            finish()
        case .noMovement:
            break
        }
    }

    // MARK: Auto-Scroll

    private func toggleAutoScroll(_ axis: ScrollAxis) {
        if phase == .autoScrolling {
            stopAutoScroll()
            return
        }
        guard phase == .capturing else { return }
        guard KeystrokeOverlay.hasPermission else {
            KeystrokeOverlay.requestPermission()
            let alert = NSAlert()
            alert.messageText = "Auto-Scroll needs accessibility permissions"
            alert.informativeText = "Allow Skreener in System Settings › Privacy & Security › Accessibility, then try Auto-Scroll again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if let stitcher, stitcher.axis != axis {
            controls.flash("You can't switch directions during a capture")
            return
        }
        if stitcher == nil {
            // Auto-Scroll decides the direction.
            stitcher = candidates.first { $0.axis == axis }
            candidates = []
            preview.axis = axis
        }
        phase = .autoScrolling
        controls.show(phase: .autoScrolling)
        autoTask = Task { await autoScrollLoop(axis) }
    }

    private func stopAutoScroll() {
        autoTask?.cancel()
        autoTask = nil
        hidePauseHint()
        if phase == .autoScrolling {
            phase = .capturing
            controls.show(phase: .capturing)
        }
    }

    private func autoScrollLoop(_ axis: ScrollAxis) async {
        let span = axis == .vertical ? rect.height : rect.width
        var step = max(40, span * 0.6)
        var direction: CGFloat = 1
        var stillCount = 0
        while !Task.isCancelled, phase == .autoScrolling {
            // Like CleanShot, scrolling only happens while the cursor is over the area.
            guard rect.contains(NSEvent.mouseLocation) else {
                showPauseHint()
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            hidePauseHint()
            postScroll(axis: axis, amount: step * direction)
            await waitUntilSettled()
            guard !Task.isCancelled, phase == .autoScrolling else { break }
            while busy { try? await Task.sleep(nanoseconds: 20_000_000) }
            switch await captureAndCompare() {
            case .noMovement?:
                stillCount += 1
                // Nothing moves any more: the end of the content was reached.
                if stillCount >= 2 { return finish() }
            case .tooFast?:
                // Went past the overlap: go back and continue with smaller steps.
                postScroll(axis: axis, amount: -step * direction)
                step = max(30, step / 2)
                await waitUntilSettled()
            case .backwards?:
                // The app reverses synthetic scroll direction; flip ours.
                direction = -direction
                stillCount = 0
            default:
                stillCount = 0
            }
        }
    }

    private func postScroll(axis: ScrollAxis, amount: CGFloat) {
        // Pixel-unit wheel events at the cursor; negative deltas move content toward its end.
        var remaining = Int(amount.rounded())
        let location = CGEvent(source: nil)?.location
        while remaining != 0 {
            let chunk = remaining > 0 ? min(remaining, 60) : max(remaining, -60)
            remaining -= chunk
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: axis == .vertical ? Int32(-chunk) : 0,
                                      wheel2: axis == .horizontal ? Int32(-chunk) : 0, wheel3: 0) else { return }
            if let location { event.location = location }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Waits for smooth-scroll animations to finish: two quick captures in a row look the same.
    private func waitUntilSettled() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        var previous: CGImage?
        for _ in 0..<5 {
            guard let (img, _) = try? await ScreenCapturer.capture(rect: rect, on: screen) else { return }
            if let previous, ImageDiff.changedFraction(previous, img) < 0.0005 { return }
            previous = img
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
    }

    private func showPauseHint() {
        guard pauseHint == nil else { return }
        let label = NSTextField(labelWithString: "Move cursor here to start scrolling")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        let size = CGSize(width: label.fittingSize.width + 32, height: 40)
        let panel = NSPanel(contentRect: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        bg.layer?.cornerRadius = 10
        label.frame = CGRect(x: 16, y: (size.height - label.fittingSize.height) / 2, width: size.width - 32, height: label.fittingSize.height)
        label.alignment = .center
        bg.addSubview(label)
        panel.contentView = bg
        panel.orderFrontRegardless()
        pauseHint = panel
    }

    private func hidePauseHint() {
        pauseHint?.orderOut(nil)
        pauseHint = nil
    }

    // MARK: Finish

    private func finish() {
        guard phase != .done else { return }
        let source = stitcher ?? candidates.first
        tearDown()
        guard let image = source?.result() else { return }
        Coordinator.shared.didCapture(image, pixelScale: screen.backingScaleFactor)
    }

    private func cancel() {
        guard phase != .done else { return }
        tearDown()
    }

    private func tearDown() {
        phase = .done
        timer?.invalidate()
        autoTask?.cancel()
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors.removeAll()
        hidePauseHint()
        border.close()
        controls.window.orderOut(nil)
        preview.window.orderOut(nil)
        if Self.active === self { Self.active = nil }
    }
}

// MARK: - Controls

@MainActor
final class ScrollControlsPanel {
    enum Phase { case ready, capturing, autoScrolling }

    let window: NSPanel
    var onStart: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScroll: ((ScrollAxis) -> Void)?

    private let stack = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let alertLabel = NSTextField(labelWithString: "")
    private let rect: CGRect
    private let screen: NSScreen
    private var flashWork: DispatchWorkItem?

    init(around rect: CGRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)

        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        alertLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        alertLabel.textColor = .systemYellow
        alertLabel.isHidden = true

        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
    }

    func show(phase: Phase) {
        let cancel = button("Cancel", nil) { [weak self] in self?.onCancel?() }
        var views: [NSView] = [cancel]
        switch phase {
        case .ready:
            let hint = NSTextField(labelWithString: "Press Start, then scroll slowly")
            hint.textColor = .secondaryLabelColor
            views += [hint, button("Start", "play.fill", prominent: true) { [weak self] in self?.onStart?() }]
        case .capturing:
            views += [status, alertLabel,
                      button("Auto-Scroll", "arrow.down") { [weak self] in self?.onAutoScroll?(.vertical) },
                      button("Auto-Scroll", "arrow.right") { [weak self] in self?.onAutoScroll?(.horizontal) },
                      button("Done", "checkmark", prominent: true) { [weak self] in self?.onDone?() }]
        case .autoScrolling:
            views += [status, alertLabel,
                      button("Stop Auto-Scroll", "pause.fill") { [weak self] in self?.onAutoScroll?(.vertical) },
                      button("Done", "checkmark", prominent: true) { [weak self] in self?.onDone?() }]
        }
        stack.setViews(views, in: .leading)
        layout()
        window.orderFrontRegardless()
    }

    func setStatus(_ text: String) {
        status.stringValue = text
        layout()
    }

    func flash(_ message: String) {
        alertLabel.stringValue = message
        alertLabel.isHidden = false
        layout()
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.alertLabel.isHidden = true
            self?.layout()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func layout() {
        let size = window.contentView?.fittingSize ?? CGSize(width: 400, height: 44)
        let vf = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < vf.minY + 4 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > vf.maxY - 4 { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func button(_ title: String, _ symbol: String?, prominent: Bool = false,
                        _ handler: @escaping () -> Void) -> NSButton {
        let b = ActionButton(title: title, handler: handler)
        b.bezelStyle = .rounded
        if let symbol {
            b.image = NSImage.symbol(symbol, size: 11, weight: .semibold)
            b.imagePosition = .imageLeading
        }
        if prominent { b.bezelColor = .controlAccentColor }
        return b
    }
}

private final class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler() }
}

// MARK: - Live preview

@MainActor
final class ScrollPreviewPanel {
    let window: NSPanel
    private let view = PreviewView()
    var axis: ScrollAxis = .vertical {
        didSet { view.axis = axis }
    }

    init(beside rect: CGRect, screen: NSScreen) {
        let vf = screen.visibleFrame
        let width: CGFloat = 170
        let height = min(max(rect.height, 260), vf.height - 40)
        let x = vf.maxX - rect.maxX >= width + 24 ? rect.maxX + 12 : max(vf.minX + 8, rect.minX - width - 12)
        let y = min(max(rect.maxY - height, vf.minY + 8), vf.maxY - height - 8)
        window = NSPanel(contentRect: CGRect(x: x, y: y, width: width, height: height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView = view
    }

    /// Downscales only pieces it hasn't seen yet, so updates stay cheap for very long captures.
    func update(with stitcher: ScrollStitcher?) {
        guard let stitcher else { return }
        let pieces = stitcher.committedPieces
        if pieces.count < view.thumbs.count { view.thumbs.removeAll() }
        while view.thumbs.count < pieces.count { view.thumbs.append(thumbnail(pieces[view.thumbs.count])) }
        view.tail = stitcher.tail.map(thumbnail)
        view.needsDisplay = true
    }

    private func thumbnail(_ image: CGImage) -> CGImage {
        // 300 px across the axis covers the 150 pt preview at 2x.
        let across = CGFloat(axis == .vertical ? image.width : image.height)
        let scale = min(1, 300 / across)
        guard scale < 1 else { return image }
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

final class PreviewView: NSView {
    var thumbs: [CGImage] = []
    var tail: CGImage?
    var axis: ScrollAxis = .vertical

    private var parts: [CGImage] { thumbs + (tail.map { [$0] } ?? []) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let inner = bounds.insetBy(dx: 8, dy: 8)
        let parts = self.parts
        guard let first = parts.first, let ctx = NSGraphicsContext.current?.cgContext else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ("Preview" as NSString).draw(at: CGPoint(x: inner.midX - 22, y: inner.midY), withAttributes: attrs)
            return
        }
        // Fit across the axis; when the stitch is longer than the panel, show its newest end.
        ctx.saveGState()
        ctx.clip(to: inner)
        ctx.interpolationQuality = .medium
        // Pieces must butt together exactly; antialiased fractional edges show as seams.
        ctx.setShouldAntialias(false)
        if axis == .vertical {
            let s = inner.width / CGFloat(first.width)
            let total = parts.reduce(0) { $0 + CGFloat($1.height) * s }
            var top = total > inner.height ? inner.minY + total : inner.maxY
            for part in parts {
                let h = CGFloat(part.height) * s
                ctx.draw(part, in: CGRect(x: inner.minX, y: top - h, width: inner.width, height: h + 0.5))
                top -= h
            }
        } else {
            let s = min(inner.height, 120) / CGFloat(first.height)
            let total = parts.reduce(0) { $0 + CGFloat($1.width) * s }
            var x = total > inner.width ? inner.maxX - total : inner.minX
            let h = CGFloat(first.height) * s
            for part in parts {
                let w = CGFloat(part.width) * s
                ctx.draw(part, in: CGRect(x: x, y: inner.maxY - h, width: w + 0.5, height: h))
                x += w
            }
        }
        ctx.restoreGState()
    }
}
