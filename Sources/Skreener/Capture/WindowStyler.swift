import AppKit

/// Places a captured window on a wallpaper or gradient backdrop with padding.
@MainActor
enum WindowStyler {
    static func apply(_ image: CGImage, pixelScale: CGFloat, screen: NSScreen) -> CGImage {
        let background = Settings.windowBackground
        guard background != .none else { return image }
        let fraction: [CGFloat] = [0.05, 0.09, 0.14]
        let pad = (CGFloat(max(image.width, image.height)) * fraction[min(2, max(0, Settings.windowPadding))]).rounded()
        let w = CGFloat(image.width) + pad * 2, h = CGFloat(image.height) + pad * 2
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high

        switch background {
        case .wallpaper:
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let (wall, _) = ImageIOHelper.load(url) {
                let s = max(w / CGFloat(wall.width), h / CGFloat(wall.height))
                let size = CGSize(width: CGFloat(wall.width) * s, height: CGFloat(wall.height) * s)
                ctx.draw(wall, in: CGRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height))
            } else {
                drawGradient(ctx, canvas, [NSColor(white: 0.3, alpha: 1), NSColor(white: 0.12, alpha: 1)])
            }
        case .sunset:
            drawGradient(ctx, canvas, [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.35, alpha: 1),
                                       NSColor(srgbRed: 0.93, green: 0.29, blue: 0.53, alpha: 1)])
        case .ocean:
            drawGradient(ctx, canvas, [NSColor(srgbRed: 0.26, green: 0.6, blue: 0.98, alpha: 1),
                                       NSColor(srgbRed: 0.45, green: 0.27, blue: 0.86, alpha: 1)])
        case .mint:
            drawGradient(ctx, canvas, [NSColor(srgbRed: 0.55, green: 0.93, blue: 0.75, alpha: 1),
                                       NSColor(srgbRed: 0.13, green: 0.62, blue: 0.62, alpha: 1)])
        case .graphite:
            drawGradient(ctx, canvas, [NSColor(white: 0.36, alpha: 1), NSColor(white: 0.1, alpha: 1)])
        case .none:
            break
        }

        // Window captures without the system shadow get a soft one so they don't look flat.
        if !Settings.windowShadow || Settings.windowAsShown {
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * pixelScale), blur: 28 * pixelScale,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    private static func drawGradient(_ ctx: CGContext, _ rect: CGRect, _ colors: [NSColor]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

/// Big translucent 3-2-1 countdown centered on the capture area. Escape cancels.
@MainActor
final class CountdownOverlay {
    /// Returns false if the user cancelled.
    static func run(seconds: Int, over rect: CGRect) async -> Bool {
        guard seconds > 0 else { return true }
        let overlay = CountdownOverlay(rect: rect)
        defer { overlay.close() }
        for n in stride(from: seconds, through: 1, by: -1) {
            overlay.show(n)
            Sound.tick()
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if overlay.cancelled { return false }
            }
        }
        return true
    }

    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?
    private(set) var cancelled = false

    private init(rect: CGRect) {
        let side: CGFloat = 160
        window = NSPanel(contentRect: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side + 30),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let circle = NSView(frame: CGRect(x: 0, y: 30, width: side, height: side))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        circle.layer?.cornerRadius = side / 2
        label.font = .systemFont(ofSize: 84, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (side - 100) / 2, width: side, height: 100)
        circle.addSubview(label)
        let hint = NSTextField(labelWithString: "Esc to cancel")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 2, width: side, height: 18)
        hint.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black; return s }()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side + 30))
        root.addSubview(circle)
        root.addSubview(hint)
        window.contentView = root
        window.orderFrontRegardless()
        // Global: Skreener isn't the active app during the countdown.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancelled = true } }
        }
    }

    private func show(_ n: Int) {
        label.stringValue = "\(n)"
        label.alphaValue = 0.3
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; label.animator().alphaValue = 1 }
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        window.orderOut(nil)
    }
}
