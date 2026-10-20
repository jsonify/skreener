import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSApp.mainMenu = MainMenu.build()
        statusBar = StatusBarController()
        registerHotkeys()
    }

    private func registerHotkeys() {
        let c = Coordinator.shared
        for action in HotkeyAction.allCases {
            HotkeyCenter.shared.register(action.defaultHotkey, id: action.rawValue) {
                switch action {
                case .captureArea: c.captureArea()
                case .captureFullscreen: c.captureFullscreen()
                case .captureWindow: c.captureWindow()
                case .capturePreviousArea: c.capturePreviousArea()
                case .captureText: c.captureText()
                case .toggleRecording: c.toggleRecording()
                case .pickColor: c.pickColor()
                case .watchArea: c.toggleWatchArea()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "skreener" {
                URLCommand.handle(url)
            } else if url.isFileURL, let (cg, scale) = ImageIOHelper.load(url) {
                AnnotateWindowController.open(image: cg, pixelScale: scale)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        DesktopIconHider.shared.show()
    }
}

enum MainMenu {
    /// Gives windows the standard Edit/Window key equivalents (⌘Z, ⌘C, ⌘W…) even though the app
    /// has no Dock icon or visible menu bar.
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Skreener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save As…", action: #selector(AnnotateWindowController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(AnnotationCanvas.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(AnnotationCanvas.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}
