import Foundation

/// Was der Nutzer mit der Prüfungsvorbereitung erreichen möchte.
public enum StudyGoalType: String, Codable, CaseIterable, Sendable {
    case pass
    case specificGrade
    case masterMaterial
    case multipleExams

    public var title: String {
        switch self {
        case .pass: return "Prüfung bestehen"
        case .specificGrade: return "Bestimmte Note erreichen"
        case .masterMaterial: return "Umfangreichen Stoff beherrschen"
        case .multipleExams: return "Mehrere Prüfungen vorbereiten"
        }
    }
}

public enum ExamFormat: String, Codable, CaseIterable, Sendable {
    case written
    case multipleChoice
    case oral
    case practical
    case mixed
    case unknown

    public var title: String {
        switch self {
        case .written: return "Schriftlich"
        case .multipleChoice: return "Multiple Choice"
        case .oral: return "Mündlich"
        case .practical: return "Praktisch / Rechenaufgaben"
        case .mixed: return "Gemischt"
        case .unknown: return "Noch nicht bekannt"
        }
    }
}

public enum PriorKnowledge: String, Codable, CaseIterable, Sendable {
    case none
    case basic
    case solid

    public var title: String {
        switch self {
        case .none: return "Neu für mich"
        case .basic: return "Grundkenntnisse"
        case .solid: return "Schon gut vertraut"
        }
    }

    /// Angenommene Lösungswahrscheinlichkeit einer mittelschweren Aufgabe ohne jede Übung.
    /// Wird nur verwendet, solange keine eigenen Daten vorliegen, und ist als Annahme gekennzeichnet.
    public var priorProbability: Double {
        switch self {
        case .none: return 0.15
        case .basic: return 0.35
        case .solid: return 0.55
        }
    }
}

/// Tatsächliches Prüfungsergebnis – dient der Überprüfung, wie gut die Prognose war.
public struct ExamOutcome: Codable, Hashable, Sendable {
    public var actualGradeID: String
    public var actualScoreFraction: Double?
    public var enteredAt: Date
    public var forecastGradeID: String?
    public var forecastScore: Double?

    public init(actualGradeID: String, actualScoreFraction: Double? = nil, enteredAt: Date, forecastGradeID: String? = nil, forecastScore: Double? = nil) {
        self.actualGradeID = actualGradeID
        self.actualScoreFraction = actualScoreFraction
        self.enteredAt = enteredAt
        self.forecastGradeID = forecastGradeID
        self.forecastScore = forecastScore
    }
}

public struct Exam: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var examDate: Date
    public var format: ExamFormat
    /// Dauer der echten Prüfung in Minuten, falls bekannt.
    public var durationMinutes: Int?
    public var gradeScale: GradeScale
    public var targetGradeID: String
    public var goal: StudyGoalType
    public var priorKnowledge: PriorKnowledge
    /// Zusätzliche Prüfungsanforderungen in Freitext (z. B. "Kapitel 7 nicht prüfungsrelevant").
    public var additionalRequirements: String
    public var createdAt: Date
    public var isArchived: Bool
    public var outcome: ExamOutcome?

    public init(
        id: UUID = UUID(),
        title: String,
        examDate: Date,
        format: ExamFormat = .unknown,
        durationMinutes: Int? = nil,
        gradeScale: GradeScale = .austrian,
        targetGradeID: String? = nil,
        goal: StudyGoalType = .specificGrade,
        priorKnowledge: PriorKnowledge = .basic,
        additionalRequirements: String = "",
        createdAt: Date = Date(),
        isArchived: Bool = false,
        outcome: ExamOutcome? = nil
    ) {
        self.id = id
        self.title = title
        self.examDate = examDate
        self.format = format
        self.durationMinutes = durationMinutes
        self.gradeScale = gradeScale
        self.targetGradeID = targetGradeID ?? gradeScale.defaultTargetID
        self.goal = goal
        self.priorKnowledge = priorKnowledge
        self.additionalRequirements = additionalRequirements
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.outcome = outcome
    }

    public var targetBand: GradeBand { gradeScale.band(id: targetGradeID) ?? gradeScale.bands[gradeScale.bands.count / 2] }

    /// Eine Prüfung ist aktiv, solange sie nicht archiviert ist und ihr Termin nicht vor heute liegt.
    public func isActive(now: Date, calendar: Calendar) -> Bool {
        !isArchived && calendar.startOfDay(for: examDate) >= calendar.startOfDay(for: now)
    }

    public func daysUntilExam(from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: examDate)).day ?? 0
    }
}
