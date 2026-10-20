import AppKit
@preconcurrency import AVFoundation

/// Floating HUD shown during a capture session, modelled on macOS's ⌘⇧5 bar and
/// CleanShot's recorder controls.
final class CaptureToolbar: NSPanel, NSTextFieldDelegate {
    private unowned let session: CaptureSession
    private var modeButtons: [(CaptureIntent, CaptureTarget, HUDButton)] = []
    private let sizeGroup = NSStackView()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let ratioButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let primaryButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let hostScreen: NSScreen

    private static let ratios: [(String, CGFloat?)] = [("Free", nil), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("3:2", 1.5),
                                                       ("1:1", 1), ("9:16", 9.0 / 16)]
    private static let presets: [(Int, Int)] = [(640, 480), (1280, 720), (1920, 1080), (1080, 1080), (1080, 1350), (1080, 1920)]

    @MainActor
    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        self.hostScreen = screen
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
        position()
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { session.cancel() } }

    // MARK: Layout

    @MainActor
    private func build() {
        let close = HUDButton(symbol: "xmark", size: 12, tip: "Cancel (Esc)")
        close.target = self
        close.action = #selector(cancelSession)

        let screenshotGroup = group([
            mode(.screenshot, .fullscreen, NSImage.symbol("rectangle.inset.filled", size: 17), "Capture Entire Screen"),
            mode(.screenshot, .window, NSImage.symbol("macwindow", size: 17), "Capture Selected Window"),
            mode(.screenshot, .area, NSImage.symbol("rectangle.dashed", size: 17), "Capture Selected Portion"),
        ])
        let recordGroup = group([
            mode(.recording, .fullscreen, Self.recordSymbol("rectangle.inset.filled.badge.record"), "Record Entire Screen"),
            mode(.recording, .window, Self.recordWindowIcon(), "Record Selected Window"),
            mode(.recording, .area, Self.recordSymbol("rectangle.dashed.badge.record"), "Record Selected Portion"),
        ])

        for field in [widthField, heightField] {
            field.formatter = {
                let f = NumberFormatter()
                f.allowsFloats = false
                f.minimum = 8
                f.maximum = 20000
                return f
            }()
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.target = self
            field.action = #selector(sizeFieldCommitted)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        widthField.toolTip = "Width in points"
        heightField.toolTip = "Height in points"
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        ratioButton.bezelStyle = .texturedRounded
        ratioButton.toolTip = "Aspect ratio and size presets"
        buildRatioMenu()
        sizeGroup.setViews([widthField, times, heightField, ratioButton], in: .leading)
        sizeGroup.spacing = 5

        let options = NSButton(title: "Options", target: self, action: #selector(showOptions(_:)))
        options.bezelStyle = .texturedRounded
        options.image = NSImage.symbol("chevron.down", size: 9, weight: .bold)
        options.imagePosition = .imageTrailing

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [close, separator(), screenshotGroup, separator(), recordGroup, separator(),
                                        sizeGroup, options, hintLabel, primaryButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.alignment = .centerY

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: 56),
        ])
        contentView = effect
    }

    private func mode(_ intent: CaptureIntent, _ target: CaptureTarget, _ image: NSImage?, _ tip: String) -> HUDButton {
        let b = HUDButton(image: image, tip: tip)
        b.target = self
        b.action = #selector(modeClicked(_:))
        modeButtons.append((intent, target, b))
        return b
    }

    private func group(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 2
        return s
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return v
    }

    @MainActor
    private func position() {
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? CGSize(width: 600, height: 56)
        let vf = hostScreen.visibleFrame
        setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.minY + 36, width: size.width, height: size.height), display: true)
    }

    // MARK: State

    @MainActor
    func refresh() {
        for (intent, target, button) in modeButtons {
            button.isSelected = intent == session.intent && target == session.target
        }
        let isArea = session.target == .area
        sizeGroup.isHidden = !isArea
        if isArea, !(firstResponder is NSTextView) {
            let sel = session.selection
            widthField.stringValue = sel.map { "\(Int($0.width))" } ?? ""
            heightField.stringValue = sel.map { "\(Int($0.height))" } ?? ""
            widthField.placeholderString = "W"
            heightField.placeholderString = "H"
        }
        let ratioTitle = Self.ratios.first { $0.1 == session.ratio }?.0 ?? "Free"
        ratioButton.item(at: 0)?.title = ratioTitle

        let recording = session.intent == .recording
        primaryButton.attributedTitle = NSAttributedString(string: recording ? "Record" : "Capture", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        primaryButton.image = recording ? NSImage.symbol("record.circle", size: 13) : nil
        primaryButton.imagePosition = .imageLeading
        primaryButton.bezelColor = recording ? .systemRed : .controlAccentColor
        primaryButton.contentTintColor = .white
        let isWindow = session.target == .window
        primaryButton.isHidden = isWindow
        hintLabel.isHidden = !isWindow
        hintLabel.stringValue = "Click a window"
        primaryButton.isEnabled = session.canConfirm
        if isVisible { position() }
    }

    // MARK: Actions

    @objc private func cancelSession() { MainActor.assumeIsolated { session.cancel() } }

    @objc private func primaryClicked() { MainActor.assumeIsolated { session.confirm() } }

    @objc private func modeClicked(_ sender: HUDButton) {
        guard let entry = modeButtons.first(where: { $0.2 === sender }) else { return }
        MainActor.assumeIsolated { session.set(intent: entry.0, target: entry.1) }
    }

    @objc private func sizeFieldCommitted() {
        let w = CGFloat(widthField.integerValue), h = CGFloat(heightField.integerValue)
        guard w >= 8, h >= 8 else { return }
        MainActor.assumeIsolated {
            if let r = session.ratio {
                // Keep the ratio: the field just edited drives the other one.
                if firstResponder === heightField.currentEditor() {
                    session.setSize(width: h * r, height: h)
                } else {
                    session.setSize(width: w, height: w / r)
                }
            } else {
                session.setSize(width: w, height: h)
            }
            session.focusOverlay()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { sizeFieldCommitted() }

    private func buildRatioMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Free", action: nil, keyEquivalent: "") // pull-down title item
        menu.addItem(.sectionHeader(title: "Aspect Ratio"))
        for (i, (title, _)) in Self.ratios.enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(ratioChosen(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Size"))
        for (i, (w, h)) in Self.presets.enumerated() {
            let item = menu.addItem(withTitle: "\(w) × \(h)", action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
        }
        ratioButton.menu = menu
    }

    @objc private func ratioChosen(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { session.ratio = Self.ratios[sender.tag].1; refresh() }
    }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        let (w, h) = Self.presets[sender.tag]
        MainActor.assumeIsolated {
            session.ratio = nil
            session.setSize(width: CGFloat(w), height: CGFloat(h))
        }
    }

    @objc private func showOptions(_ sender: NSButton) {
        MainActor.assumeIsolated {
            let menu = CaptureOptionsMenu.build(for: session.intent) { [weak self] in
                MainActor.assumeIsolated { self?.session.stateChanged() }
            }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }

    // MARK: Icons

    private static func recordSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed, .white])))
    }

    private static func recordWindowIcon() -> NSImage {
        let base = NSImage.symbol("macwindow", size: 17) ?? NSImage()
        let size = NSSize(width: base.size.width + 6, height: base.size.height + 4)
        let image = NSImage(size: size, flipped: false) { _ in
            let tinted = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: 0, y: 4, width: base.size.width, height: base.size.height))
            let dot = CGRect(x: size.width - 10, y: 0, width: 10, height: 10)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        return image
    }
}

