import AppKit
import CoreImage

enum AnnotationTool: String, CaseIterable {
    case select, arrow, line, rectangle, filledRectangle, ellipse, text, highlighter, pen, pixelate, counter, crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .text: "textformat"
        case .highlighter: "highlighter"
        case .pen: "scribble"
        case .pixelate: "checkerboard.rectangle"
        case .counter: "1.circle"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Select (V)"
        case .arrow: "Arrow (A)"
        case .line: "Line (L)"
        case .rectangle: "Rectangle (R)"
        case .filledRectangle: "Filled Rectangle (F)"
        case .ellipse: "Ellipse (O)"
        case .text: "Text (T)"
        case .highlighter: "Highlighter (H)"
        case .pen: "Pen (P)"
        case .pixelate: "Pixelate (X)"
        case .counter: "Counter (N)"
        case .crop: "Crop (C) — Return to apply"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "o"
        case .text: "t"
        case .highlighter: "h"
        case .pen: "p"
        case .pixelate: "x"
        case .counter: "n"
        case .crop: "c"
        }
    }
}

/// One drawn object. Geometry is in image pixel space (bottom-left origin); sizes are in points
/// and get multiplied by the document's pixel scale when rendered.
final class Annotation {
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat
    var text = ""
    var fontSize: CGFloat = 22
    var number = 0

    init(tool: AnnotationTool, start: CGPoint, color: NSColor, lineWidth: CGFloat) {
        self.tool = tool
        self.start = start
        self.end = start
        self.color = color
        self.lineWidth = lineWidth
    }

    func copy() -> Annotation {
        let a = Annotation(tool: tool, start: start, color: color, lineWidth: lineWidth)
        a.end = end
        a.points = points
        a.text = text
        a.fontSize = fontSize
        a.number = number
        return a
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    func textAttributes(pixelScale: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3 * pixelScale
        shadow.shadowOffset = CGSize(width: 0, height: -pixelScale)
        return [
            .font: NSFont.systemFont(ofSize: fontSize * pixelScale, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    func counterRadius(pixelScale: CGFloat) -> CGFloat { (lineWidth * 1.5 + 11) * pixelScale }

    /// Area used for hit testing and the selection outline.
    func bounds(pixelScale ps: CGFloat) -> CGRect {
        switch tool {
        case .text:
            let size = (text as NSString).size(withAttributes: textAttributes(pixelScale: ps))
            return CGRect(x: start.x, y: start.y - size.height, width: size.width, height: size.height)
        case .counter:
            let r = counterRadius(pixelScale: ps)
            return CGRect(x: start.x - r, y: start.y - r, width: 2 * r, height: 2 * r)
        case .pen:
            guard let first = points.first else { return .null }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -lineWidth * ps, dy: -lineWidth * ps)
        default:
            return rect.insetBy(dx: -lineWidth * ps, dy: -lineWidth * ps)
        }
    }

    func hitTest(_ p: CGPoint, pixelScale ps: CGFloat) -> Bool {
        let slop = max(6, lineWidth) * ps
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= slop
        case .rectangle, .ellipse:
            let outer = rect.insetBy(dx: -slop, dy: -slop)
            let inner = rect.insetBy(dx: slop, dy: slop)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .pen:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= slop }
        default:
            return bounds(pixelScale: ps).contains(p)
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// The image being annotated plus its annotations and crop.
final class AnnotationDocument {
    let base: CGImage
    let pixelScale: CGFloat
    var annotations: [Annotation] = []
    var cropRect: CGRect?

    init(base: CGImage, pixelScale: CGFloat) {
        self.base = base
        self.pixelScale = pixelScale
    }

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    var visibleRect: CGRect { cropRect ?? imageRect }

    lazy var pixelated: CGImage = {
        let ci = CIImage(cgImage: base)
        let output = ci.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: 12 * pixelScale,
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
            .cropped(to: ci.extent)
        return CIContext().createCGImage(output, from: ci.extent) ?? base
    }()

    var nextCounterNumber: Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    /// Flattens the image, annotations and crop into a new bitmap.
    func render() -> CGImage? {
        let v = visibleRect.integral
        guard let ctx = CGContext(data: nil, width: Int(v.width), height: Int(v.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: -v.minX, y: -v.minY)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: imageRect)
        for a in annotations { AnnotationRenderer.draw(a, in: self, ctx: ctx) }
        return ctx.makeImage()
    }
}
