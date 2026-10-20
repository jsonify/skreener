import AppKit
import UniformTypeIdentifiers

enum Sound {
    private static let captureSound: NSSound? = {
        let system = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: system, byReference: true) ?? NSSound(named: "Tink")
    }()

    /// Short, soft "tick" confirming text or a color was copied: ~50 ms of audible energy around
    /// 800–900 Hz with a fast exponential decay. Synthesized here, no audio asset needed.
    private static let ocrSound: NSSound? = NSSound(data: synthesizeTick())

    static func capture() {
        guard Settings.playSound else { return }
        captureSound?.stop()
        captureSound?.play()
    }

    private static let tickSound = NSSound(named: "Tink")

    static func tick() {
        guard Settings.playSound else { return }
        tickSound?.stop()
        tickSound?.play()
    }

    static func ocr() {
        guard Settings.playSound else { return }
        ocrSound?.stop()
        ocrSound?.play()
    }

    private static func synthesizeTick() -> Data {
        let sampleRate = 48_000.0
        let count = Int(sampleRate * 0.22)
        var samples = [Int16](repeating: 0, count: count)
        var phase1 = 0.0, phase2 = 0.0
        var noise: UInt32 = 0x2545F491
        for i in 0..<count {
            let t = Double(i) / sampleRate
            // Pitch glides from 900 Hz down to 820 Hz over the first 60 ms.
            let f = 820 + 80 * exp(-t / 0.02)
            phase1 += 2 * .pi * f / sampleRate
            phase2 += 2 * .pi * f * 1.5 / sampleRate
            // Brief hold, then a fast release, so it reads as a crisp tick rather than a ring.
            let attack = min(1, t / 0.003)
            let envelope = attack * (t < 0.03 ? 1 - t * 4 : 0.88 * exp(-(t - 0.03) / 0.012))
            noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
            let click = t < 0.002 ? (Double(noise) / Double(UInt32.max) - 0.5) * (1 - t / 0.002) * 0.3 : 0
            let value = (sin(phase1) + 0.3 * sin(phase2)) * envelope * 0.28 + click
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.forEach { append($0) }
        return data
    }
}

enum ImageIOHelper {
    /// PNG data with DPI metadata so other apps show the image at its point size.
    static func pngData(_ image: CGImage, pixelScale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * pixelScale
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return (image, max(1, CGFloat(dpi / 72).rounded()))
    }

    static func nsImage(_ image: CGImage, pixelScale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / pixelScale,
                                             height: CGFloat(image.height) / pixelScale))
    }
}

enum Clipboard {
    static func copy(image: CGImage, pixelScale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = ImageIOHelper.pngData(image, pixelScale: pixelScale) { item.setData(png, forType: .png) }
        if let tiff = ImageIOHelper.nsImage(image, pixelScale: pixelScale).tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func image() -> (CGImage, CGFloat)? {
        guard let ns = NSImage(pasteboard: NSPasteboard.general),
              let rep = ns.representations.first else { return nil }
        var rect = CGRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let scale = ns.size.width > 0 ? max(1, (CGFloat(rep.pixelsWide) / ns.size.width).rounded()) : 1
        return (cg, scale)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var withMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}
