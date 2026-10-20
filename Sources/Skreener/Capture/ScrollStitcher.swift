import CoreGraphics
import Foundation
import Vision

enum ScrollAxis { case vertical, horizontal }

/// One captured frame reduced to what matching needs: a hash and a coarse luminance signature
/// per line along the scroll axis (rows when scrolling vertically, columns horizontally).
struct ScrollFrame {
    let image: CGImage
    let lines: [UInt64]
    let uniform: [Bool]
    /// 16 block-average luminance values per line, for tolerant (non pixel-exact) matching.
    let signatures: [Float]
    static let blocks = 16

    var count: Int { lines.count }

    /// `ignoreEdge` pixels at the trailing edge (overlay scroll bars) are left out of hashes.
    init?(image: CGImage, axis: ScrollAxis, ignoreEdge: Int) {
        let w = image.width, h = image.height
        guard w > 8, h > 8,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt32.self, capacity: w * h)
        self.image = image

        // Line i runs across the axis. In memory row 0 is the top row of the image.
        let n = axis == .vertical ? h : w
        let span = axis == .vertical ? w : h
        let end = max(span / 2, span - ignoreEdge)
        var lines = [UInt64](repeating: 0, count: n)
        var uniform = [Bool](repeating: true, count: n)
        var sigs = [Float](repeating: 0, count: n * Self.blocks)
        let blockLen = max(1, end / Self.blocks)

        for i in 0..<n {
            var hash: UInt64 = 0xcbf29ce484222325
            let first = axis == .vertical ? px[i * w] : px[i]
            var same = true
            var blockSum: UInt32 = 0, blockIndex = 0, inBlock = 0
            for k in 0..<end {
                let p = axis == .vertical ? px[i * w + k] : px[k * w + i]
                hash = (hash ^ UInt64(p)) &* 0x100000001b3
                if p != first { same = false }
                // Luminance approximation from RGBA bytes.
                blockSum &+= (p & 0xff) &+ ((p >> 8) & 0xff) &* 2 &+ ((p >> 16) & 0xff)
                inBlock += 1
                if inBlock == blockLen, blockIndex < Self.blocks {
                    sigs[i * Self.blocks + blockIndex] = Float(blockSum) / Float(blockLen * 4)
                    blockIndex += 1
                    blockSum = 0
                    inBlock = 0
                }
            }
            lines[i] = hash
            uniform[i] = same
        }
        self.lines = lines
        self.uniform = uniform
        signatures = sigs
    }

    /// Mean absolute luminance difference between line `a` here and line `b` in `other`.
    func signatureDistance(_ a: Int, _ other: ScrollFrame, _ b: Int) -> Float {
        var sum: Float = 0
        let ia = a * Self.blocks, ib = b * Self.blocks
        for k in 0..<Self.blocks { sum += abs(signatures[ia + k] - other.signatures[ib + k]) }
        return sum / Float(Self.blocks)
    }
}

