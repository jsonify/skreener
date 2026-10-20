import AppKit
@preconcurrency import AVFoundation

// MARK: - Control bar (excluded from the recording)

/// Floating stop / pause / restart / discard controls with an elapsed timer.
@MainActor
final class RecordingControlBar {
    let window: NSPanel
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let pauseButton: HUDButton
    private let dot = NSView()
    private var timer: Timer?

    init(around rect: CGRect, screen: NSScreen, micOn: Bool) {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pauseButton = HUDButton(symbol: "pause.fill", size: 13, tip: "Pause")
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)

        let stop = HUDButton(symbol: "stop.fill", size: 14, tip: "Stop and save (⌘⇧6)")
        stop.contentTintColor = .systemRed
        stop.target = self
        stop.action = #selector(stopClicked)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        let restart = HUDButton(symbol: "arrow.counterclockwise", size: 13, tip: "Restart recording")
        restart.target = self
        restart.action = #selector(restartClicked)
        let discard = HUDButton(symbol: "trash", size: 13, tip: "Discard recording")
        discard.target = self
        discard.action = #selector(discardClicked)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white

        var views: [NSView] = [stop, dot, timeLabel, pauseButton, restart, discard]
        if micOn {
            let mic = NSImageView(image: NSImage.symbol("mic.fill", size: 12) ?? NSImage())
            mic.contentTintColor = .secondaryLabelColor
            mic.toolTip = "Microphone is recording"
            views.insert(mic, at: 3)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        stack.setCustomSpacing(8, after: stop)

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

        // Below the area if there's room, else above it, else inside its bottom edge.
        let size = effect.fittingSize
        let vf = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < vf.minY + 4 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > vf.maxY - 4 { origin.y = rect.minY + 16 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let rec = ScreenRecorder.shared
        let s = Int(rec.elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        let paused = rec.isPaused
        pauseButton.image = NSImage.symbol(paused ? "play.fill" : "pause.fill", size: 13, weight: .semibold)
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        // Blink the dot while recording; hold it dim while paused.
        dot.alphaValue = paused ? 0.35 : (Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.4)
    }

    func close() {
        timer?.invalidate()
        window.orderOut(nil)
    }

    @objc private func stopClicked() { Task { await ScreenRecorder.shared.stop() } }
    @objc private func pauseClicked() { ScreenRecorder.shared.togglePause() }
    @objc private func restartClicked() { Task { await ScreenRecorder.shared.restart() } }
    @objc private func discardClicked() { Task { await ScreenRecorder.shared.discard() } }
}

// MARK: - Recordable overlays (included in the recording)

/// Expanding rings at each mouse click inside the recorded area.
@MainActor
final class ClickHighlighter {
    let window: NSWindow
    private var monitors: [Any] = []

    init(rect: CGRect) {
        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] e in
            let right = e.type == .rightMouseDown
            MainActor.assumeIsolated { self?.ripple(at: NSEvent.mouseLocation, right: right) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { handler($0); return $0 }) {
            monitors.append(m)
        }
    }

    private func ripple(at global: CGPoint, right: Bool) {
        guard window.frame.contains(global), let root = window.contentView?.layer else { return }
        let p = CGPoint(x: global.x - window.frame.minX, y: global.y - window.frame.minY)
        let color = right ? NSColor.systemBlue : NSColor.systemYellow
        let ring = CAShapeLayer()
        let r: CGFloat = 22
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = p
        ring.fillColor = color.withAlphaComponent(0.3).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        root.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ring.removeFromSuperlayer() }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        window.orderOut(nil)
    }
}

/// Shows pressed keys and shortcuts near the bottom of the recorded area.
/// Global key monitoring requires the Accessibility permission.
@MainActor
final class KeystrokeOverlay {
    let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private var monitor: Any?
    private var lastKey = Date.distantPast
    private var hideWork: DispatchWorkItem?
    private let area: CGRect

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    init(rect: CGRect) {
        area = rect
        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let root = NSView(frame: CGRect(origin: .zero, size: rect.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        pill.layer?.cornerRadius = 12
        pill.alphaValue = 0
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        pill.addSubview(label)
        root.addSubview(pill)
        window.contentView = root
        window.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let text = Self.describe(e)
            let isCombo = !e.modifierFlags.intersection([.command, .control, .option]).isEmpty
            MainActor.assumeIsolated { self?.show(text, isCombo: isCombo) }
        }
    }

    private func show(_ text: String, isCombo: Bool) {
        // Plain typing accumulates into a short phrase; shortcuts replace it.
        let typing = !isCombo && text.count == 1 && Date().timeIntervalSince(lastKey) < 1.2 && !label.stringValue.isEmpty
        var display = typing ? label.stringValue + text : text
        if display.count > 28 { display = "…" + display.suffix(27) }
        lastKey = Date()
        label.stringValue = display
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 36, height: label.frame.height + 18)
        pill.frame = CGRect(x: (area.width - size.width) / 2, y: 40, width: size.width, height: size.height)
        label.frame.origin = CGPoint(x: 18, y: 9)
        pill.alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.pill.animator().alphaValue = 0 }
            self?.label.stringValue = ""
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private static func describe(_ e: NSEvent) -> String {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift), !(f.intersection([.command, .control, .option]).isEmpty) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→",
                                         125: "↓", 126: "↑", 76: "⌤", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
        if let sym = special[e.keyCode] { return s + sym }
        let chars = (s.isEmpty ? e.characters : e.charactersIgnoringModifiers) ?? ""
        return s + (s.isEmpty ? chars : chars.uppercased())
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        hideWork?.cancel()
        window.orderOut(nil)
    }
}

/// Draggable webcam bubble shown inside the recorded area.
@MainActor
final class CameraOverlay {
    let window: NSPanel
    private let session = AVCaptureSession()

    init?(rect: CGRect) {
        let devices = MediaDevices.cameras()
        guard let device = devices.first(where: { $0.uniqueID == Settings.cameraID }) ?? devices.first,
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.sessionPreset = .high
        session.addInput(input)

        let side: CGFloat = [130, 190, 270][min(2, max(0, Settings.cameraSize))]
        let rounded = Settings.cameraShape == .rounded
        let size = CGSize(width: rounded ? side * 4 / 3 : side, height: side)
        let origin = CGPoint(x: rect.maxX - size.width - 24, y: rect.minY + 24)
        window = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        view.layer?.cornerRadius = rounded ? 18 : side / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        view.toolTip = "Drag to move the camera"
        window.contentView = view
        window.orderFrontRegardless()
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func close() {
        let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
        window.orderOut(nil)
    }
}
