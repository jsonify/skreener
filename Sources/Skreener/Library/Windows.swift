import AppKit
import QuickLookThumbnailing
import ServiceManagement
import SwiftUI

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var history: NSWindow?
    private var settings: NSWindow?

    func showHistory() {
        history = show(history, title: "Capture History", size: CGSize(width: 820, height: 560), resizable: true) {
            HistoryView()
        }
    }

    func showSettings() {
        settings = show(settings, title: "Skreener Settings", size: CGSize(width: 520, height: 440), resizable: false) {
            SettingsView()
        }
    }

    private func show<V: View>(_ existing: NSWindow?, title: String, size: CGSize, resizable: Bool,
                               content: () -> V) -> NSWindow {
        NSApp.activate(ignoringOtherApps: true)
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        w.makeKeyAndOrderFront(nil)
        return w
    }
}

// MARK: - History

struct HistoryView: View {
    @State private var items: [CaptureItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(Settings.historyEnabled ? "No captures yet" : "Capture history is turned off in Settings")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(items) { item in
                            HistoryCell(item: item)
                                .onTapGesture(count: 2) { QuickAccessManager.shared.annotate(item) }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .historyChanged)) { _ in reload() }
    }

    @ViewBuilder
    private func menu(for item: CaptureItem) -> some View {
        let m = QuickAccessManager.shared
        Button(item.kind == .image ? "Annotate" : "Open") { m.annotate(item) }
        Button("Show Quick Access Overlay") { m.show(item) }
        if item.kind == .image { Button("Pin to Screen") { m.pin(item) } }
        Button("Copy") { m.copy(item) }
        Button("Save to \(Settings.saveDirectory.lastPathComponent)") { m.save(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { HistoryStore.shared.delete(item) }
    }

    private func reload() { items = HistoryStore.shared.items() }
}

private struct HistoryCell: View {
    let item: CaptureItem
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(4)
                }
                if item.kind == .video {
                    Image(systemName: "video.fill").padding(6).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .frame(height: 120)
            Text(item.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 360, height: 240),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.saveDirectory) private var saveDirectory = ""
    @AppStorage(SettingsKey.showOverlay) private var showOverlay = true
    @AppStorage(SettingsKey.copyToClipboard) private var copyToClipboard = false
    @AppStorage(SettingsKey.saveToDisk) private var saveToDisk = false
    @AppStorage(SettingsKey.playSound) private var playSound = true
    @AppStorage(SettingsKey.overlayAutoClose) private var autoClose = 0
    @AppStorage(SettingsKey.historyEnabled) private var historyEnabled = true
    @AppStorage(SettingsKey.windowShadow) private var windowShadow = true
    @AppStorage(SettingsKey.freezeScreen) private var freezeScreen = true
    @AppStorage(SettingsKey.ocrKeepLineBreaks) private var ocrLineBreaks = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Show Quick Access Overlay", isOn: $showOverlay)
                Picker("Close overlay automatically", selection: $autoClose) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                }
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder", isOn: $saveToDisk)
                HStack {
                    Text("Folder")
                    Spacer()
                    Text((saveDirectory as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Section("Capture") {
                Toggle("Freeze screen while selecting (keeps tooltips and menus)", isOn: $freezeScreen)
                Toggle("Play sound", isOn: $playSound)
                Toggle("Include window shadow", isOn: $windowShadow)
                Toggle("Keep line breaks in captured text", isOn: $ocrLineBreaks)
                Toggle("Keep capture history", isOn: $historyEnabled)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }
}

private struct RecordingSettings: View {
    @AppStorage(SettingsKey.recordFPS) private var fps = 60
    @AppStorage(SettingsKey.recordCursor) private var cursor = true
    @AppStorage(SettingsKey.recordSystemAudio) private var systemAudio = false
    @AppStorage(SettingsKey.recordMicrophone) private var microphone = false

    var body: some View {
        Form {
            Picker("Frame rate", selection: $fps) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Toggle("Show cursor", isOn: $cursor)
            Toggle("Record computer audio", isOn: $systemAudio)
            Toggle("Record microphone", isOn: $microphone)
            if #unavailable(macOS 15) {
                Text("Microphone recording requires macOS 15 or later.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Click without dragging to record the whole screen. Click the menu-bar timer to stop.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                LabeledContent(action.title) {
                    Text(action.defaultHotkey.displayString).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Text("Automation: open skreener://capture-area, capture-fullscreen, capture-window, capture-text, record-screen, open-from-clipboard, toggle-desktop-icons, …")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Desktop icons

/// Covers desktop icons with a window showing the wallpaper, one per screen.
@MainActor
final class DesktopIconHider {
    static let shared = DesktopIconHider()
    private var windows: [NSWindow] = []

    var isHidden: Bool { !windows.isEmpty }

    func toggle() { isHidden ? show() : hide() }

    func hide() {
        guard !isHidden else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            w.backgroundColor = .black
            w.setFrame(screen.frame, display: false)
            let view = NSView()
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                view.layer?.contents = image
            } else {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            w.contentView = view
            w.orderFront(nil)
            windows.append(w)
        }
    }

    func show() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
