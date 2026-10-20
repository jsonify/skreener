import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Skreener")
        item.button?.image?.isTemplate = true
        menu.delegate = self
        item.menu = menu
        ScreenRecorder.shared.onStateChange = { [weak self] recording in self?.setRecording(recording) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add(HotkeyAction.captureArea, #selector(captureArea))
        add(HotkeyAction.capturePreviousArea, #selector(capturePreviousArea))
        add(HotkeyAction.captureFullscreen, #selector(captureFullscreen))
        add(HotkeyAction.captureWindow, #selector(captureWindow))
        add(HotkeyAction.captureText, #selector(captureText))
        add("Capture Toolbar…", #selector(openToolbar))
        menu.addItem(.separator())
        let record = add(HotkeyAction.toggleRecording, #selector(toggleRecording))
        if ScreenRecorder.shared.isRecording { record.title = "Stop Recording" }
        let watch = add(HotkeyAction.watchArea, #selector(watchArea))
        if AreaWatcher.shared.isWatching { watch.title = "Stop Watching Area" }
        add(HotkeyAction.pickColor, #selector(pickColor))
        menu.addItem(.separator())
        add("Open Annotation Tool…", #selector(openAnnotate))
        add("Open From Clipboard", #selector(openFromClipboard))
        add("Annotate Last Screenshot", #selector(annotateLast))
        add("Pin Last Screenshot", #selector(pinLast))
        add("Pin From Clipboard", #selector(pinFromClipboard))
        let restore = add("Restore Recently Closed", #selector(restoreRecentlyClosed))
        restore.isEnabled = QuickAccessManager.shared.hasRecentlyClosed
        add("Capture History…", #selector(openHistory))
        menu.addItem(.separator())
        add(DesktopIconHider.shared.isHidden ? "Show Desktop Icons" : "Hide Desktop Icons", #selector(toggleDesktopIcons))
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        add("Quit Skreener", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @discardableResult
    private func add(_ action: HotkeyAction, _ selector: Selector) -> NSMenuItem {
        let hk = action.defaultHotkey
        let mi = add(action.title, selector, key: hk.keyEquivalent)
        mi.keyEquivalentModifierMask = hk.modifiers
        return mi
    }

    // MARK: Recording state

    private func setRecording(_ recording: Bool) {
        timer?.invalidate()
        timer = nil
        guard let button = item.button else { return }
        if recording {
            item.menu = nil
            button.target = self
            button.action = #selector(toggleRecording)
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            updateElapsed()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateElapsed() }
            }
        } else {
            button.title = ""
            button.action = nil
            button.contentTintColor = nil
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Skreener")
            button.image?.isTemplate = true
            item.menu = menu
        }
    }

    private func updateElapsed() {
        let rec = ScreenRecorder.shared
        let s = Int(rec.elapsed)
        item.button?.title = (rec.isPaused ? " ⏸" : "") + String(format: " %d:%02d", s / 60, s % 60)
    }

    // MARK: Actions

    @objc private func captureArea() { Coordinator.shared.captureArea() }
    @objc private func capturePreviousArea() { Coordinator.shared.capturePreviousArea() }
    @objc private func captureFullscreen() { Coordinator.shared.captureFullscreen() }
    @objc private func captureWindow() { Coordinator.shared.captureWindow() }
    @objc private func openToolbar() { Coordinator.shared.openCaptureToolbar(intent: .screenshot, target: .area) }
    @objc private func captureText() { Coordinator.shared.captureText() }
    @objc private func toggleRecording() { Coordinator.shared.toggleRecording() }
    @objc private func watchArea() { Coordinator.shared.toggleWatchArea() }
    @objc private func pickColor() { Coordinator.shared.pickColor() }
    @objc private func openAnnotate() { Coordinator.shared.openAnnotateFromFile() }
    @objc private func openFromClipboard() { Coordinator.shared.openFromClipboard() }
    @objc private func annotateLast() { Coordinator.shared.annotateLast() }
    @objc private func pinLast() { Coordinator.shared.pinLast() }
    @objc private func pinFromClipboard() { Coordinator.shared.pinFromClipboard() }
    @objc private func restoreRecentlyClosed() { Coordinator.shared.restoreRecentlyClosed() }
    @objc private func openHistory() { WindowManager.shared.showHistory() }
    @objc private func toggleDesktopIcons() { DesktopIconHider.shared.toggle() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
