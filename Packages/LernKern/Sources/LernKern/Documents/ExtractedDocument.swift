import Foundation

/// Ein Textblock aus einem Dokument mit Strukturinformation.
public struct ExtractedBlock: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case heading(Int)
        case paragraph
        case listItem
        case tableRow
        case note
    }

    public var kind: Kind
    public var text: String
    public var page: Int?

    public init(kind: Kind, text: String, page: Int?) {
        self.kind = kind
        self.text = text
        self.page = page
    }

    public var headingLevel: Int? {
        if case .heading(let level) = kind { return level }
        return nil
    }
}

/// Ergebnis der Textextraktion (vor Strukturierung und Analyse).
public struct ExtractedDocument: Sendable {
    public var blocks: [ExtractedBlock]
    public var pageCount: Int
    public var warnings: [ExtractionWarning]
    /// Erkennungssicherheit je Seite (nur bei Texterkennung/OCR).
    public var recognitionConfidence: [Int: Double]

    public init(blocks: [ExtractedBlock], pageCount: Int, warnings: [ExtractionWarning] = [], recognitionConfidence: [Int: Double] = [:]) {
        self.blocks = blocks
        self.pageCount = pageCount
        self.warnings = warnings
        self.recognitionConfidence = recognitionConfidence
    }

    public var characterCount: Int { blocks.reduce(0) { $0 + $1.text.count } }

    /// Erzeugt Blöcke aus seitenweise vorliegendem Text (PDF, OCR, Textdateien).
    /// Überschriften werden heuristisch erkannt (Nummerierung, "Kapitel", Großschreibung, Markdown).
    public static func fromPages(_ pages: [String], confidence: [Int: Double] = [:]) -> ExtractedDocument {
        var blocks: [ExtractedBlock] = []
        for (index, pageText) in pages.enumerated() {
            let page = index + 1
            var paragraph: [String] = []
            func flush() {
                let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(ExtractedBlock(kind: .paragraph, text: text, page: page)) }
                paragraph = []
            }
            for rawLine in pageText.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if let level = StructureDetector.headingLevel(of: line) {
                    flush()
                    blocks.append(ExtractedBlock(kind: .heading(level), text: StructureDetector.cleanHeading(line), page: page))
                } else if StructureDetector.isListItem(line) {
                    flush()
                    blocks.append(ExtractedBlock(kind: .listItem, text: StructureDetector.stripListMarker(line), page: page))
                } else if StructureDetector.isLikelyPageFurniture(line, pageNumber: page) {
                    continue
                } else {
                    // Silbentrennung am Zeilenende zusammenführen
                    if let last = paragraph.last, last.hasSuffix("-"), let first = line.first, first.isLowercase {
                        paragraph[paragraph.count - 1] = String(last.dropLast()) + line
                    } else {
                        paragraph.append(line)
                    }
                    // Satzende + kurze Zeile → Absatzende
                    if line.count < 50, line.hasSuffix(".") || line.hasSuffix(":") { flush() }
                }
            }
            flush()
        }
        return ExtractedDocument(blocks: blocks, pageCount: pages.count, recognitionConfidence: confidence)
    }
}
