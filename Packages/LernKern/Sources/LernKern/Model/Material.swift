import Foundation

public enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case pdf, docx, pptx, text, markdown, image, scan, other

    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word"
        case .pptx: return "PowerPoint"
        case .text: return "Text"
        case .markdown: return "Markdown"
        case .image: return "Bild"
        case .scan: return "Scan"
        case .other: return "Datei"
        }
    }

    public static func from(fileExtension ext: String) -> DocumentKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "pptx": return .pptx
        case "txt", "text", "rtf": return .text
        case "md", "markdown": return .markdown
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp": return .image
        default: return .other
        }
    }
}

/// Lernmaterial oder verbindliche Prüfungsvorgabe (Lehrplan/Themenliste).
public enum DocumentRole: String, Codable, Sendable {
    case material
    case syllabus
}

public enum ProcessingStage: String, Codable, Sendable {
    case queued
    case reading
    case extractingText
    case recognizingText
    case structuring
    case analyzing
    case checkingQuality
    case completed
    case failed

    public var title: String {
        switch self {
        case .queued: return "Wartet"
        case .reading: return "Datei wird gelesen"
        case .extractingText: return "Text wird extrahiert"
        case .recognizingText: return "Texterkennung (OCR)"
        case .structuring: return "Kapitel und Abschnitte werden erkannt"
        case .analyzing: return "Lernziele und Begriffe werden bestimmt"
        case .checkingQuality: return "Vollständigkeit wird geprüft"
        case .completed: return "Fertig"
        case .failed: return "Fehlgeschlagen"
        }
    }
}

public struct ProcessingState: Codable, Hashable, Sendable {
    public var stage: ProcessingStage
    public var fraction: Double?
    public var detail: String?
    public var errorMessage: String?

    public init(stage: ProcessingStage, fraction: Double? = nil, detail: String? = nil, errorMessage: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
        self.errorMessage = errorMessage
    }

    public var isFinished: Bool { stage == .completed || stage == .failed }
}

public struct ExtractionWarning: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case emptyPage
        case lowRecognitionConfidence
        case garbledText
        case unsupportedContent
        case truncated
        case duplicateContent
        case noDefinitionsFound
        case analysisIncomplete
    }

    public var kind: Kind
    public var page: Int?
    public var message: String

    public init(kind: Kind, page: Int? = nil, message: String) {
        self.kind = kind
        self.page = page
        self.message = message
    }
}

/// Woher Themen und Lernziele eines Dokuments stammen.
public enum AnalysisSource: String, Codable, Sendable {
    case none
    case local
    case ai
}

public struct SourceDocument: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var fileName: String
    public var kind: DocumentKind
    public var role: DocumentRole
    public var importedAt: Date
    public var pageCount: Int
    public var characterCount: Int
    public var state: ProcessingState
    public var warnings: [ExtractionWarning]
    /// Dateiname der lokal gespeicherten Kopie im App-Container.
    public var storedFileName: String?
    public var analysisSource: AnalysisSource

    public init(
        id: UUID = UUID(),
        examID: UUID,
        fileName: String,
        kind: DocumentKind,
        role: DocumentRole = .material,
        importedAt: Date = Date(),
        pageCount: Int = 0,
        characterCount: Int = 0,
        state: ProcessingState = ProcessingState(stage: .queued),
        warnings: [ExtractionWarning] = [],
        storedFileName: String? = nil,
        analysisSource: AnalysisSource = .none
    ) {
        self.id = id
        self.examID = examID
        self.fileName = fileName
        self.kind = kind
        self.role = role
        self.importedAt = importedAt
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.state = state
        self.warnings = warnings
        self.storedFileName = storedFileName
        self.analysisSource = analysisSource
    }
}

/// Ein zusammenhängender Textabschnitt eines Dokuments mit Quellenangabe.
public struct SourceChunk: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var index: Int
    public var sectionPath: [String]
    public var pageStart: Int?
    public var pageEnd: Int?
    public var text: String
    /// Gesetzt, wenn dieser Abschnitt (nahezu) identisch mit einem anderen ist.
    public var duplicateOf: UUID?

    public init(id: UUID = UUID(), documentID: UUID, index: Int, sectionPath: [String], pageStart: Int?, pageEnd: Int?, text: String, duplicateOf: UUID? = nil) {
        self.id = id
        self.documentID = documentID
        self.index = index
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.text = text
        self.duplicateOf = duplicateOf
    }

    public var pageLabel: String? {
        guard let start = pageStart else { return nil }
        if let end = pageEnd, end != start { return "S. \(start)–\(end)" }
        return "S. \(start)"
    }
}

/// Verweis auf die Stelle im Lernmaterial, auf der eine Information beruht.
public struct SourceReference: Codable, Hashable, Sendable {
    public var documentID: UUID
    public var chunkID: UUID
    public var page: Int?
    /// Wörtliches Zitat aus dem Material (wurde gegen den Text geprüft).
    public var quote: String?

    public init(documentID: UUID, chunkID: UUID, page: Int?, quote: String?) {
        self.documentID = documentID
        self.chunkID = chunkID
        self.page = page
        self.quote = quote
    }
}
