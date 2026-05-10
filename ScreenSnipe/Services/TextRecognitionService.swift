import AppKit
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum TextRecognitionService {

    enum TextRecognitionError: LocalizedError {
        case noText
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .noText:
                return "No text found in this image."
            case .imageConversionFailed:
                return "Failed to process the image."
            }
        }
    }

    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw TextRecognitionError.imageConversionFailed
        }

        let result: String = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: TextRecognitionError.noText)
                    return
                }

                // Sort top-to-bottom (Vision uses bottom-left origin, so higher Y = higher on screen)
                let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

                let text = sorted.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                if text.isEmpty {
                    continuation.resume(throwing: TextRecognitionError.noText)
                } else {
                    continuation.resume(returning: text)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }

        return result
    }

    static func formatText(_ text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return await formatWithFoundationModels(text)
        }
        #endif
        return text
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func formatWithFoundationModels(_ text: String) async -> String {
        guard SystemLanguageModel.default.availability == .available else {
            return text
        }

        do {
            let session = LanguageModelSession(
                instructions: """
                You receive raw OCR text extracted from a screenshot. Interpret it the way a \
                human would read the screen. Fix OCR errors and typos. Recognize structure: \
                code blocks, tables, lists, headings, UI labels, and hierarchies. Reconstruct \
                the content in clean, readable plain text. Output only the result.
                """
            )
            let response = try await session.respond(to: text)
            return response.content
        } catch {
            return text
        }
    }
    #endif
}
