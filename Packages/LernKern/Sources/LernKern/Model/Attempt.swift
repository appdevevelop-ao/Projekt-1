import Foundation

public enum AttemptContext: String, Codable, Sendable {
    case practice
    case check
    case review
    case simulation
}

public enum GradingConfidence: String, Codable, Sendable {
    case low, medium, high
}

/// Wie eine Antwort bewertet wurde. Bestimmt, wie stark sie als Beleg zählt.
public struct GradingMethod: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case automatic, ai, selfAssessed }

    public var kind: Kind
    public var confidence: GradingConfidence

    public init(kind: Kind, confidence: GradingConfidence = .high) {
        self.kind = kind
        self.confidence = confidence
    }

    public static let automatic = GradingMethod(kind: .automatic, confidence: .high)
    public static let selfAssessed = GradingMethod(kind: .selfAssessed, confidence: .low)

    /// Gewicht als Lernbeleg (0…1). Selbsteinschätzungen und unsichere Bewertungen zählen weniger.
    public var evidenceWeight: Double {
        switch kind {
        case .automatic: return 1.0
        case .selfAssessed: return 0.5
        case .ai:
            switch confidence {
            case .high: return 1.0
            case .medium: return 0.8
            case .low: return 0.5
            }
        }
    }
}

public struct AttemptResponse: Codable, Hashable, Sendable {
    public var selectedIndices: [Int]?
    public var text: String?
    /// Zuordnungsaufgaben: Index der rechten Seite für jedes linke Element.
    public var matching: [Int]?
    /// Selbsteinschätzung 0…1 (nur ohne automatische/KI-Bewertung).
    public var selfRating: Double?

    public init(selectedIndices: [Int]? = nil, text: String? = nil, matching: [Int]? = nil, selfRating: Double? = nil) {
        self.selectedIndices = selectedIndices
        self.text = text
        self.matching = matching
        self.selfRating = selfRating
    }
}

public struct Attempt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var objectiveID: UUID
    public var questionID: UUID
    public var sessionID: UUID?
    public var answeredAt: Date
    public var durationSeconds: Double
    public var response: AttemptResponse
    /// Ergebnis 0…1 (Teilpunkte möglich).
    public var score: Double
    public var grading: GradingMethod
    public var usedHint: Bool
    public var context: AttemptContext
    /// Frage wurde zum ersten Mal gesehen – aussagekräftig für neue, unbekannte Aufgaben.
    public var wasFirstExposure: Bool
    /// Ungültig, z. B. weil die Frage als fehlerhaft gemeldet wurde.
    public var isVoided: Bool
    /// Bei Multiple Choice: Text der falsch gewählten Option (für den Schwächen-Detektor).
    public var chosenDistractor: String?
    /// Maschinenlesbare Fehlerhinweise, z. B. "unitMissing".
    public var feedbackTags: [String]

    public init(
        id: UUID = UUID(), examID: UUID, objectiveID: UUID, questionID: UUID, sessionID: UUID? = nil,
        answeredAt: Date, durationSeconds: Double, response: AttemptResponse = AttemptResponse(),
        score: Double, grading: GradingMethod = .automatic, usedHint: Bool = false,
        context: AttemptContext = .practice, wasFirstExposure: Bool = false, isVoided: Bool = false,
        chosenDistractor: String? = nil, feedbackTags: [String] = []
    ) {
        self.id = id
        self.examID = examID
        self.objectiveID = objectiveID
        self.questionID = questionID
        self.sessionID = sessionID
        self.answeredAt = answeredAt
        self.durationSeconds = durationSeconds
        self.response = response
        self.score = min(max(score, 0), 1)
        self.grading = grading
        self.usedHint = usedHint
        self.context = context
        self.wasFirstExposure = wasFirstExposure
        self.isVoided = isVoided
        self.chosenDistractor = chosenDistractor
        self.feedbackTags = feedbackTags
    }

    public var isCorrect: Bool { score >= 0.8 }
    public var isSuccess: Bool { score >= 0.6 }
}
