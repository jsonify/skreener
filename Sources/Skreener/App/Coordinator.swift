import AppKit

/// Central entry point for every user-triggered action (menu, hotkey, URL scheme).
@MainActor
final class Coordinator {
    static let shared = Coordinator()

    private var previousArea: (rect: CGRect, displayID: CGDirectDisplayID)?
    private var lastCapture: CaptureItem?

    // MARK: Screenshots

    func captureArea() {
        guard ensurePermission() else { return }
        withFrozenScreen { frozen in
            SelectionController.begin(mode: .area, allowWindowMode: true, clickAction: .window, frozen: frozen) { [weak self] result in
                self?.handleSelection(result, frozen: frozen)
            }
        }
    }

    /// Scrolling capture: select the scrollable part of the screen, then scroll or Auto-Scroll.
    func scrollingCapture() { openCaptureToolbar(intent: .screenshot, target: .scrolling) }

    /// ⌘⇧5: the capture toolbar, starting in window mode.
    func captureWindow() { openCaptureToolbar(intent: .screenshot, target: .window) }

    /// Opens the ⌘⇧5-style toolbar session. Screenshots freeze the screen first (when enabled).
    func openCaptureToolbar(intent: CaptureIntent, target: CaptureTarget) {
        guard ensurePermission() else { return }
        if CaptureSession.isActive { return }
        let start: (FrozenScreens?) -> Void = { frozen in
            CaptureSession.begin(intent: intent, target: target, frozen: frozen) { [weak self] request in
                guard let request else { return }
                self?.perform(request, frozen: frozen)
            }
        }
        // Recording and scrolling capture work on the live screen, so they never freeze it.
        if intent == .screenshot, target != .scrolling { withFrozenScreen(start) } else { start(nil) }
    }

    private func perform(_ request: CaptureRequest, frozen: FrozenScreens?) {
        if request.intent == .recording {
            Task { await ScreenRecorder.shared.begin(request) }
            return
        }
        if request.target == .scrolling {
            ScrollingCaptureController.begin(rect: request.rect, screen: request.screen)
            return
        }
        Task {
            // A timer means "capture what's on screen later", so it never uses the frozen image.
            let timer = Settings.captureTimer
            if timer > 0, !(await CountdownOverlay.run(seconds: timer, over: request.rect)) { return }
            let snapshot = timer > 0 ? nil : frozen
            do {
                switch request.target {
                case .fullscreen, .area:
                    if request.target == .area { previousArea = (request.rect, request.screen.displayID) }
                    if let shot = snapshot?.crop(request.rect, on: request.screen) {
                        didCapture(shot.0, pixelScale: shot.1)
                    } else {
                        let (image, scale) = try await ScreenCapturer.capture(rect: request.rect, on: request.screen)
                        didCapture(image, pixelScale: scale)
                    }
                case .scrolling:
                    break
                case .window:
                    guard let w = request.window else { return }
                    var shot: (CGImage, CGFloat)?
                    if Settings.windowAsShown { shot = snapshot?.crop(window: w) }
                    if shot == nil { shot = try await ScreenCapturer.capture(windowID: w.id, includeShadow: Settings.windowShadow) }
                    guard let (image, scale) = shot else { return }
                    didCapture(WindowStyler.apply(image, pixelScale: scale, screen: request.screen), pixelScale: scale)
                }
            } catch {
                presentError(error)
            }
        }
    }

    /// Snapshots all displays first (when Freeze Screen is on) so tooltips, hover states and
    /// open menus survive while the selection overlay is up. Nothing is shown or activated
    /// before the snapshot, because that would dismiss them.
    private func withFrozenScreen(_ then: @escaping (FrozenScreens?) -> Void) {
        guard Settings.freezeScreen else { return then(nil) }
        Task {
            do {
                then(try await ScreenCapturer.freezeAllScreens())
            } catch {
                NSLog("Skreener: freeze failed, selecting on live screen: \(error)")
                then(nil)
            }
        }
    }

    func captureFullscreen() {
        guard ensurePermission() else { return }
        let screen = NSScreen.withMouse
        run { try await ScreenCapturer.capture(rect: screen.frame, on: screen) }
    }

    func capturePreviousArea() {
        guard ensurePermission() else { return }
        guard let prev = previousArea,
              let screen = NSScreen.screens.first(where: { $0.displayID == prev.displayID }) else {
            captureArea()
            return
        }
        run { try await ScreenCapturer.capture(rect: prev.rect, on: screen) }
    }

    private func handleSelection(_ result: SelectionResult?, frozen: FrozenScreens?) {
        switch result {
        case .area(let rect, let screen):
            previousArea = (rect, screen.displayID)
            if let shot = frozen?.crop(rect, on: screen) { return didCapture(shot.0, pixelScale: shot.1) }
            run { try await ScreenCapturer.capture(rect: rect, on: screen) }
        case .window(let w):
            // From a frozen screen, crop the window as it looked, including any menu or tooltip over it.
            if let shot = frozen?.crop(window: w) { return didCapture(shot.0, pixelScale: shot.1) }
            run { try await ScreenCapturer.capture(windowID: w.id, includeShadow: Settings.windowShadow) }
        case nil:
            break
        }
    }

    private func run(_ capture: @escaping () async throws -> (CGImage, CGFloat)) {
        Task {
            do {
                let (image, scale) = try await capture()
                didCapture(image, pixelScale: scale)
            } catch {
                presentError(error)
            }
        }
    }

