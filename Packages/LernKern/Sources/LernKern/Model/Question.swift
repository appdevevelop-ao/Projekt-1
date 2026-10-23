import Foundation

public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    case multipleChoice
    case trueFalse
    case cloze
    case shortAnswer
    case freeText
    case numeric
    case matching

    public var title: String {
        switch self {
        case .multipleChoice: return "Multiple Choice"
        case .trueFalse: return "Richtig oder falsch"
        case .cloze: return "Lückentext"
        case .shortAnswer: return "Kurzantwort"
        case .freeText: return "Erklären in eigenen Worten"
        case .numeric: return "Rechenaufgabe"
        case .matching: return "Zuordnung"
        }
    }

    /// Ob die Antwort ohne KI zuverlässig automatisch bewertet werden kann.
    public var isAutoGradable: Bool { self != .freeText }

    /// Abruf ohne vorgegebene Antwortoptionen (aussagekräftiger als Wiedererkennen).
    public var isRecall: Bool {
        switch self {
        case .cloze, .shortAnswer, .freeText, .numeric: return true
        case .multipleChoice, .trueFalse, .matching: return false
        }
    }
}

public enum Difficulty: String, Codable, CaseIterable, Comparable, Sendable {
    case easy, medium, hard

    /// Schwierigkeitsparameter auf der Logit-Skala des Fähigkeitsmodells.
    public var logit: Double {
        switch self {
        case .easy: return -1.0
        case .medium: return 0.0
        case .hard: return 1.0
        }
    }

    public var title: String {
        switch self {
        case .easy: return "Leicht"
        case .medium: return "Mittel"
        case .hard: return "Schwer"
        }
    }

    private var order: Int {
        switch self {
        case .easy: return 0
        case .medium: return 1
        case .hard: return 2
        }
    }

    public static func < (lhs: Difficulty, rhs: Difficulty) -> Bool { lhs.order < rhs.order }
}

public struct NumericAnswer: Codable, Hashable, Sendable {
    public var value: Double
    public var unit: String?
    /// Absolute Toleranz; falls nil, gilt `relativeTolerance`.
    public var absoluteTolerance: Double?
    public var relativeTolerance: Double

    public init(value: Double, unit: String? = nil, absoluteTolerance: Double? = nil, relativeTolerance: Double = 0.01) {
        self.value = value
        self.unit = unit
        self.absoluteTolerance = absoluteTolerance
        self.relativeTolerance = relativeTolerance
    }
}

public struct MatchPair: Codable, Hashable, Sendable {
    public var left: String
    public var right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }
}

public enum QuestionStatus: String, Codable, Sendable {
    case active
    /// Vom Nutzer als fehlerhaft gemeldet – wird nicht mehr gestellt, bisherige Antworten zählen nicht.
    case reported
    case retired
}

public struct Question: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var objectiveID: UUID
    public var kind: QuestionKind
    public var prompt: String
    public var options: [String]
    public var correctOptionIndices: [Int]
    public var acceptedAnswers: [String]
    public var numeric: NumericAnswer?
    public var pairs: [MatchPair]
    public var referenceAnswer: String?
    /// Bewertungskriterien für offene Antworten (Kernpunkte).
    public var rubric: [String]
    public var explanation: String
    public var simplerExplanation: String?
    public var commonMistakes: [String]
    public var difficulty: Difficulty
    /// Transferaufgabe: Anwendung auf eine neue Situation.
    public var isTransfer: Bool
    public var points: Double
    public var source: SourceReference?
    public var origin: ContentOrigin
    public var status: QuestionStatus
    public var createdAt: Date
    /// Fragen mit gleicher Gruppe prüfen denselben Inhalt in anderer Formulierung.
    public var variantGroup: String?

    public init(
        id: UUID = UUID(), examID: UUID, objectiveID: UUID, kind: QuestionKind, prompt: String,
        options: [String] = [], correctOptionIndices: [Int] = [], acceptedAnswers: [String] = [],
        numeric: NumericAnswer? = nil, pairs: [MatchPair] = [], referenceAnswer: String? = nil,
        rubric: [String] = [], explanation: String = "", simplerExplanation: String? = nil,
        commonMistakes: [String] = [], difficulty: Difficulty = .medium, isTransfer: Bool = false,
        points: Double? = nil, source: SourceReference? = nil, origin: ContentOrigin,
        status: QuestionStatus = .active, createdAt: Date = Date(), variantGroup: String? = nil
    ) {
        self.id = id
        self.examID = examID
        self.objectiveID = objectiveID
        self.kind = kind
        self.prompt = prompt
        self.options = options
        self.correctOptionIndices = correctOptionIndices
        self.acceptedAnswers = acceptedAnswers
        self.numeric = numeric
        self.pairs = pairs
        self.referenceAnswer = referenceAnswer
        self.rubric = rubric
        self.explanation = explanation
        self.simplerExplanation = simplerExplanation
        self.commonMistakes = commonMistakes
        self.difficulty = difficulty
        self.isTransfer = isTransfer
        self.points = points ?? Question.defaultPoints(kind: kind, difficulty: difficulty)
        self.source = source
        self.origin = origin
        self.status = status
        self.createdAt = createdAt
        self.variantGroup = variantGroup
    }

    public static func defaultPoints(kind: QuestionKind, difficulty: Difficulty) -> Double {
        let base: Double
        switch kind {
        case .trueFalse: base = 1
        case .multipleChoice, .cloze, .shortAnswer: base = 2
        case .matching: base = 3
        case .numeric, .freeText: base = 4
        }
        switch difficulty {
        case .easy: return base
        case .medium: return base + 1
        case .hard: return base + 2
        }
    }

    /// Geschätzte Bearbeitungszeit in Sekunden (für Simulationen und Zeitprognosen).
    public var estimatedSeconds: Int {
        switch kind {
        case .trueFalse: return 30
        case .multipleChoice: return 60
        case .cloze, .shortAnswer: return 75
        case .matching: return 120
        case .numeric: return 240
        case .freeText: return 300
        }
    }

    /// Schlüssel zum Erkennen unterschiedlicher Formulierungen desselben Inhalts.
    public var formulationKey: String { variantGroup.map { "\($0)#\(id.uuidString)" } ?? id.uuidString }
}
