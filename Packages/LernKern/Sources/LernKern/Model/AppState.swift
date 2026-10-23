import Foundation

/// Gesamtzustand der App. Antworten (`attempts`) sind die Quelle der Wahrheit für den Wissensstand;
/// Fortschritt, Prognosen und Belohnungsgrundlagen werden daraus abgeleitet.
public struct AppState: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exams: [Exam]
    public var documents: [SourceDocument]
    public var topics: [Topic]
    public var objectives: [LearningObjective]
    public var terms: [KeyTerm]
    public var questions: [Question]
    public var attempts: [Attempt]
    public var checks: [CompletedCheck]
    public var tasks: [StudyTask]
    public var simulations: [ExamSimulationResult]
    public var rewardLedger: [RewardLedgerEntry]
    public var calendarLinks: [CalendarLink]
    public var dailyGoals: [DailyGoalRecord]
    public var planLog: [PlanChangeEntry]
    public var preferences: StudyPreferences
    public var rewardPolicy: RewardPolicy
    public var masteryPolicy: MasteryPolicy
    public var settings: AppSettings

    public init(
        exams: [Exam] = [], documents: [SourceDocument] = [], topics: [Topic] = [],
        objectives: [LearningObjective] = [], terms: [KeyTerm] = [], questions: [Question] = [],
        attempts: [Attempt] = [], checks: [CompletedCheck] = [], tasks: [StudyTask] = [],
        simulations: [ExamSimulationResult] = [], rewardLedger: [RewardLedgerEntry] = [],
        calendarLinks: [CalendarLink] = [], dailyGoals: [DailyGoalRecord] = [], planLog: [PlanChangeEntry] = [],
        preferences: StudyPreferences = StudyPreferences(), rewardPolicy: RewardPolicy = .standard,
        masteryPolicy: MasteryPolicy = .standard, settings: AppSettings = AppSettings()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exams = exams
        self.documents = documents
        self.topics = topics
        self.objectives = objectives
        self.terms = terms
        self.questions = questions
        self.attempts = attempts
        self.checks = checks
        self.tasks = tasks
        self.simulations = simulations
        self.rewardLedger = rewardLedger
        self.calendarLinks = calendarLinks
        self.dailyGoals = dailyGoals
        self.planLog = planLog
        self.preferences = preferences
        self.rewardPolicy = rewardPolicy
        self.masteryPolicy = masteryPolicy
        self.settings = settings
    }

    // Tolerantes Dekodieren: fehlende Felder (ältere Versionen) erhalten Standardwerte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exams = try c.decodeIfPresent([Exam].self, forKey: .exams) ?? []
        documents = try c.decodeIfPresent([SourceDocument].self, forKey: .documents) ?? []
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        objectives = try c.decodeIfPresent([LearningObjective].self, forKey: .objectives) ?? []
        terms = try c.decodeIfPresent([KeyTerm].self, forKey: .terms) ?? []
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        attempts = try c.decodeIfPresent([Attempt].self, forKey: .attempts) ?? []
        checks = try c.decodeIfPresent([CompletedCheck].self, forKey: .checks) ?? []
        tasks = try c.decodeIfPresent([StudyTask].self, forKey: .tasks) ?? []
        simulations = try c.decodeIfPresent([ExamSimulationResult].self, forKey: .simulations) ?? []
        rewardLedger = try c.decodeIfPresent([RewardLedgerEntry].self, forKey: .rewardLedger) ?? []
        calendarLinks = try c.decodeIfPresent([CalendarLink].self, forKey: .calendarLinks) ?? []
        dailyGoals = try c.decodeIfPresent([DailyGoalRecord].self, forKey: .dailyGoals) ?? []
        planLog = try c.decodeIfPresent([PlanChangeEntry].self, forKey: .planLog) ?? []
        preferences = try c.decodeIfPresent(StudyPreferences.self, forKey: .preferences) ?? StudyPreferences()
        rewardPolicy = try c.decodeIfPresent(RewardPolicy.self, forKey: .rewardPolicy) ?? .standard
        masteryPolicy = try c.decodeIfPresent(MasteryPolicy.self, forKey: .masteryPolicy) ?? .standard
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    // MARK: - Abfragen

    public func exam(_ id: UUID) -> Exam? { exams.first { $0.id == id } }

    public func activeExams(now: Date, calendar: Calendar) -> [Exam] {
        exams.filter { $0.isActive(now: now, calendar: calendar) }.sorted { $0.examDate < $1.examDate }
    }

    public func topics(for examID: UUID) -> [Topic] {
        topics.filter { $0.examID == examID && $0.isActive }.sorted { $0.order < $1.order }
    }

    public func objectives(for examID: UUID) -> [LearningObjective] {
        let activeTopics = Set(topics(for: examID).map(\.id))
        return objectives.filter { $0.examID == examID && $0.isActive && activeTopics.contains($0.topicID) }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    public func objectives(inTopic topicID: UUID) -> [LearningObjective] {
        objectives.filter { $0.topicID == topicID && $0.isActive }.sorted { $0.order < $1.order }
    }

    public func activeQuestions(for objectiveID: UUID) -> [Question] {
        questions.filter { $0.objectiveID == objectiveID && $0.status == .active }
    }

    public var questionIndex: [UUID: Question] { Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

    public func documents(for examID: UUID) -> [SourceDocument] {
        documents.filter { $0.examID == examID }.sorted { $0.importedAt < $1.importedAt }
    }

    /// Kontostand der Bildschirmzeit in Minuten.
    public var rewardBalance: Int { max(0, rewardLedger.reduce(0) { $0 + $1.minutes }) }

    public func earnedMinutes(on day: DayKey, calendar: Calendar) -> Int {
        rewardLedger.filter { $0.kind == .earned && DayKey($0.date, calendar: calendar) == day }.reduce(0) { $0 + $1.minutes }
    }

    public func dailyGoal(for day: DayKey) -> DailyGoalRecord? { dailyGoals.first { $0.day == day } }
}
