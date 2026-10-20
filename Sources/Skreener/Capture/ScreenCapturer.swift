import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay, noWindow

    var errorDescription: String? {
        switch self {
        case .noDisplay: "The selected display is no longer available."
        case .noWindow: "The selected window is no longer available."
        }
    }
}

/// A capturable on-screen window, with its frame in AppKit global coordinates (bottom-left origin).
struct PickableWindow {
    let id: CGWindowID
    let frame: CGRect
    let owner: String
    let title: String
    let pid: pid_t

    var appIcon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

@MainActor
enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { CGRequestScreenCaptureAccess() }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func ownApps(_ content: SCShareableContent) -> [SCRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { $0.processID == pid }
    }

    /// Filter for a whole display that hides Skreener's own windows (overlays, pins, borders).
    static func displayFilter(for screen: NSScreen) async throws -> (SCContentFilter, SCDisplay) {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        return (SCContentFilter(display: display, excludingApplications: ownApps(content), exceptingWindows: []), display)
    }

    /// Converts a global AppKit rect into the display-local, top-left-origin rect ScreenCaptureKit expects.
    static func displayLocalRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: rect.minX - f.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func capture(rect: CGRect, on screen: NSScreen) async throws -> (CGImage, CGFloat) {
        let (filter, _) = try await displayFilter(for: screen)
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = displayLocalRect(rect, on: screen)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    static func capture(windowID: CGWindowID, includeShadow: Bool) async throws -> (CGImage, CGFloat) {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.ignoreShadowsSingleWindow = !includeShadow
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Snapshots every display, starting with the one under the mouse. Called the instant a
    /// hotkey fires, before Skreener shows or activates anything, so tooltips, hover states and
    /// open menus in other apps are still on screen.
    static func freezeAllScreens() async throws -> FrozenScreens {
        let content = try await shareableContent()
        let apps = ownApps(content)
        let mouseScreen = NSScreen.withMouse
        let ordered = [mouseScreen] + NSScreen.screens.filter { $0 != mouseScreen }
        var shots: [CGDirectDisplayID: FrozenScreens.Shot] = [:]
        for screen in ordered {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots[screen.displayID] = .init(image: image, scale: scale, frame: screen.frame)
        }
        return FrozenScreens(shots: shots)
    }

    /// Normal-layer windows of other apps, front to back.
    static func onScreenWindows() -> [PickableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  b.width >= 40, b.height >= 40 else { return nil }
            let frame = CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
            return PickableWindow(id: id, frame: frame, owner: d[kCGWindowOwnerName as String] as? String ?? "",
                                  title: d[kCGWindowName as String] as? String ?? "", pid: pid)
        }
    }
}

/// Full-resolution snapshots of every display taken when a capture shortcut fires.
/// Selections are cropped from these, so the result matches exactly what was frozen.
struct FrozenScreens {
    struct Shot {
        let image: CGImage
        let scale: CGFloat
        /// Screen frame in global AppKit coordinates at the time of the snapshot.
        let frame: CGRect
    }

    let shots: [CGDirectDisplayID: Shot]

    func image(for screen: NSScreen) -> CGImage? { shots[screen.displayID]?.image }

    /// Crops a global AppKit rect out of the snapshot of the display it lies on.
    func crop(_ rect: CGRect, on screen: NSScreen) -> (CGImage, CGFloat)? {
        guard let shot = shots[screen.displayID] else { return nil }
        let r = rect.intersection(shot.frame)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        // CGImage cropping uses a top-left origin in pixels.
        let pixels = CGRect(x: (r.minX - shot.frame.minX) * shot.scale,
                            y: (shot.frame.maxY - r.maxY) * shot.scale,
                            width: r.width * shot.scale,
                            height: r.height * shot.scale).integral
        return shot.image.cropping(to: pixels).map { ($0, shot.scale) }
    }

    /// Crops a window's frame out of the snapshot of the display holding most of it.
    func crop(window: PickableWindow) -> (CGImage, CGFloat)? {
        let screen = NSScreen.screens.max {
            area($0.frame.intersection(window.frame)) < area($1.frame.intersection(window.frame))
        }
        return screen.flatMap { crop(window.frame, on: $0) }
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
