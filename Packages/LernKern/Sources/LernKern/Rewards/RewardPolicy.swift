import Foundation

/// Einstellbare Regeln für verdiente Bildschirmzeit. Standardwerte siehe `standard`.
public struct RewardPolicy: Codable, Hashable, Sendable {
    /// Mindestanzahl gültiger Antworten, damit eine Überprüfung belohnt wird.
    public var minQuestionsPerCheck: Int
    public var baseMinutesPerCheck: Int
    public var maxMinutesPerCheck: Int
    /// Bonus je Lernziel, das nach zeitlichem Abstand erfolgreich wiederholt wurde (max. 3).
    public var spacedReviewBonus: Int
    /// Bonus, wenn ein Lernziel "vorläufig beherrscht" erreicht.
    public var provisionalBonus: Int
    /// Bonus, wenn ein Lernziel "stabil beherrscht" erreicht.
    public var stableBonus: Int
    /// Bonus für messbare Verbesserung (auch wenn die Überprüfung nicht bestanden wurde).
    public var improvementBonus: Int
    public var simulationBaseMinutes: Int
    public var simulationMaxMinutes: Int
    public var simulationTargetBonus: Int
    /// Höchstens so viele Minuten pro Tag verdienen.
    public var dailyEarnCap: Int
    /// Höchster Kontostand.
    public var maxBalance: Int
    /// Antworten, die schneller gegeben werden, zählen nicht (Durchklicken).
    public var minSecondsPerAnswer: Double
    /// Dieselbe Frage zählt erst nach dieser Zeit wieder.
    public var repeatCooldownHours: Double

    public init(
        minQuestionsPerCheck: Int = 3, baseMinutesPerCheck: Int = 5, maxMinutesPerCheck: Int = 10,
        spacedReviewBonus: Int = 1, provisionalBonus: Int = 2, stableBonus: Int = 3, improvementBonus: Int = 2,
        simulationBaseMinutes: Int = 10, simulationMaxMinutes: Int = 20, simulationTargetBonus: Int = 5,
        dailyEarnCap: Int = 120, maxBalance: Int = 240, minSecondsPerAnswer: Double = 3, repeatCooldownHours: Double = 20
    ) {
        self.minQuestionsPerCheck = max(1, minQuestionsPerCheck)
        self.baseMinutesPerCheck = max(0, baseMinutesPerCheck)
        self.maxMinutesPerCheck = max(self.baseMinutesPerCheck, maxMinutesPerCheck)
        self.spacedReviewBonus = max(0, spacedReviewBonus)
        self.provisionalBonus = max(0, provisionalBonus)
        self.stableBonus = max(0, stableBonus)
        self.improvementBonus = max(0, improvementBonus)
        self.simulationBaseMinutes = max(0, simulationBaseMinutes)
        self.simulationMaxMinutes = max(self.simulationBaseMinutes, simulationMaxMinutes)
        self.simulationTargetBonus = max(0, simulationTargetBonus)
        self.dailyEarnCap = max(0, dailyEarnCap)
        self.maxBalance = max(0, maxBalance)
        self.minSecondsPerAnswer = max(0, minSecondsPerAnswer)
        self.repeatCooldownHours = max(0, repeatCooldownHours)
    }

    public static let standard = RewardPolicy()
}

/// Lernphase relativ zum Ziel. Bestimmt, WAS belohnt wird – nicht die Prognose selbst.
public enum RewardPhase: String, Codable, Sendable {
    /// Weit unter dem Ziel: kleine, erreichbare Fortschritte zählen.
    case foundation
    /// Auf dem Weg zum Ziel.
    case building
    /// Nah am Ziel: anspruchsvollere Aufgaben werden stärker belohnt.
    case refinement
    /// Ziel zuverlässig erreicht: Behalten steht im Mittelpunkt, kein Zwang zu mehr Lernen.
    case maintenance

    public var title: String {
        switch self {
        case .foundation: return "Grundlagen aufbauen"
        case .building: return "Auf Kurs zum Ziel"
        case .refinement: return "Feinschliff"
        case .maintenance: return "Wissen erhalten"
        }
    }

    /// Mindestgenauigkeit (schwierigkeitsgewichtet), ab der eine Überprüfung als bestanden gilt.
    public var passThreshold: Double {
        switch self {
        case .foundation: return 0.5
        case .building: return 0.6
        case .refinement, .maintenance: return 0.7
        }
    }

    /// Phase aus Prognose und Ziel. Die Prognose wird hier nur gelesen, nie verändert.
    public static func from(forecast: GradeForecast?, targetMinFraction: Double) -> RewardPhase {
        guard let f = forecast, f.confidence != .insufficient else { return .building }
        if f.confidence >= .medium, f.scoreLow >= targetMinFraction { return .maintenance }
        let gap = targetMinFraction - f.expectedScore
        if gap > 0.2 { return .foundation }
        if gap > 0.05 { return .building }
        return .refinement
    }
}
