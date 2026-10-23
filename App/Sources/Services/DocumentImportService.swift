import Foundation
import LernKern
import PDFKit
import UIKit
import Vision

/// Liest Dateien ein und extrahiert Text – PDF über PDFKit, gescannte Seiten und Fotos per
/// Texterkennung (Vision, auf dem Gerät), Office- und Textdateien über LernKern.
final class DocumentImportService {
    enum ImportError: LocalizedError {
        case tooLarge
        case locked
        case unreadable
        case tooManyPages(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Die Datei ist zu groß (max. 200 MB)."
            case .locked: return "Das PDF ist passwortgeschützt. Bitte eine ungeschützte Version importieren."
            case .unreadable: return "Die Datei konnte nicht gelesen werden."
            case .tooManyPages(let n): return "Das Dokument hat \(n) Seiten. Bitte in kleinere Teile aufteilen (max. 1.500 Seiten)."
            }
        }
    }

    static let maxBytes = 200 * 1024 * 1024
    static let maxPages = 1_500

    func extract(data: Data, kind: DocumentKind, progress: @escaping @Sendable (ProcessingState) -> Void) async throws -> ExtractedDocument {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        switch kind {
        case .pdf:
            return try await extractPDF(data: data, progress: progress)
        case .image, .scan:
            guard let image = UIImage(data: data) else { throw ImportError.unreadable }
            return try await recognize(images: [image], progress: progress)
        default:
            progress(ProcessingState(stage: .extractingText))
            return try await Task.detached(priority: .userInitiated) {
                try DocumentPipeline.extract(data: data, kind: kind)
            }.value
        }
    }

    func extractPDF(data: Data, progress: @escaping @Sendable (ProcessingState) -> Void) async throws -> ExtractedDocument {
        guard let document = PDFDocument(data: data) else { throw ImportError.unreadable }
        if document.isLocked { throw ImportError.locked }
        let count = document.pageCount
        guard count <= Self.maxPages else { throw ImportError.tooManyPages(count) }
        var pages: [String] = []
        var confidence: [Int: Double] = [:]
        pages.reserveCapacity(count)
        for index in 0..<count {
            progress(ProcessingState(stage: .extractingText, fraction: Double(index) / Double(max(count, 1)), detail: "Seite \(index + 1) von \(count)"))
            guard let page = document.page(at: index) else { pages.append(""); continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30 {
                pages.append(text)
            } else if let image = Self.render(page) {
                // Gescannte Seite: Texterkennung auf dem Gerät
                progress(ProcessingState(stage: .recognizingText, fraction: Double(index) / Double(max(count, 1)), detail: "Texterkennung Seite \(index + 1) von \(count)"))
                let result = try await Self.recognizeText(in: image)
                pages.append(result.text)
                confidence[index + 1] = result.confidence
            } else {
                pages.append(text)
            }
            if index % 20 == 19 { await Task.yield() }
        }
        return ExtractedDocument.fromPages(pages, confidence: confidence)
    }

    func recognize(images: [UIImage], progress: @escaping @Sendable (ProcessingState) -> Void) async throws -> ExtractedDocument {
        var pages: [String] = []
        var confidence: [Int: Double] = [:]
        for (index, image) in images.enumerated() {
            progress(ProcessingState(stage: .recognizingText, fraction: Double(index) / Double(max(images.count, 1)), detail: "Seite \(index + 1) von \(images.count)"))
            guard let cgImage = image.cgImage else { pages.append(""); continue }
            let result = try await Self.recognizeText(in: cgImage)
            pages.append(result.text)
            confidence[index + 1] = result.confidence
        }
        return ExtractedDocument.fromPages(pages, confidence: confidence)
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, 2_000 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }

    /// Texterkennung mit Vision (läuft lokal, keine Daten verlassen das Gerät).
    static func recognizeText(in image: CGImage) async throws -> (text: String, confidence: Double) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["de-DE", "en-US"]
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = (request.results ?? []).sorted { a, b in
                        // Von oben nach unten, dann von links nach rechts (Vision-Koordinaten beginnen unten links)
                        abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
                    }
                    var lines: [String] = []
                    var total: Float = 0
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        lines.append(candidate.string)
                        total += candidate.confidence
                    }
                    let confidence = lines.isEmpty ? 0 : Double(total) / Double(lines.count)
                    continuation.resume(returning: (lines.joined(separator: "\n"), confidence))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func kind(for url: URL) -> DocumentKind {
        DocumentKind.from(fileExtension: url.pathExtension)
    }
}
