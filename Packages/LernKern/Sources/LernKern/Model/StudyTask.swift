import Foundation

public enum StudyTaskKind: String, Codable, CaseIterable, Sendable {
    case learn
    case practice
    case review
    case mixedPractice
    case errorAnalysis
    case simulation

    public var title: String {
        switch self {
        case .learn: return "Verstehen"
        case .practice: return "Üben"
        case .review: return "Wiederholen"
        case .mixedPractice: return "Gemischte Übung"
        case .errorAnalysis: return "Fehler analysieren"
        case .simulation: return "Prüfungssimulation"
        }
    }

    public var symbolName: String {
        switch self {
        case .learn: return "book"
        case .practice: return "pencil.and.list.clipboard"
        case .review: return "arrow.triangle.2.circlepath"
        case .mixedPractice: return "shuffle"
        case .errorAnalysis: return "magnifyingglass"
        case .simulation: return "timer"
        }
    }
}

public enum StudyTaskStatus: String, Codable, Sendable {
    case planned
    case inProgress
    case completed
    case skipped
    case missed
}

public struct StudyTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var kind: StudyTaskKind
    public var title: String
    public var detail: String
    public var objectiveIDs: [UUID]
    public var topicIDs: [UUID]
    public var start: Date
    public var durationMinutes: Int
    public var status: StudyTaskStatus
    /// Vom Nutzer manuell verschoben/festgelegt – wird bei automatischer Neuplanung nicht verändert.
    public var isPinned: Bool
    /// Warum diese Einheit eingeplant wurde (transparenter Lerncoach).
    public var reason: String
    public var completedAt: Date?
    public var actualMinutes: Double?
    public var checkPassed: Bool?
    public var part: Int?
    public var partsTotal: Int?

    public init(
        id: UUID = UUID(), examID: UUID, kind: StudyTaskKind, title: String, detail: String = "",
        objectiveIDs: [UUID] = [], topicIDs: [UUID] = [], start: Date, durationMinutes: Int,
        status: StudyTaskStatus = .planned, isPinned: Bool = false, reason: String = "",
        completedAt: Date? = nil, actualMinutes: Double? = nil, checkPassed: Bool? = nil,
        part: Int? = nil, partsTotal: Int? = nil
    ) {
        self.id = id
        self.examID = examID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.objectiveIDs = objectiveIDs
        self.topicIDs = topicIDs
        self.start = start
        self.durationMinutes = durationMinutes
        self.status = status
        self.isPinned = isPinned
        self.reason = reason
        self.completedAt = completedAt
        self.actualMinutes = actualMinutes
        self.checkPassed = checkPassed
        self.part = part
        self.partsTotal = partsTotal
    }

    public var end: Date { start.addingTimeInterval(Double(durationMinutes * 60)) }
    public var isOpen: Bool { status == .planned || status == .inProgress }
}

public struct TopicScore: Codable, Hashable, Sendable {
    public var topicID: UUID
    public var achieved: Double
    public var possible: Double

    public init(topicID: UUID, achieved: Double, possible: Double) {
        self.topicID = topicID
        self.achieved = achieved
        self.possible = possible
    }

    public var fraction: Double { possible > 0 ? achieved / possible : 0 }
}

public struct ExamSimulationResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var timeLimitMinutes: Int
    public var questionIDs: [UUID]
    public var attemptIDs: [UUID]
    public var pointsAchieved: Double
    public var pointsPossible: Double
    public var topicScores: [TopicScore]
    public var gradeBandID: String

    public init(
        id: UUID = UUID(), examID: UUID, startedAt: Date, finishedAt: Date, timeLimitMinutes: Int,
        questionIDs: [UUID], attemptIDs: [UUID], pointsAchieved: Double, pointsPossible: Double,
        topicScores: [TopicScore], gradeBandID: String
    ) {
        self.id = id
        self.examID = examID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.timeLimitMinutes = timeLimitMinutes
        self.questionIDs = questionIDs
        self.attemptIDs = attemptIDs
        self.pointsAchieved = pointsAchieved
        self.pointsPossible = pointsPossible
        self.topicScores = topicScores
        self.gradeBandID = gradeBandID
    }

    public var scoreFraction: Double { pointsPossible > 0 ? pointsAchieved / pointsPossible : 0 }
    public var answeredShare: Double { questionIDs.isEmpty ? 0 : Double(attemptIDs.count) / Double(questionIDs.count) }
}
