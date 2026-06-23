import Foundation
import CoreGraphics
import ImageIO
import Vision

enum ComputerUseScreenshotTextRecognition {
    static func recognizedText(from screenshot: ComputerUseScreenshotObservation?) async -> String? {
        guard let imageDataURL = screenshot?.imageDataURL else { return nil }
        return await recognizedText(fromImageDataURL: imageDataURL)
    }

    static func recognizedText(fromImageDataURL imageDataURL: String) async -> String? {
        guard let image = image(fromImageDataURL: imageDataURL) else { return nil }
        do {
            return try await recognizeText(in: image)
        } catch {
            return nil
        }
    }

    private static func image(fromImageDataURL imageDataURL: String) -> CGImage? {
        let base64: String
        if let comma = imageDataURL.firstIndex(of: ",") {
            base64 = String(imageDataURL[imageDataURL.index(after: comma)...])
        } else {
            base64 = imageDataURL
        }
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let text = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.usesCPUOnly = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
