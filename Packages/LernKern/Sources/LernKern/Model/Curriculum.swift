import Foundation

public enum Importance: String, Codable, CaseIterable, Sendable {
    case core
    case standard
    case peripheral

    public var weight: Double {
        switch self {
        case .core: return 1.5
        case .standard: return 1.0
        case .peripheral: return 0.5
        }
    }

    public var title: String {
        switch self {
        case .core: return "Kernthema"
        case .standard: return "Standard"
        case .peripheral: return "Randthema"
        }
    }
}

/// Herkunft eines Inhalts. KI-Vorschläge werden getrennt von bestätigten Daten geführt.
public enum ContentOrigin: String, Codable, Sendable {
    case ai
    case local
    case user
    case syllabus

    public var title: String {
        switch self {
        case .ai: return "KI-Vorschlag"
        case .local: return "Aus deinen Unterlagen erkannt"
        case .user: return "Von dir angelegt"
        case .syllabus: return "Aus dem Lehrplan"
        }
    }
}

public enum ReviewStatus: String, Codable, Sendable {
    case suggested
    case confirmed
    case rejected
}

public enum BloomLevel: String, Codable, CaseIterable, Sendable {
    case remember
    case understand
    case apply
    case analyze

    public var title: String {
        switch self {
        case .remember: return "Wissen"
        case .understand: return "Verstehen"
        case .apply: return "Anwenden"
        case .analyze: return "Analysieren"
        }
    }

    /// Grobe Erstlernzeit in Minuten (wird später an das eigene Tempo angepasst).
    public var baseLearningMinutes: Int {
        switch self {
        case .remember: return 8
        case .understand: return 12
        case .apply: return 18
        case .analyze: return 22
        }
    }
}

public struct Topic: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var title: String
    public var summary: String
    public var order: Int
    public var importance: Importance
    /// Bekannter Anteil an der Prüfung (0…1), z. B. aus einem Lehrplan.
    public var examWeight: Double?
    /// 1 = leicht, 2 = mittel, 3 = schwer.
    public var difficulty: Int
    public var prerequisiteTopicIDs: [UUID]
    public var origin: ContentOrigin
    public var reviewStatus: ReviewStatus
    public var sourceChunkIDs: [UUID]
    /// `false`, wenn das Thema nur im Lehrplan steht, aber kein Material dazu vorliegt.
    public var hasMaterial: Bool

    public init(
        id: UUID = UUID(), examID: UUID, title: String, summary: String = "", order: Int,
        importance: Importance = .standard, examWeight: Double? = nil, difficulty: Int = 2,
        prerequisiteTopicIDs: [UUID] = [], origin: ContentOrigin, reviewStatus: ReviewStatus = .suggested,
        sourceChunkIDs: [UUID] = [], hasMaterial: Bool = true
    ) {
        self.id = id
        self.examID = examID
        self.title = title
        self.summary = summary
        self.order = order
        self.importance = importance
        self.examWeight = examWeight
        self.difficulty = min(max(difficulty, 1), 3)
        self.prerequisiteTopicIDs = prerequisiteTopicIDs
        self.origin = origin
        self.reviewStatus = reviewStatus
        self.sourceChunkIDs = sourceChunkIDs
        self.hasMaterial = hasMaterial
    }

    public var isActive: Bool { reviewStatus != .rejected }
}

public struct LearningObjective: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var topicID: UUID
    public var title: String
    public var detail: String
    public var bloom: BloomLevel
    public var keyTerms: [String]
    public var sourceChunkIDs: [UUID]
    public var importance: Importance
    public var origin: ContentOrigin
    public var reviewStatus: ReviewStatus
    public var estimatedMinutes: Int
    public var order: Int

    public init(
        id: UUID = UUID(), examID: UUID, topicID: UUID, title: String, detail: String = "",
        bloom: BloomLevel = .understand, keyTerms: [String] = [], sourceChunkIDs: [UUID] = [],
        importance: Importance = .standard, origin: ContentOrigin, reviewStatus: ReviewStatus = .suggested,
        estimatedMinutes: Int? = nil, order: Int = 0
    ) {
        self.id = id
        self.examID = examID
        self.topicID = topicID
        self.title = title
        self.detail = detail
        self.bloom = bloom
        self.keyTerms = keyTerms
        self.sourceChunkIDs = sourceChunkIDs
        self.importance = importance
        self.origin = origin
        self.reviewStatus = reviewStatus
        self.estimatedMinutes = estimatedMinutes ?? bloom.baseLearningMinutes
        self.order = order
    }

    public var isActive: Bool { reviewStatus != .rejected }
}

/// Ein Fachbegriff, eine Definition oder Formel mit wörtlichem Beleg aus dem Material.
public struct KeyTerm: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case definition, formula, fact }

    public var id: UUID
    public var examID: UUID
    public var topicID: UUID?
    public var objectiveID: UUID?
    public var term: String
    public var definition: String
    public var kind: Kind
    public var source: SourceReference

    public init(id: UUID = UUID(), examID: UUID, topicID: UUID? = nil, objectiveID: UUID? = nil, term: String, definition: String, kind: Kind = .definition, source: SourceReference) {
        self.id = id
        self.examID = examID
        self.topicID = topicID
        self.objectiveID = objectiveID
        self.term = term
        self.definition = definition
        self.kind = kind
        self.source = source
    }
}
