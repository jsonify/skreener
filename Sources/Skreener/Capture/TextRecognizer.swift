import CoreGraphics
import Vision

enum TextRecognizer {
    /// Recognizes text with Vision and returns lines in reading order (top to bottom).
    static func recognize(_ image: CGImage, keepLineBreaks: Bool) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? [])
                .sorted { a, b in
                    abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                        ? a.boundingBox.midY > b.boundingBox.midY
                        : a.boundingBox.minX < b.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: keepLineBreaks ? "\n" : " ")
        }.value
    }
}
