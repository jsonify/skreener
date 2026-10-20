import AppKit

enum AnnotationRenderer {
    static func draw(_ a: Annotation, in doc: AnnotationDocument, ctx: CGContext) {
        let ps = doc.pixelScale
        let lw = a.lineWidth * ps
        ctx.saveGState()
        defer { ctx.restoreGState() }

        func shadow() {
            ctx.setShadow(offset: CGSize(width: 0, height: -ps), blur: 4 * ps,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .arrow:
            shadow()
            ctx.setFillColor(a.color.cgColor)
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: lw))
            ctx.fillPath()

        case .line:
            shadow()
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()

        case .rectangle:
            shadow()
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw)
            let r = a.rect
            let radius = min(lw, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()

        case .filledRectangle:
            shadow()
            ctx.setFillColor(a.color.cgColor)
            ctx.fill(a.rect)

        case .ellipse:
            shadow()
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: a.rect)

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.fill(a.rect)

        case .pen:
            guard let first = a.points.first else { return }
            shadow()
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.move(to: first)
            a.points.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()

        case .pixelate:
            ctx.clip(to: a.rect)
            ctx.draw(doc.pixelated, in: doc.imageRect)

        case .counter:
            let r = a.counterRadius(pixelScale: ps)
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
            shadow()
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 * ps)
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.75 * ps, dy: 0.75 * ps))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: a.color.contrastingTextColor,
            ]
            drawString("\(a.number)", attrs: attrs, centeredIn: circle, ctx: ctx)

        case .text:
            let attrs = a.textAttributes(pixelScale: ps)
            let size = (a.text as NSString).size(withAttributes: attrs)
            let rect = CGRect(x: a.start.x, y: a.start.y - size.height, width: size.width + 2, height: size.height)
            withNSContext(ctx) { (a.text as NSString).draw(in: rect, withAttributes: attrs) }

        case .select, .crop:
            break
        }
    }

    /// Tapered shaft with a barbed head, built along the x axis and rotated into place.
    static func arrowPath(from p0: CGPoint, to p1: CGPoint, width w: CGFloat) -> CGPath {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let length = hypot(dx, dy)
        let path = CGMutablePath()
        guard length > 1 else { return path }
        let headLength = min(max(w * 4.5, 12), length * 0.6)
        let headWidth = max(w * 3.6, 10)
        let neck = length - headLength * 0.75
        let points = [
            CGPoint(x: 0, y: -w * 0.2),
            CGPoint(x: neck, y: -w / 2),
            CGPoint(x: length - headLength, y: -headWidth / 2),
            CGPoint(x: length, y: 0),
            CGPoint(x: length - headLength, y: headWidth / 2),
            CGPoint(x: neck, y: w / 2),
            CGPoint(x: 0, y: w * 0.2),
        ]
        let t = CGAffineTransform(translationX: p0.x, y: p0.y).rotated(by: atan2(dy, dx))
        path.addLines(between: points, transform: t)
        path.closeSubpath()
        return path
    }

    private static func drawString(_ s: String, attrs: [NSAttributedString.Key: Any], centeredIn r: CGRect, ctx: CGContext) {
        let size = (s as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2)
        withNSContext(ctx) { (s as NSString).draw(at: origin, withAttributes: attrs) }
    }

    private static func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSColor {
    var contrastingTextColor: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.65 ? .black : .white
    }
}
