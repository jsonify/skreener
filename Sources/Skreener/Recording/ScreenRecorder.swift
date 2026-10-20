import AppKit
import AVFoundation
import ScreenCaptureKit

/// Writes ScreenCaptureKit sample buffers to an MP4. Callbacks arrive on a background queue.
/// Pausing drops samples and shifts later timestamps back by the paused duration.
private final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var paused = false
    private var pauseStart = CMTime.invalid
    private var resumeAt = CMTime.zero
    private var offset = CMTime.zero

    init(url: URL, width: Int, height: Int, fps: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // H.264 tops out around 4096 px wide; use HEVC for larger (5K/6K) areas.
        let codec: AVVideoCodecType = (width > 4096 || height > 2304) ? .hevc : .h264
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(4_000_000, width * height * 6),
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        audio = systemAudio ? Self.audioInput(channels: 2) : nil
        mic = microphone ? Self.audioInput(channels: 1) : nil
        if let audio { writer.add(audio) }
        if let mic { writer.add(mic) }
        super.init()
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func pause() {
        lock.withLock {
            guard !paused else { return }
            paused = true
            pauseStart = Self.hostNow
        }
    }

    func resume() {
        lock.withLock {
            guard paused else { return }
            let now = Self.hostNow
            if pauseStart.isValid { offset = offset + (now - pauseStart) }
            resumeAt = now
            paused = false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        lock.lock()
        defer { lock.unlock() }
        // ScreenCaptureKit timestamps use the host clock, so they compare directly with pause times.
        guard !finished, !paused, buffer.presentationTimeStamp >= resumeAt else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let sample = retimed(buffer) else { return }
            if !started {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
            }
            if video.isReadyForMoreMediaData { video.append(sample) }
        case .audio:
            if started, let audio, audio.isReadyForMoreMediaData, let sample = retimed(buffer) { audio.append(sample) }
        default:
            if #available(macOS 15.0, *), type == .microphone, started, let mic, mic.isReadyForMoreMediaData,
               let sample = retimed(buffer) {
                mic.append(sample)
            }
        }
    }

    private func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Returns false if no frame was ever written.
    func finish() async -> Bool {
        let wasStarted: Bool = lock.withLock {
            finished = true
            return started
        }
        guard wasStarted else {
            writer.cancelWriting()
            return false
        }
        video.markAsFinished()
        audio?.markAsFinished()
        mic?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    func cancel() {
        lock.withLock { finished = true }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate {
    static let shared = ScreenRecorder()

    private enum State { case idle, countdown, recording, paused }
    private var state = State.idle {
        didSet { if (oldValue == .idle) != (state == .idle) { onStateChange?(state != .idle) } }
    }

    var isRecording: Bool { state != .idle }
    var isPaused: Bool { state == .paused }
    var onStateChange: ((Bool) -> Void)?

    private var request: CaptureRequest?
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var border: RecordingBorder?
    private var controls: RecordingControlBar?
    private var clicks: ClickHighlighter?
    private var keys: KeystrokeOverlay?
    private var camera: CameraOverlay?
    private var hidIcons = false
    private let sampleQueue = DispatchQueue(label: "skreener.recording", qos: .userInitiated)

    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    var elapsed: TimeInterval { accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0) }

    // MARK: Start

    func begin(_ request: CaptureRequest, countdown: Bool = true) async {
        guard state == .idle else { return }
        self.request = request
        state = .countdown

        if Settings.recordMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            Toast.show("Microphone access denied, recording without it", symbol: "mic.slash")
        }
        if Settings.cameraEnabled, !(await AVCaptureDevice.requestAccess(for: .video)) {
            Toast.show("Camera access denied, recording without it", symbol: "video.slash")
        }
        if Settings.showKeystrokes, !KeystrokeOverlay.hasPermission {
            KeystrokeOverlay.requestPermission()
            Toast.show("Allow Accessibility for Skreener to show keystrokes", symbol: "keyboard")
        }
        if Settings.hideIconsWhileRecording, !DesktopIconHider.shared.isHidden {
            DesktopIconHider.shared.hide()
            hidIcons = true
        }

        if countdown, !(await CountdownOverlay.run(seconds: Settings.captureTimer, over: request.rect)) {
            cleanUp()
            state = .idle
            return
        }

        do {
            try await startStream(request)
            accumulated = 0
            segmentStart = Date()
            state = .recording
        } catch {
            cleanUp()
            state = .idle
            Coordinator.shared.presentError(error)
        }
    }

    private func startStream(_ request: CaptureRequest) async throws {
        let isWindow = request.target == .window
        let micEnabled: Bool
        if #available(macOS 15.0, *) {
            micEnabled = Settings.recordMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            micEnabled = false
        }

        // Overlays that belong in the video are created first, then everything else of ours is excluded.
        var recordable: [NSWindow] = []
        if !isWindow {
            if Settings.highlightClicks {
                let c = ClickHighlighter(rect: request.rect)
                clicks = c
                recordable.append(c.window)
            }
            if Settings.showKeystrokes, KeystrokeOverlay.hasPermission {
                let k = KeystrokeOverlay(rect: request.rect)
                keys = k
                recordable.append(k.window)
            }
            if Settings.cameraEnabled, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
               let cam = CameraOverlay(rect: request.rect) {
                camera = cam
                recordable.append(cam.window)
            }
            if request.rect != request.screen.frame { border = RecordingBorder(rect: request.rect) }
        }
        controls = RecordingControlBar(around: request.rect, screen: request.screen, micOn: micEnabled)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let width: Int, height: Int
        if isWindow, let pw = request.window {
            guard let scWindow = content.windows.first(where: { $0.windowID == pw.id }) else { throw CaptureError.noWindow }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = CGFloat(filter.pointPixelScale)
            width = Int(filter.contentRect.width * scale) & ~1
            height = Int(filter.contentRect.height * scale) & ~1
        } else {
            guard let display = content.displays.first(where: { $0.displayID == request.screen.displayID }) else {
                throw CaptureError.noDisplay
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let keep = Set(recordable.map { CGWindowID($0.windowNumber) })
            let excluded = content.windows.filter { $0.owningApplication?.processID == pid && !keep.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = request.screen.backingScaleFactor
            config.sourceRect = ScreenCapturer.displayLocalRect(request.rect, on: request.screen)
            // Encoders need even dimensions.
            width = Int(request.rect.width * scale) & ~1
            height = Int(request.rect.height * scale) & ~1
        }

        let fps = Settings.recordFPS
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = Settings.recordCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = Settings.recordSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *), micEnabled {
            config.captureMicrophone = true
            if let id = Settings.microphoneID { config.microphoneCaptureDeviceID = id }
        }

        let writer = try RecordingWriter(url: HistoryStore.shared.newURL(ext: "mp4"), width: width, height: height, fps: fps,
                                         systemAudio: Settings.recordSystemAudio, microphone: micEnabled)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
        if Settings.recordSystemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleQueue) }
        if #available(macOS 15.0, *), micEnabled {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.writer = writer
    }

    // MARK: Controls

    func togglePause() {
        guard let writer else { return }
        switch state {
        case .recording:
            writer.pause()
            accumulated = elapsed
            segmentStart = nil
            state = .paused
        case .paused:
            writer.resume()
            segmentStart = Date()
            state = .recording
        default:
            break
        }
    }

    func stop() async {
        guard state == .recording || state == .paused, let writer else { return }
        let stream = self.stream
        cleanUp()
        state = .idle
        try? await stream?.stopCapture()
        guard await writer.finish() else {
            try? FileManager.default.removeItem(at: writer.url)
            Toast.show("Recording failed: no frames captured", symbol: "exclamationmark.triangle.fill")
            return
        }
        await deliver(writer.url)
    }

    func discard() async {
        guard state == .recording || state == .paused, let writer else { return }
        let stream = self.stream
        cleanUp()
        state = .idle
        try? await stream?.stopCapture()
        writer.cancel()
        Toast.show("Recording discarded", symbol: "trash")
    }

    func restart() async {
        guard let request, state == .recording || state == .paused, let writer else { return }
        let stream = self.stream
        cleanUp()
        state = .idle
        try? await stream?.stopCapture()
        writer.cancel()
        await begin(request, countdown: false)
    }

    private func deliver(_ mp4: URL) async {
        guard Settings.recordFormat == .gif else { return Coordinator.shared.didRecord(url: mp4) }
        Toast.show("Creating GIF…", symbol: "photo.stack")
        let gif = mp4.deletingPathExtension().appendingPathExtension("gif")
        do {
            try await GIFExporter.export(video: mp4, to: gif)
            try? FileManager.default.removeItem(at: mp4)
            Coordinator.shared.didRecord(url: gif)
        } catch {
            Toast.show("GIF export failed, kept the video", symbol: "exclamationmark.triangle.fill")
            Coordinator.shared.didRecord(url: mp4)
        }
    }

    private func cleanUp() {
        [border?.close, controls?.close, clicks?.close, keys?.close, camera?.close].forEach { $0?() }
        border = nil
        controls = nil
        clicks = nil
        keys = nil
        camera = nil
        stream = nil
        writer = nil
        segmentStart = nil
        if hidIcons {
            DesktopIconHider.shared.show()
            hidIcons = false
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            NSLog("Skreener: stream stopped: \(error)")
            await self.stop()
        }
    }
}

/// Click-through outline around the recorded area. It is excluded from the recording.
@MainActor
final class RecordingBorder {
    private let window: NSWindow

    init(rect: CGRect, color: NSColor = .systemRed) {
        let pad: CGFloat = 3
        window = NSWindow(contentRect: rect.insetBy(dx: -pad, dy: -pad), styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 3
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }
}

/// Converts a finished recording into a looping GIF with ImageIO.
enum GIFExporter {
    static func export(video: URL, to gif: URL, fps: Double = 15, maxSide: CGFloat = 960) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int(duration * fps))
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            if let image = try? result.image { CGImageDestinationAddImage(dest, image, frameProps) }
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
