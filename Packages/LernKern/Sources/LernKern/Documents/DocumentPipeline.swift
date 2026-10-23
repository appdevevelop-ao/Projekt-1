import Foundation

/// Ergebnis der lokalen Dokumentanalyse.
public struct DocumentAnalysis: Sendable {
    public var sections: [DocumentSection]
    public var chunks: [SourceChunk]
    public var terms: [ExtractedTerm]
    public var warnings: [ExtractionWarning]
    public var pageCount: Int
    public var characterCount: Int

    public var duplicateShare: Double {
        chunks.isEmpty ? 0 : Double(chunks.filter { $0.duplicateOf != nil }.count) / Double(chunks.count)
    }
}

public enum DocumentPipelineError: Error, Equatable, LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String)
    case noText

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Dieses Format wird nicht unterstützt: \(s). Unterstützt werden PDF, Word (.docx), PowerPoint (.pptx), Text und Bilder."
        case .unreadable(let s): return s
        case .noText: return "In dieser Datei wurde kein lesbarer Text gefunden. Bei gescannten Seiten hilft die Texterkennung; bei Bildern ohne Text kann nichts ausgewertet werden."
        }
    }
}

/// Plattformunabhängiger Teil der Verarbeitungspipeline:
/// Datei lesen → Text extrahieren → Struktur erkennen → Abschnitte → Begriffe → Duplikate → Qualitätsprüfung.
/// (PDF-Text und OCR liefert die App über PDFKit/Vision und übergibt Seiten an `ExtractedDocument.fromPages`.)
public enum DocumentPipeline {
    public static func extract(data: Data, kind: DocumentKind) throws -> ExtractedDocument {
        switch kind {
        case .docx:
            do { return try OOXMLExtractor.extractDocx(data) } catch let e as OOXMLExtractor.OOXMLError {
                switch e {
                case .missingContent(let s), .unreadable(let s): throw DocumentPipelineError.unreadable(s)
                }
            }
        case .pptx:
            do { return try OOXMLExtractor.extractPptx(data) } catch let e as OOXMLExtractor.OOXMLError {
                switch e {
                case .missingContent(let s), .unreadable(let s): throw DocumentPipelineError.unreadable(s)
                }
            }
        case .text, .markdown:
            guard let text = decodeText(data) else { throw DocumentPipelineError.unreadable("Die Textdatei hat eine unbekannte Zeichenkodierung.") }
            // Seitenumbruch (Form Feed) respektieren, sonst eine "Seite" je ~3000 Zeichen für Quellenangaben
            let pages = text.contains("\u{0C}") ? text.components(separatedBy: "\u{0C}") : paginate(text, size: 3_000)
            return ExtractedDocument.fromPages(pages)
        case .pdf, .image, .scan:
            throw DocumentPipelineError.unsupportedFormat("\(kind.title) wird auf dem Gerät verarbeitet")
        case .other:
            throw DocumentPipelineError.unsupportedFormat("unbekannt")
        }
    }

    public static func analyze(_ document: ExtractedDocument, documentID: UUID, kind: DocumentKind, existingChunks: [SourceChunk]) throws -> DocumentAnalysis {
        guard document.characterCount >= 20 else { throw DocumentPipelineError.noText }
        let sections = Chunker.sections(from: document)
        var chunks = Chunker.chunks(documentID: documentID, sections: sections)
        chunks = Deduplicator.markDuplicates(newChunks: chunks, existing: existingChunks)
        let terms = TermExtractor.extract(from: chunks)
        var warnings = ExtractionQualityChecker.check(document, kind: kind)
        let duplicates = chunks.filter { $0.duplicateOf != nil }.count
        if duplicates > 0 {
            warnings.append(ExtractionWarning(kind: .duplicateContent, message: "\(duplicates) Abschnitt(e) sind bereits in anderen Unterlagen enthalten und werden nur einmal berücksichtigt."))
        }
        if terms.isEmpty {
            warnings.append(ExtractionWarning(kind: .noDefinitionsFound, message: "Es wurden keine eindeutigen Definitionen erkannt. Ohne KI-Dienst entstehen deshalb vor allem Lückentexte aus wichtigen Sätzen."))
        }
        return DocumentAnalysis(sections: sections, chunks: chunks, terms: terms, warnings: warnings, pageCount: document.pageCount, characterCount: document.characterCount)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    static func paginate(_ text: String, size: Int) -> [String] {
        var pages: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > size, !current.isEmpty {
                pages.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}
