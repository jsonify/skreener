import CoreImage
import CoreVideo
import Foundation
import Vision

/// Image-understanding helpers built on Vision: barcodes, sensitive-text detection, subject lifting.
enum VisionTools {
    // MARK: Barcodes / QR codes

    static func barcodes(in image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            var seen = Set<String>()
            return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
        }.value
    }

    // MARK: Sensitive text

    struct SensitiveMatch {
        let kind: String
        /// Bounding box in image pixel coordinates (bottom-left origin).
        let rect: CGRect
    }

    private static let patterns: [(String, NSRegularExpression)] = [
        ("email", #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
        ("card", #"\b(?:\d[ -]?){13,19}\b"#),
        ("aws-key", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        ("token", #"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{16,}\b"#),
        ("github-token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
        ("slack-token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        ("jwt", #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
        ("secret", #"\b[A-Fa-f0-9]{32,}\b|\b[A-Za-z0-9+/]{40,}={0,2}"#),
        ("ip", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        ("ssn", #"\b\d{3}-\d{2}-\d{4}\b"#),
    ].compactMap { name, pattern in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (name, $0) }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Finds emails, phone numbers, card numbers, API keys/tokens, IPs and similar secrets.
    static func sensitiveText(in image: CGImage) async throws -> [SensitiveMatch] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let size = CGSize(width: image.width, height: image.height)
            var matches: [SensitiveMatch] = []

            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let ns = text as NSString
                var ranges: [(String, NSRange)] = []
                for (kind, regex) in patterns {
                    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                        if let m { ranges.append((kind, m.range)) }
                    }
                }
                detector?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                    if let m { ranges.append(("phone", m.range)) }
                }
                for (kind, nsRange) in ranges {
                    guard kind != "card" || luhnValid(ns.substring(with: nsRange)),
                          let range = Range(nsRange, in: text),
                          let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    let r = VNImageRectForNormalizedRect(box, Int(size.width), Int(size.height)).insetBy(dx: -4, dy: -3).integral
                    // A card number can also look like a phone number; keep one box per region.
                    if !matches.contains(where: { $0.rect.intersection(r).width * $0.rect.intersection(r).height > 0.8 * r.width * r.height }) {
                        matches.append(SensitiveMatch(kind: kind, rect: r))
                    }
                }
            }
            return matches
        }.value
    }

    private static func luhnValid(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { acc, item in
            let (i, d) = item
            guard i % 2 == 1 else { return acc + d }
            let doubled = d * 2
            return acc + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    // MARK: Subject lifting

    /// Returns the foreground subject(s) on a transparent background, cropped to their extent.
    static func liftSubject(from image: CGImage) async throws -> CGImage? {
        try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }.value
    }
}

/// Pixel-level comparison of two same-sized captures, used by Watch Area.
enum ImageDiff {
    /// Fraction (0…1) of sampled pixels whose color changed noticeably.
    static func changedFraction(_ a: CGImage, _ b: CGImage) -> Double {
        // Downsample both to a small thumbnail so the check is cheap and ignores sub-pixel noise.
        let w = 160, h = max(1, Int(Double(a.height) / Double(max(a.width, 1)) * 160))
        guard let pa = pixels(a, w, h), let pb = pixels(b, w, h) else { return 1 }
        var changed = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            if d > 40 { changed += 1 }
        }
        return Double(changed) / Double(w * h)
    }

    private static func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buffer : nil
    }
}