    func didCapture(_ image: CGImage, pixelScale: CGFloat) {
        Sound.capture()
        do {
            let item = try HistoryStore.shared.add(image: image, pixelScale: pixelScale)
            lastCapture = item
            if Settings.copyToClipboard { Clipboard.copy(image: image, pixelScale: pixelScale) }
            if Settings.saveToDisk { try item.export() }
            if Settings.showOverlay {
                QuickAccessManager.shared.show(item)
            } else if Settings.copyToClipboard {
                Toast.show("Copied to clipboard")
            }
        } catch {
            presentError(error)
        }
    }

    // MARK: OCR

    func captureText() {
        guard ensurePermission() else { return }
        withFrozenScreen { frozen in
            SelectionController.begin(mode: .area, allowWindowMode: false, clickAction: .none, frozen: frozen) { result in
                guard case .area(let rect, let screen) = result else { return }
                self.recognizeText(rect: rect, screen: screen, frozen: frozen)
            }
        }
    }

    private func recognizeText(rect: CGRect, screen: NSScreen, frozen: FrozenScreens?) {
            Task {
                do {
                    let image: CGImage
                    if let shot = frozen?.crop(rect, on: screen) {
                        image = shot.0
                    } else {
                        image = try await ScreenCapturer.capture(rect: rect, on: screen).0
                    }
                    async let codes = VisionTools.barcodes(in: image)
                    async let recognized = TextRecognizer.recognize(image, keepLineBreaks: Settings.ocrKeepLineBreaks)
                    let (payloads, text) = try await (codes, recognized)
                    // A QR/barcode wins over plain text: its payload is what the user is after.
                    if let payload = payloads.first {
                        Clipboard.copy(text: payloads.joined(separator: "\n"))
                        Sound.ocr()
                        self.offerToOpen(payload)
                    } else if text.isEmpty {
                        Toast.show("No text found", symbol: "text.magnifyingglass")
                    } else {
                        Clipboard.copy(text: text)
                        Sound.ocr()
                        Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
                    }
                } catch {
                    self.presentError(error)
                }
            }
    }

    private func offerToOpen(_ payload: String) {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel", "sms", "facetime"].contains(scheme) else {
            Toast.show("Code copied: \(payload.prefix(60))", symbol: "qrcode.viewfinder")
            return
        }
        let alert = NSAlert()
        alert.messageText = "QR code found"
        alert.informativeText = "\(payload)\n\nThe link was copied to the clipboard."
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    // MARK: Color picker

    func pickColor() {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                             Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            Clipboard.copy(text: hex)
            Sound.ocr()
            MainActor.assumeIsolated { Toast.show("\(hex) copied", symbol: "eyedropper") }
        }
    }

    // MARK: Watch area

    func toggleWatchArea() {
        if AreaWatcher.shared.isWatching {
            AreaWatcher.shared.stop()
            Toast.show("Stopped watching", symbol: "eye.slash")
            return
        }
        guard ensurePermission() else { return }
        SelectionController.begin(mode: .area, allowWindowMode: false, clickAction: .none) { result in
            guard case .area(let rect, let screen) = result else { return }
            Task {
                do {
                    try await AreaWatcher.shared.start(rect: rect, screen: screen)
                    Toast.show("Watching area: Skreener will capture it when it changes", symbol: "eye")
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if ScreenRecorder.shared.isRecording {
            Task { await ScreenRecorder.shared.stop() }
            return
        }
        openCaptureToolbar(intent: .recording, target: .area)
    }

    func didRecord(url: URL) {
        let item = CaptureItem(url: url, date: Date())
        lastCapture = item
        NotificationCenter.default.post(name: .historyChanged, object: nil)
        if Settings.saveToDisk { _ = try? item.export() }
        QuickAccessManager.shared.show(item)
    }

    // MARK: Other tools

    func openAnnotateFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = Settings.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let (cg, scale) = ImageIOHelper.load(url) else { return }
        AnnotateWindowController.open(image: cg, pixelScale: scale)
    }

    func openFromClipboard() {
        guard let (cg, scale) = Clipboard.image() else {
            Toast.show("No image on the clipboard", symbol: "exclamationmark.circle")
            return
        }
        AnnotateWindowController.open(image: cg, pixelScale: scale)
    }

    func pinFromClipboard() {
        guard let (cg, scale) = Clipboard.image() else {
            Toast.show("No image on the clipboard", symbol: "exclamationmark.circle")
            return
        }
        PinPanel.pin(image: cg, pixelScale: scale)
    }

    func annotateLast() {
        guard let item = lastCapture ?? HistoryStore.shared.items().first(where: { $0.kind == .image }) else { return }
        QuickAccessManager.shared.annotate(item)
    }

    func pinLast() {
        guard let item = lastCapture ?? HistoryStore.shared.items().first(where: { $0.kind == .image }) else { return }
        QuickAccessManager.shared.pin(item)
    }

    func restoreRecentlyClosed() { QuickAccessManager.shared.restoreRecentlyClosed() }

    // MARK: Helpers

    private func ensurePermission() -> Bool {
        if ScreenCapturer.hasPermission { return true }
        ScreenCapturer.requestPermission()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Allow Skreener in System Settings › Privacy & Security › Screen & System Audio Recording, then try again. You may need to quit and reopen Skreener."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    func presentError(_ error: Error) {
        NSLog("Skreener error: \(error)")
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