/// Matches successive frames of scrolling content and stitches the new lines into one long image.
///
/// Works in "content coordinates": `offset` is how far the latest matched frame has scrolled
/// from the first one, and `contentEnd` is the first content line not yet appended. Sticky
/// headers (static lines at the start) and footers (static lines at the end) are detected per
/// match, so they appear once instead of repeating.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case started
        case appended(Int)
        case noMovement
        /// The content moved further than one frame of overlap, or changed too much to match.
        case tooFast
        /// The user scrolled back the other way.
        case backwards
        case tooLarge
    }

    let axis: ScrollAxis
    let ignoreEdge: Int
    let maxLength: Int

    private var reference: ScrollFrame?
    private var pieces: [CGImage] = []
    private var footerPiece: CGImage?
    private var offset = 0
    private var contentEnd = 0
    private var started = false
    private(set) var length = 0
    private var lastAppended = 0

    init(axis: ScrollAxis, ignoreEdge: Int, maxLength: Int = 32_000) {
        self.axis = axis
        self.ignoreEdge = ignoreEdge
        self.maxLength = maxLength
    }

    /// Stitched pieces so far; they only ever grow, so previews can cache them.
    var committedPieces: [CGImage] { pieces }
    /// What follows the pieces: the sticky footer / static tail, or the whole first frame before any match.
    var tail: CGImage? { pieces.isEmpty ? reference?.image : footerPiece }

    func add(_ image: CGImage) -> Outcome {
        guard let frame = ScrollFrame(image: image, axis: axis, ignoreEdge: ignoreEdge) else { return .noMovement }
        guard let prev = reference else {
            reference = frame
            length = frame.count
            started = true
            return .started
        }

        switch Self.match(prev, frame, axis: axis) {
        case .none(let backwards):
            return backwards ? .backwards : .tooFast
        case .some(0, _, _):
            return .noMovement
        case .some(let d, let header, let footer):
            let n = frame.count
            if pieces.isEmpty {
                // First match: the whole first frame above its footer is the start of the content.
                pieces.append(Self.crop(prev.image, axis: axis, from: 0, to: n - footer))
                contentEnd = n - footer
            }
            offset += d
            let start = max(header, contentEnd - offset)
            let end = n - footer
            if end > start {
                pieces.append(Self.crop(frame.image, axis: axis, from: start, to: end))
                contentEnd = offset + end
            }
            // The tail (sticky footer, or static blank lines) starts where appended content ends,
            // so nothing is duplicated when the static region already overlaps appended content.
            let tailStart = max(end, contentEnd - offset)
            footerPiece = tailStart < n ? Self.crop(frame.image, axis: axis, from: tailStart, to: n) : nil
            reference = frame
            length = contentEnd + (n - tailStart)
            lastAppended = max(0, end - start)
            return length > maxLength ? .tooLarge : .appended(lastAppended)
        }
    }

    /// The stitched image so far (the first frame alone if nothing matched yet).
    func result() -> CGImage? {
        guard let first = reference?.image ?? pieces.first else { return nil }
        let parts = pieces.isEmpty ? [first] : pieces + (footerPiece.map { [$0] } ?? [])
        let along = parts.reduce(0) { $0 + (axis == .vertical ? $1.height : $1.width) }
        let across = axis == .vertical ? first.width : first.height
        let w = axis == .vertical ? across : along
        let h = axis == .vertical ? along : across
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var cursor = 0
        for part in parts {
            switch axis {
            case .vertical:
                // CGContext has a bottom-left origin; stack pieces from the top down.
                cursor += part.height
                ctx.draw(part, in: CGRect(x: 0, y: h - cursor, width: part.width, height: part.height))
            case .horizontal:
                ctx.draw(part, in: CGRect(x: cursor, y: 0, width: part.width, height: part.height))
                cursor += part.width
            }
        }
        return ctx.makeImage()
    }

    // MARK: Matching

    enum Match {
        case none(backwards: Bool)
        case some(d: Int, header: Int, footer: Int)
    }

    /// Finds `d` such that line i of `new` shows what line i + d of `prev` showed.
    static func match(_ prev: ScrollFrame, _ new: ScrollFrame, axis: ScrollAxis) -> Match {
        let P = prev.lines, N = new.lines
        let n = min(P.count, N.count)
        var header = 0
        while header < n, P[header] == N[header] { header += 1 }
        if header == n { return .some(d: 0, header: 0, footer: 0) }
        var footer = 0
        while footer < n - header, P[n - 1 - footer] == N[n - 1 - footer] { footer += 1 }

        // Exact matching: distinctive lines of the new frame vote for an offset.
        var index: [UInt64: [Int]] = [:]
        for j in header..<(n - footer) where !prev.uniform[j] { index[P[j], default: []].append(j) }
        var votes: [Int: Int] = [:]
        var backVotes = 0
        for i in header..<(n - footer) where !new.uniform[i] {
            guard let js = index[N[i]], js.count <= 3 else { continue }
            for j in js {
                if j > i { votes[j - i, default: 0] += 1 } else if j < i { backVotes += 1 }
            }
        }
        // Try offsets from most to least voted; blank lines match at any offset, so only lines
        // with content count as evidence.
        for (d, count) in votes.sorted(by: { $0.value > $1.value }).prefix(3) where count >= 3 {
            if verifyExact(prev, new, d: d, header: header, footer: footer, n: n) {
                return .some(d: d, header: header, footer: footer)
            }
        }

        // Tolerant fallback (sub-pixel text rendering, fades): Vision registration proposes an
        // offset, block signatures confirm it; a coarse signature search is the last resort.
        // Static header/footer detection must be tolerant here too, since nothing is pixel-identical.
        var softHeader = 0
        while softHeader < n, new.signatureDistance(softHeader, prev, softHeader) < 1 { softHeader += 1 }
        if softHeader == n { return .some(d: 0, header: 0, footer: 0) }
        var softFooter = 0
        while softFooter < n - softHeader, new.signatureDistance(n - 1 - softFooter, prev, n - 1 - softFooter) < 1 { softFooter += 1 }
        if let d = visionOffset(prev, new, axis: axis, header: softHeader, footer: softFooter, n: n)
            ?? signatureSearch(prev, new, header: softHeader, footer: softFooter, n: n) {
            return .some(d: d, header: softHeader, footer: softFooter)
        }
        return .none(backwards: backVotes >= 6 && backVotes > (votes.values.max() ?? 0) * 2)
    }

    private static func verifyExact(_ prev: ScrollFrame, _ new: ScrollFrame, d: Int, header: Int, footer: Int, n: Int) -> Bool {
        let hi = n - footer - d
        guard hi - header >= 8 else { return false }
        var ok = 0, considered = 0
        for i in header..<hi where !(new.uniform[i] && prev.uniform[i + d]) {
            considered += 1
            if new.lines[i] == prev.lines[i + d] { ok += 1 }
        }
        return considered >= 6 && Double(ok) / Double(considered) >= 0.85
    }

    private static func signatureCost(_ prev: ScrollFrame, _ new: ScrollFrame, d: Int, header: Int, footer: Int,
                                      n: Int, step: Int = 1) -> Float? {
        let hi = n - footer - d
        // Approximate matches need a meaningful overlap (a fifth of the moving region) to be trusted.
        guard d > 0, hi - header >= max(40, (n - header - footer) / 5) else { return nil }
        var total: Float = 0, count = 0
        var i = header
        while i < hi {
            total += new.signatureDistance(i, prev, i + d)
            count += 1
            i += step
        }
        return total / Float(count)
    }

    private static func visionOffset(_ prev: ScrollFrame, _ new: ScrollFrame, axis: ScrollAxis,
                                     header: Int, footer: Int, n: Int) -> Int? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: new.image)
        guard (try? VNImageRequestHandler(cgImage: prev.image).perform([request])) != nil,
              let t = request.results?.first?.alignmentTransform else { return nil }
        let shift = Int((axis == .vertical ? t.ty : t.tx).rounded())
        // Only the magnitude is used; the signature check confirms the content moved forward by it.
        let d = abs(shift)
        guard let cost = signatureCost(prev, new, d: d, header: header, footer: footer, n: n), cost < 3 else { return nil }
        return d
    }

    private static func signatureSearch(_ prev: ScrollFrame, _ new: ScrollFrame, header: Int, footer: Int, n: Int) -> Int? {
        var best: (d: Int, cost: Float)?
        let maxD = n - footer - header - 16
        guard maxD > 0 else { return nil }
        for d in 1...maxD {
            guard let cost = signatureCost(prev, new, d: d, header: header, footer: footer, n: n, step: 3) else { continue }
            if cost < (best?.cost ?? .infinity) { best = (d, cost) }
        }
        guard let best, best.cost < 2,
              let fine = signatureCost(prev, new, d: best.d, header: header, footer: footer, n: n), fine < 2.5 else { return nil }
        return best.d
    }

    /// Copies lines [from, to) along the axis into a standalone image (so frames can be released).
    static func crop(_ image: CGImage, axis: ScrollAxis, from: Int, to: Int) -> CGImage {
        let rect = axis == .vertical
            ? CGRect(x: 0, y: from, width: image.width, height: to - from)
            : CGRect(x: from, y: 0, width: to - from, height: image.height)
        guard rect.width > 0, rect.height > 0, let cropped = image.cropping(to: rect),
              let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage() ?? cropped
    }
}
