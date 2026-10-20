import AppKit
import UniformTypeIdentifiers

/// Editor window: tool bar on top, canvas below.
final class AnnotateWindowController: NSWindowController, NSWindowDelegate {
    @MainActor private static var open: [AnnotateWindowController] = []

    private let canvas: AnnotationCanvas
    private let toolControl: NSSegmentedControl
    private let widthControl: NSSegmentedControl
    private let colorWell = NSColorWell(style: .minimal)
    private var undoButton: NSButton!
    private var redoButton: NSButton!

    private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue,
                                             .systemPurple, .white, .black]
    private static let widths: [CGFloat] = [2, 4, 8]

    @MainActor
    static func open(image: CGImage, pixelScale: CGFloat) {
        let wc = AnnotateWindowController(document: AnnotationDocument(base: image, pixelScale: pixelScale))
        open.append(wc)
        wc.showWindow(nil)
        wc.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private init(document: AnnotationDocument) {
        canvas = AnnotationCanvas(document: document)
        toolControl = NSSegmentedControl(images: AnnotationTool.allCases.map { NSImage.symbol($0.symbol, size: 14) ?? NSImage() },
                                         trackingMode: .selectOne, target: nil, action: nil)
        widthControl = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)

        let screen = NSScreen.withMouse.visibleFrame
        let imageSize = CGSize(width: CGFloat(document.base.width) / document.pixelScale,
                               height: CGFloat(document.base.height) / document.pixelScale)
        let size = CGSize(width: min(max(imageSize.width + 48, 760), screen.width * 0.85),
                          height: min(max(imageSize.height + 48 + 44, 460), screen.height * 0.85))
        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = "Annotate"
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        buildUI()
        canvas.onStateChange = { [weak self] in self?.syncControls() }
        syncControls()
        window.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    private func buildUI() {
        guard let content = window?.contentView else { return }

        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        for (i, tool) in AnnotationTool.allCases.enumerated() {
            toolControl.setToolTip(tool.title, forSegment: i)
            toolControl.setWidth(30, forSegment: i)
        }

        var swatches: [NSView] = Self.palette.enumerated().map { i, color in
            let b = NSButton(title: "", target: self, action: #selector(swatchClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = color.cgColor
            b.layer?.cornerRadius = 8
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 16).isActive = true
            b.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return b
        }
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)
        swatches.append(colorWell)
        let swatchStack = NSStackView(views: swatches)
        swatchStack.spacing = 5

        widthControl.target = self
        widthControl.action = #selector(widthChanged)
        widthControl.selectedSegment = 1
        widthControl.setToolTip("Line width / text size", forSegment: 0)

        undoButton = iconButton("arrow.uturn.backward", #selector(AnnotationCanvas.undo(_:)), "Undo (⌘Z)", target: canvas)
        redoButton = iconButton("arrow.uturn.forward", #selector(AnnotationCanvas.redo(_:)), "Redo (⇧⌘Z)", target: canvas)
        let redact = iconButton("eye.slash", #selector(autoRedact), "Auto-Redact: pixelate emails, phone numbers, card numbers, API keys and tokens", target: self)
        let lift = iconButton("person.crop.rectangle.badge.plus", #selector(liftSubject), "Lift Subject: cut out the main subject with a transparent background", target: self)
        let pin = iconButton("pin", #selector(pinImage), "Pin to screen", target: self)
        let copy = iconButton("doc.on.doc", #selector(copyImage), "Copy (⌘C)", target: self)
        let save = iconButton("square.and.arrow.down", #selector(saveDocument(_:)), "Save As… (⌘S)", target: self)
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = ""
        done.toolTip = "Copy to clipboard and close"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [toolControl, swatchStack, widthControl, spacer, redact, lift, undoButton, redoButton,
                                      pin, copy, save, done])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 78, bottom: 0, right: 12)
        bar.setCustomSpacing(4, after: redact)
        bar.setCustomSpacing(4, after: undoButton)

        content.addSubview(bar)
        content.addSubview(canvas)
        bar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func iconButton(_ symbol: String, _ action: Selector, _ tip: String, target: AnyObject) -> NSButton {
        let b = NSButton(image: NSImage.symbol(symbol, size: 14) ?? NSImage(), target: target, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        return b
    }

    private func syncControls() {
        toolControl.selectedSegment = AnnotationTool.allCases.firstIndex(of: canvas.tool) ?? 0
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool.allCases[toolControl.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        let c = Self.palette[sender.tag]
        colorWell.color = c
        canvas.applyColor(c)
    }

    @objc private func colorWellChanged() { canvas.applyColor(colorWell.color) }

    @objc private func widthChanged() { canvas.applyLineWidth(Self.widths[widthControl.selectedSegment]) }

    // MARK: Output

    private func rendered() -> CGImage? {
        canvas.finishEditing()
        return canvas.doc.render()
    }

    @objc func copyImage() {
        guard let img = rendered() else { return }
        Clipboard.copy(image: img, pixelScale: canvas.doc.pixelScale)
        MainActor.assumeIsolated { Toast.show("Copied to clipboard") }
    }

    /// ⌘C from the Edit menu reaches here when the canvas is first responder.
    @objc func copy(_ sender: Any?) { copyImage() }

    @objc func done() {
        copyImage()
        close()
    }

    @objc func autoRedact() {
        let doc = canvas.doc
        Task { @MainActor in
            do {
                let matches = try await VisionTools.sensitiveText(in: doc.base)
                    .filter { doc.visibleRect.intersects($0.rect) }
                if matches.isEmpty {
                    Toast.show("Nothing sensitive found", symbol: "checkmark.shield")
                } else {
                    canvas.addRedactions(matches.map(\.rect))
                    let kinds = Set(matches.map(\.kind)).sorted().joined(separator: ", ")
                    Toast.show("Redacted \(matches.count) item\(matches.count == 1 ? "" : "s") (\(kinds)). ⌘Z to undo",
                               symbol: "eye.slash.fill")
                }
            } catch {
                Coordinator.shared.presentError(error)
            }
        }
    }

    @objc func liftSubject() {
        guard let img = rendered() else { return }
        let scale = canvas.doc.pixelScale
        Task { @MainActor in
            do {
                guard let subject = try await VisionTools.liftSubject(from: img) else {
                    Toast.show("No clear subject found", symbol: "person.crop.rectangle")
                    return
                }
                Clipboard.copy(image: subject, pixelScale: scale)
                AnnotateWindowController.open(image: subject, pixelScale: scale)
                Toast.show("Subject lifted and copied (transparent PNG)", symbol: "person.crop.rectangle.badge.plus")
            } catch {
                Coordinator.shared.presentError(error)
            }
        }
    }

    @objc func pinImage() {
        guard let img = rendered() else { return }
        MainActor.assumeIsolated { PinPanel.pin(image: img, pixelScale: canvas.doc.pixelScale) }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let img = rendered(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = Settings.fileName(ext: "png")
        panel.directoryURL = Settings.saveDirectory
        let scale = canvas.doc.pixelScale
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let data: Data?
            if url.pathExtension.lowercased().hasPrefix("jp") {
                data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            } else {
                data = ImageIOHelper.pngData(img, pixelScale: scale)
            }
            do {
                try data?.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { Self.open.removeAll { $0 === self } }
    }
}

/// Routes ⌘C to the image copy unless a text field is being edited.
private final class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "c",
           let wc = windowController as? AnnotateWindowController {
            wc.copyImage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
