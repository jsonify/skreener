import AppKit

/// Polls a screen area and captures it automatically the moment its contents change,
/// e.g. a build finishing, a download completing, or a chat reply arriving.
@MainActor
final class AreaWatcher {
    static let shared = AreaWatcher()

    private(set) var isWatching = false
    private var timer: Timer?
    private var baseline: CGImage?
    private var rect: CGRect = .zero
    private var screen: NSScreen?
    private var border: RecordingBorder?
    private var checking = false
    /// Share of downsampled pixels that must change before it counts (ignores blinking cursors).
    private let threshold = 0.004

    func start(rect: CGRect, screen: NSScreen) async throws {
        stop()
        let (image, _) = try await ScreenCapturer.capture(rect: rect, on: screen)
        baseline = image
        self.rect = rect
        self.screen = screen
        isWatching = true
        border = RecordingBorder(rect: rect, color: .systemBlue)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        border?.close()
        border = nil
        baseline = nil
        isWatching = false
    }

    private func check() {
        guard isWatching, !checking, let screen, let baseline else { return }
        checking = true
        Task {
            defer { checking = false }
            guard let (image, scale) = try? await ScreenCapturer.capture(rect: rect, on: screen), isWatching else { return }
            if ImageDiff.changedFraction(baseline, image) > threshold {
                stop()
                Coordinator.shared.didCapture(image, pixelScale: scale)
                Toast.show("Change detected: area captured", symbol: "eye.trianglebadge.exclamationmark")
            }
        }
    }
}
