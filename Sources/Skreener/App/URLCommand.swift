import AppKit

/// `skreener://<command>` automation API, modelled on the command set CleanShot exposes.
/// Example: `open "skreener://capture-area"`.
@MainActor
enum URLCommand {
    static let commands: [String: (Coordinator) -> Void] = [
        "capture-area": { $0.captureArea() },
        "capture-previous-area": { $0.capturePreviousArea() },
        "capture-fullscreen": { $0.captureFullscreen() },
        "capture-window": { $0.captureWindow() },
        "capture-text": { $0.captureText() },
        "record-screen": { $0.toggleRecording() },
        "capture-toolbar": { $0.openCaptureToolbar(intent: .screenshot, target: .area) },
        "pick-color": { $0.pickColor() },
        "watch-area": { $0.toggleWatchArea() },
        "open-annotate": { $0.openAnnotateFromFile() },
        "open-from-clipboard": { $0.openFromClipboard() },
        "pin-from-clipboard": { $0.pinFromClipboard() },
        "annotate-last": { $0.annotateLast() },
        "pin-last": { $0.pinLast() },
        "restore-recently-closed": { $0.restoreRecentlyClosed() },
        "open-history": { _ in WindowManager.shared.showHistory() },
        "open-settings": { _ in WindowManager.shared.showSettings() },
        "hide-desktop-icons": { _ in DesktopIconHider.shared.hide() },
        "show-desktop-icons": { _ in DesktopIconHider.shared.show() },
        "toggle-desktop-icons": { _ in DesktopIconHider.shared.toggle() },
    ]

    static func handle(_ url: URL) {
        // skreener://capture-area parses with host "capture-area"; tolerate skreener:///capture-area too.
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if let command = commands[name] {
            command(Coordinator.shared)
        } else {
            NSLog("Skreener: unknown URL command \(url.absoluteString)")
        }
    }
}
