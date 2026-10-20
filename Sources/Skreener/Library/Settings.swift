import AppKit

/// UserDefaults-backed preferences. Keys are shared with SettingsView's @AppStorage bindings.
enum SettingsKey {
    static let saveDirectory = "saveDirectory"
    static let showOverlay = "showOverlay"
    static let copyToClipboard = "copyToClipboard"
    static let saveToDisk = "saveToDisk"
    static let playSound = "playSound"
    static let overlayAutoClose = "overlayAutoCloseSeconds"
    static let historyEnabled = "historyEnabled"
    static let historyLimit = "historyLimit"
    static let windowShadow = "captureWindowShadow"
    static let windowBackground = "windowBackground"
    static let windowPadding = "windowPadding"
    static let windowAsShown = "windowAsShown"
    static let freezeScreen = "freezeScreen"
    static let captureTimer = "captureTimer"
    static let rememberSelection = "rememberSelection"
    static let lastSelection = "lastSelection"
    static let ocrKeepLineBreaks = "ocrKeepLineBreaks"
    static let recordFPS = "recordFPS"
    static let recordFormat = "recordFormat"
    static let recordCursor = "recordShowsCursor"
    static let recordSystemAudio = "recordSystemAudio"
    static let recordMicrophone = "recordMicrophone"
    static let microphoneID = "microphoneDeviceID"
    static let highlightClicks = "highlightClicks"
    static let showKeystrokes = "showKeystrokes"
    static let cameraEnabled = "cameraEnabled"
    static let cameraID = "cameraDeviceID"
    static let cameraShape = "cameraShape"
    static let cameraSize = "cameraSize"
    static let hideIconsWhileRecording = "hideIconsWhileRecording"
}

enum RecordFormat: String { case mp4, gif }
enum CameraShape: String { case circle, rounded }

/// Backgrounds a captured window can be placed on.
enum WindowBackground: String, CaseIterable {
    case none, wallpaper, sunset, ocean, mint, graphite

    var title: String {
        switch self {
        case .none: "None (transparent)"
        case .wallpaper: "Desktop Wallpaper"
        case .sunset: "Sunset Gradient"
        case .ocean: "Ocean Gradient"
        case .mint: "Mint Gradient"
        case .graphite: "Graphite Gradient"
        }
    }
}

enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
        d.register(defaults: [
            SettingsKey.saveDirectory: desktop,
            SettingsKey.showOverlay: true,
            SettingsKey.copyToClipboard: false,
            SettingsKey.saveToDisk: false,
            SettingsKey.playSound: true,
            SettingsKey.overlayAutoClose: 0,
            SettingsKey.historyEnabled: true,
            SettingsKey.historyLimit: 200,
            SettingsKey.windowShadow: true,
            SettingsKey.windowBackground: WindowBackground.none.rawValue,
            SettingsKey.windowPadding: 1,
            SettingsKey.windowAsShown: false,
            SettingsKey.freezeScreen: true,
            SettingsKey.captureTimer: 0,
            SettingsKey.rememberSelection: true,
            SettingsKey.ocrKeepLineBreaks: true,
            SettingsKey.recordFPS: 60,
            SettingsKey.recordFormat: RecordFormat.mp4.rawValue,
            SettingsKey.recordCursor: true,
            SettingsKey.recordSystemAudio: false,
            SettingsKey.recordMicrophone: false,
            SettingsKey.highlightClicks: false,
            SettingsKey.showKeystrokes: false,
            SettingsKey.cameraEnabled: false,
            SettingsKey.cameraShape: CameraShape.circle.rawValue,
            SettingsKey.cameraSize: 1,
            SettingsKey.hideIconsWhileRecording: false,
        ])
    }

    static var saveDirectory: URL {
        get { URL(fileURLWithPath: d.string(forKey: SettingsKey.saveDirectory) ?? NSHomeDirectory()) }
        set { d.set(newValue.path, forKey: SettingsKey.saveDirectory) }
    }

    private static func bool(_ key: String) -> Bool { d.bool(forKey: key) }
    private static func set(_ key: String, _ value: Any?) { d.set(value, forKey: key) }

    static var showOverlay: Bool { get { bool(SettingsKey.showOverlay) } set { set(SettingsKey.showOverlay, newValue) } }
    static var copyToClipboard: Bool { get { bool(SettingsKey.copyToClipboard) } set { set(SettingsKey.copyToClipboard, newValue) } }
    static var saveToDisk: Bool { get { bool(SettingsKey.saveToDisk) } set { set(SettingsKey.saveToDisk, newValue) } }
    static var playSound: Bool { bool(SettingsKey.playSound) }
    static var overlayAutoClose: Int { d.integer(forKey: SettingsKey.overlayAutoClose) }
    static var historyEnabled: Bool { bool(SettingsKey.historyEnabled) }
    static var historyLimit: Int { max(10, d.integer(forKey: SettingsKey.historyLimit)) }
    static var ocrKeepLineBreaks: Bool { bool(SettingsKey.ocrKeepLineBreaks) }
    static var freezeScreen: Bool { get { bool(SettingsKey.freezeScreen) } set { set(SettingsKey.freezeScreen, newValue) } }
    static var captureTimer: Int { get { d.integer(forKey: SettingsKey.captureTimer) } set { set(SettingsKey.captureTimer, newValue) } }
    static var rememberSelection: Bool { get { bool(SettingsKey.rememberSelection) } set { set(SettingsKey.rememberSelection, newValue) } }

    /// Last confirmed area selection, in global AppKit coordinates.
    static var lastSelection: CGRect? {
        get { d.string(forKey: SettingsKey.lastSelection).map { NSRectFromString($0) }.flatMap { $0.width > 4 ? $0 : nil } }
        set { set(SettingsKey.lastSelection, newValue.map { NSStringFromRect($0) }) }
    }

    // Window capture
    static var windowShadow: Bool { get { bool(SettingsKey.windowShadow) } set { set(SettingsKey.windowShadow, newValue) } }
    static var windowAsShown: Bool { get { bool(SettingsKey.windowAsShown) } set { set(SettingsKey.windowAsShown, newValue) } }
    static var windowBackground: WindowBackground {
        get { WindowBackground(rawValue: d.string(forKey: SettingsKey.windowBackground) ?? "") ?? .none }
        set { set(SettingsKey.windowBackground, newValue.rawValue) }
    }
    /// 0 small, 1 medium, 2 large.
    static var windowPadding: Int { get { d.integer(forKey: SettingsKey.windowPadding) } set { set(SettingsKey.windowPadding, newValue) } }

    // Recording
    static var recordFPS: Int {
        get { min(60, max(5, d.integer(forKey: SettingsKey.recordFPS))) }
        set { set(SettingsKey.recordFPS, newValue) }
    }
    static var recordFormat: RecordFormat {
        get { RecordFormat(rawValue: d.string(forKey: SettingsKey.recordFormat) ?? "") ?? .mp4 }
        set { set(SettingsKey.recordFormat, newValue.rawValue) }
    }
    static var recordCursor: Bool { get { bool(SettingsKey.recordCursor) } set { set(SettingsKey.recordCursor, newValue) } }
    static var recordSystemAudio: Bool { get { bool(SettingsKey.recordSystemAudio) } set { set(SettingsKey.recordSystemAudio, newValue) } }
    static var recordMicrophone: Bool { get { bool(SettingsKey.recordMicrophone) } set { set(SettingsKey.recordMicrophone, newValue) } }
    static var microphoneID: String? { get { d.string(forKey: SettingsKey.microphoneID) } set { set(SettingsKey.microphoneID, newValue) } }
    static var highlightClicks: Bool { get { bool(SettingsKey.highlightClicks) } set { set(SettingsKey.highlightClicks, newValue) } }
    static var showKeystrokes: Bool { get { bool(SettingsKey.showKeystrokes) } set { set(SettingsKey.showKeystrokes, newValue) } }
    static var cameraEnabled: Bool { get { bool(SettingsKey.cameraEnabled) } set { set(SettingsKey.cameraEnabled, newValue) } }
    static var cameraID: String? { get { d.string(forKey: SettingsKey.cameraID) } set { set(SettingsKey.cameraID, newValue) } }
    static var cameraShape: CameraShape {
        get { CameraShape(rawValue: d.string(forKey: SettingsKey.cameraShape) ?? "") ?? .circle }
        set { set(SettingsKey.cameraShape, newValue.rawValue) }
    }
    /// 0 small, 1 medium, 2 large.
    static var cameraSize: Int { get { d.integer(forKey: SettingsKey.cameraSize) } set { set(SettingsKey.cameraSize, newValue) } }
    static var hideIconsWhileRecording: Bool {
        get { bool(SettingsKey.hideIconsWhileRecording) }
        set { set(SettingsKey.hideIconsWhileRecording, newValue) }
    }

    static func fileName(ext: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Skreener \(f.string(from: date)).\(ext)"
    }
}