/// Square toggle button with a highlighted background when selected.
final class HUDButton: NSButton {
    var isSelected = false { didSet { updateLook() } }

    convenience init(symbol: String, size: CGFloat, tip: String) {
        self.init(image: NSImage.symbol(symbol, size: size, weight: .semibold), tip: tip)
    }

    init(image: NSImage?, tip: String) {
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 42).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateLook() {
        layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.24).cgColor : NSColor.clear.cgColor
        alphaValue = isSelected ? 1 : 0.82
    }
}

/// The Options menu: output, timer, window styling and recording options.
@MainActor
enum CaptureOptionsMenu {
    static func build(for intent: CaptureIntent, changed: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        func toggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) {
            menu.addItem(ClosureMenuItem(title, checked: value) { set(!value); changed() })
        }
        func choice<T: Equatable>(_ title: String, _ options: [(String, T)], current: T, enabled: Bool = true,
                                  _ set: @escaping (T) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (label, value) in options {
                sub.addItem(ClosureMenuItem(label, checked: value == current) { set(value); changed() })
            }
            item.submenu = sub
            item.isEnabled = enabled
            menu.addItem(item)
        }

        menu.addItem(.sectionHeader(title: "After Capture"))
        toggle("Show Quick Access Overlay", Settings.showOverlay) { Settings.showOverlay = $0 }
        toggle("Copy to Clipboard", Settings.copyToClipboard) { Settings.copyToClipboard = $0 }
        toggle("Save to Folder", Settings.saveToDisk) { Settings.saveToDisk = $0 }
        let fm = FileManager.default
        let folders: [(String, String)] = [
            ("Desktop", fm.urls(for: .desktopDirectory, in: .userDomainMask)[0].path),
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path),
            ("Downloads", fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path),
            ("Pictures", fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].path),
        ]
        let current = Settings.saveDirectory.path
        let folderItem = NSMenuItem(title: "Folder: \(Settings.saveDirectory.lastPathComponent)", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        for (name, path) in folders {
            folderMenu.addItem(ClosureMenuItem(name, checked: path == current) {
                Settings.saveDirectory = URL(fileURLWithPath: path)
            })
        }
        folderMenu.addItem(.separator())
        folderMenu.addItem(ClosureMenuItem("Other…", checked: !folders.contains { $0.1 == current }) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            if panel.runModal() == .OK, let url = panel.url { Settings.saveDirectory = url }
        })
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        menu.addItem(.separator())
        choice("Timer", [("None", 0), ("3 Seconds", 3), ("5 Seconds", 5), ("10 Seconds", 10)],
               current: Settings.captureTimer) { Settings.captureTimer = $0 }

        if intent == .screenshot {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Window"))
            toggle("Include Window Shadow", Settings.windowShadow) { Settings.windowShadow = $0 }
            toggle("Capture As Shown (keeps menus & tooltips)", Settings.windowAsShown) { Settings.windowAsShown = $0 }
            choice("Background", WindowBackground.allCases.map { ($0.title, $0) }, current: Settings.windowBackground) {
                Settings.windowBackground = $0
            }
            choice("Padding", [("Small", 0), ("Medium", 1), ("Large", 2)], current: Settings.windowPadding,
                   enabled: Settings.windowBackground != .none) { Settings.windowPadding = $0 }
            menu.addItem(.separator())
            toggle("Freeze Screen", Settings.freezeScreen) { Settings.freezeScreen = $0 }
        } else {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recording"))
            choice("Format", [("Video (MP4)", RecordFormat.mp4), ("GIF", RecordFormat.gif)], current: Settings.recordFormat) {
                Settings.recordFormat = $0
            }
            choice("Frame Rate", [("24 fps", 24), ("30 fps", 30), ("60 fps", 60)], current: Settings.recordFPS) {
                Settings.recordFPS = $0
            }

            let mics = MediaDevices.microphones()
            var micOptions: [(String, String?)] = [("None", nil)]
            micOptions += mics.map { ($0.localizedName, $0.uniqueID) }
            let micCurrent: String? = Settings.recordMicrophone ? (Settings.microphoneID ?? mics.first?.uniqueID) : nil
            if #available(macOS 15.0, *) {
                choice("Microphone", micOptions, current: micCurrent) { id in
                    Settings.recordMicrophone = id != nil
                    Settings.microphoneID = id
                }
            } else {
                choice("Microphone (macOS 15+)", micOptions, current: nil, enabled: false) { _ in }
            }
            toggle("Record Computer Audio", Settings.recordSystemAudio) { Settings.recordSystemAudio = $0 }

            let cams = MediaDevices.cameras()
            var camOptions: [(String, String?)] = [("None", nil)]
            camOptions += cams.map { ($0.localizedName, $0.uniqueID) }
            let camCurrent: String? = Settings.cameraEnabled ? (Settings.cameraID ?? cams.first?.uniqueID) : nil
            choice("Camera", camOptions, current: camCurrent) { id in
                Settings.cameraEnabled = id != nil
                Settings.cameraID = id
            }
            choice("Camera Shape", [("Circle", CameraShape.circle), ("Rounded Rectangle", CameraShape.rounded)],
                   current: Settings.cameraShape, enabled: Settings.cameraEnabled) { Settings.cameraShape = $0 }
            choice("Camera Size", [("Small", 0), ("Medium", 1), ("Large", 2)], current: Settings.cameraSize,
                   enabled: Settings.cameraEnabled) { Settings.cameraSize = $0 }

            menu.addItem(.separator())
            toggle("Show Mouse Pointer", Settings.recordCursor) { Settings.recordCursor = $0 }
            toggle("Highlight Clicks", Settings.highlightClicks) { Settings.highlightClicks = $0 }
            toggle("Show Keystrokes", Settings.showKeystrokes) { Settings.showKeystrokes = $0 }
            toggle("Hide Desktop Icons While Recording", Settings.hideIconsWhileRecording) {
                Settings.hideIconsWhileRecording = $0
            }
        }
        menu.addItem(.separator())
        toggle("Remember Last Selection", Settings.rememberSelection) { Settings.rememberSelection = $0 }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

enum MediaDevices {
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }
}
