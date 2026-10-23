import Foundation

/// Wissensstand eines Lernziels.
public enum MasteryLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case notStarted = 0
    case learned = 1
    case provisional = 2
    case stable = 3

    public var title: String {
        switch self {
        case .notStarted: return "Noch nicht begonnen"
        case .learned: return "Gelernt"
        case .provisional: return "Vorläufig beherrscht"
        case .stable: return "Stabil beherrscht"
        }
    }

    public static func < (lhs: MasteryLevel, rhs: MasteryLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Mindestkriterien für "beherrscht". Alle Werte sind bewusst nachvollziehbar gewählt
/// und können für Tests oder spätere Anpassungen verändert werden.
public struct MasteryPolicy: Codable, Hashable, Sendable {
    /// Gewichtete Anzahl richtiger Antworten ohne Hilfe.
    public var requiredCorrect: Double
    /// Anzahl unterschiedlicher Fragen (Formulierungen), die richtig beantwortet wurden.
    public var requiredDistinctQuestions: Int
    /// Geschätzte Lösungswahrscheinlichkeit einer mittelschweren Aufgabe.
    public var provisionalProbability: Double
    /// Von den letzten `consistencyWindow` Antworten müssen `consistencyRequired` richtig sein.
    public var consistencyWindow: Int
    public var consistencyRequired: Int
    /// Mindestabstand für eine "Wiederholung nach zeitlichem Abstand".
    public var spacedGapHours: Double
    public var requiredSpacedSuccesses: Int
    /// Richtige Antworten auf schwere oder Transferaufgaben.
    public var requiredHardOrTransfer: Int
    /// Aktuelle Erinnerungswahrscheinlichkeit, ab der Wissen als "noch präsent" gilt.
    public var stableRetention: Double

    public init(
        requiredCorrect: Double = 3,
        requiredDistinctQuestions: Int = 2,
        provisionalProbability: Double = 0.75,
        consistencyWindow: Int = 3,
        consistencyRequired: Int = 2,
        spacedGapHours: Double = 20,
        requiredSpacedSuccesses: Int = 1,
        requiredHardOrTransfer: Int = 1,
        stableRetention: Double = 0.85
    ) {
        self.requiredCorrect = requiredCorrect
        self.requiredDistinctQuestions = requiredDistinctQuestions
        self.provisionalProbability = provisionalProbability
        self.consistencyWindow = consistencyWindow
        self.consistencyRequired = consistencyRequired
        self.spacedGapHours = spacedGapHours
        self.requiredSpacedSuccesses = requiredSpacedSuccesses
        self.requiredHardOrTransfer = requiredHardOrTransfer
        self.stableRetention = stableRetention
    }

    public static let standard = MasteryPolicy()
}

public enum MasteryCriterionID: String, Codable, CaseIterable, Sendable {
    case correctAnswers
    case distinctQuestions
    case ability
    case consistency
    case spacedRecall
    case hardOrTransfer
    case retention

    public var isProvisional: Bool {
        switch self {
        case .correctAnswers, .distinctQuestions, .ability, .consistency: return true
        case .spacedRecall, .hardOrTransfer, .retention: return false
        }
    }
}

public struct MasteryCriterion: Hashable, Sendable {
    public var id: MasteryCriterionID
    public var title: String
    /// Erfüllungsgrad 0…1.
    public var progress: Double
    /// Was noch fehlt, in einfacher Sprache.
    public var remainingHint: String?

    public var isMet: Bool { progress >= 0.999 }
}

/// Aus allen Antworten abgeleiteter Wissensstand eines Lernziels.
///
/// Der Zustand wird nie direkt gespeichert, sondern immer aus den gespeicherten Antworten
/// berechnet. So ist er nach einem Neustart garantiert konsistent und kann nicht
/// "künstlich" zurückgesetzt werden.
public struct ObjectiveKnowledge: Hashable, Sendable {
    public var objectiveID: UUID
    public var level: MasteryLevel
    public var criteria: [MasteryCriterion]
    /// Gesamtfortschritt dieses Lernziels 0…1.
    public var score: Double
    /// Fähigkeit auf der Logit-Skala.
    public var ability: Double
    /// Geschätzte Lösungswahrscheinlichkeit einer mittelschweren Aufgabe.
    public var probabilityMedium: Double
    /// Erwartete Lösungswahrscheinlichkeit bei prüfungstypischer Schwierigkeitsmischung.
    public var probabilityExamMix: Double
    /// Summe der Beleggewichte.
    public var evidence: Double
    public var attemptCount: Int
    public var weightedCorrect: Double
    public var distinctCorrectQuestions: Int
    public var spacedSuccesses: Int
    public var hardOrTransferCorrect: Int
    public var lapses: Int
    /// Gedächtnisstabilität in Tagen (0 = noch nicht erfolgreich abgerufen).
    public var stabilityDays: Double
    public var lastReviewAt: Date?
    public var retrievability: Double
    public var reviewDueAt: Date?
    public var firstExposureAttempts: Int
    public var firstExposureScoreSum: Double
    public var averageSecondsPerQuestion: Double?
    public var recentScores: [Double]

    /// Erfüllt alle Kriterien für 100 % (stabil beherrscht UND aktuell präsent).
    public var isComplete: Bool { level == .stable && criteria.allSatisfy(\.isMet) }

    public var isStruggling: Bool {
        attemptCount >= 4 && (probabilityMedium < 0.5 || lapses >= 2)
    }

    public func isReviewDue(at date: Date) -> Bool {
        guard let due = reviewDueAt else { return false }
        return due <= date
    }

    public func criterion(_ id: MasteryCriterionID) -> MasteryCriterion? { criteria.first { $0.id == id } }
}

/// Bestimmt Fähigkeit, Gedächtnisstabilität und Beherrschungsgrad aus den Antworten.
///
/// Modell (dokumentiert in docs/LERNMODELL.md):
/// - Fähigkeit: Elo-/Rasch-ähnliche Schätzung, P(richtig) = g + (1 − g)·σ(θ − b) mit
///   Rateanteil g (z. B. 1/4 bei vier Optionen) und Schwierigkeit b.
/// - Gedächtnis: Stabilität S in Tagen; Erinnerungswahrscheinlichkeit R(t) = (1 + t/(9S))⁻¹
///   (Vergessenskurve wie im FSRS-Verfahren). Erfolgreicher Abruf bei niedrigem R erhöht S
///   stark, Abruf direkt hintereinander kaum.
public struct KnowledgeTracer: Sendable {
    public var policy: MasteryPolicy

    /// Schwierigkeitsmischung einer typischen Prüfung.
    public static let examDifficultyMix: [(Difficulty, Double)] = [(.easy, 0.3), (.medium, 0.45), (.hard, 0.25)]

    public init(policy: MasteryPolicy = .standard) {
        self.policy = policy
    }

    public func knowledge(
        for objectiveID: UUID,
        attempts: [Attempt],
        questions: [UUID: Question],
        prior: PriorKnowledge,
        now: Date
    ) -> ObjectiveKnowledge {
        let valid = attempts
            .filter { $0.objectiveID == objectiveID && !$0.isVoided && $0.answeredAt <= now }
            .filter { questions[$0.questionID].map { $0.status != .reported } ?? true }
            .sorted { $0.answeredAt < $1.answeredAt }

        var theta = MathUtil.logit(prior.priorProbability)
        var evidence = 0.0
        var weightedCorrect = 0.0
        var distinct: Set<UUID> = []
        var spaced = 0
        var hardCorrect = 0
        var lapses = 0
        var stability = 0.0
        var lastReview: Date?
        var lastSuccess: Date?
        var firstExposure = 0
        var firstExposureSum = 0.0
        var durations: [Double] = []

        for attempt in valid {
            let question = questions[attempt.questionID]
            let weight = attempt.grading.evidenceWeight * (attempt.usedHint ? 0.5 : 1)
            let b = Self.difficultyLogit(for: question)
            let g = Self.guessingRate(for: question)
            let expected = g + (1 - g) * MathUtil.sigmoid(theta - b)
            let k = max(0.3, 1.2 / (1 + 0.2 * evidence)) * weight
            theta = MathUtil.clamp(theta + k * (attempt.score - expected), -4, 4)
            evidence += weight

            let correct = attempt.isCorrect && !attempt.usedHint
            if correct {
                weightedCorrect += attempt.grading.evidenceWeight
                distinct.insert(attempt.questionID)
                if let q = question, q.difficulty == .hard || q.isTransfer { hardCorrect += 1 }
                if let previous = lastSuccess, attempt.answeredAt.timeIntervalSince(previous) >= policy.spacedGapHours * 3600 {
                    spaced += 1
                }
            }

            // Gedächtnismodell
            let difficultyFactor: Double
            switch question?.difficulty ?? .medium {
            case .easy: difficultyFactor = 0.7
            case .medium: difficultyFactor = 1.0
            case .hard: difficultyFactor = 1.3
            }
            let recallFactor = (question?.kind.isRecall ?? false) ? 1.1 : 1.0
            if attempt.isSuccess {
                if stability == 0 {
                    stability = 1.0 * difficultyFactor
                } else {
                    let elapsed = max(0, attempt.answeredAt.timeIntervalSince(lastReview ?? attempt.answeredAt)) / 86_400
                    let r = Self.retrievability(stability: stability, elapsedDays: elapsed)
                    let growth = 25 * pow(stability, -0.15) * (exp(1.2 * (1 - r)) - 1) * difficultyFactor * recallFactor * weight
                    stability = min(365, stability * (1 + growth))
                }
                lastSuccess = attempt.answeredAt
            } else if stability > 0 {
                stability = max(0.3, stability * 0.4)
                lapses += 1
            }
            lastReview = attempt.answeredAt

            if attempt.wasFirstExposure {
                firstExposure += 1
                firstExposureSum += attempt.score
            }
            durations.append(MathUtil.clamp(attempt.durationSeconds, 5, 600))
        }

        let pMedium = MathUtil.sigmoid(theta)
        let pMix = Self.examDifficultyMix.reduce(0) { $0 + $1.1 * MathUtil.sigmoid(theta - $1.0.logit) }
        let elapsedNow = lastReview.map { max(0, now.timeIntervalSince($0)) / 86_400 } ?? 0
        let retention = stability > 0 ? Self.retrievability(stability: stability, elapsedDays: elapsedNow) : 0
        let due = (stability > 0 ? lastReview?.addingTimeInterval(stability * 86_400) : nil)
        let recent = valid.suffix(5).map(\.score)

        let criteria = makeCriteria(
            weightedCorrect: weightedCorrect, distinct: distinct.count, pMedium: pMedium,
            recent: valid.suffix(policy.consistencyWindow).map(\.score), spaced: spaced,
            hard: hardCorrect, stability: stability, retention: retention
        )
        let provisionalMet = criteria.filter { $0.id.isProvisional }.allSatisfy(\.isMet)
        let stableMet = provisionalMet && criteria.filter { $0.id == .spacedRecall || $0.id == .hardOrTransfer }.allSatisfy(\.isMet)

        let level: MasteryLevel
        if valid.isEmpty { level = .notStarted }
        else if stableMet { level = .stable }
        else if provisionalMet { level = .provisional }
        else { level = .learned }

        return ObjectiveKnowledge(
            objectiveID: objectiveID,
            level: level,
            criteria: criteria,
            score: valid.isEmpty ? 0 : Self.score(criteria: criteria, provisionalMet: provisionalMet),
            ability: theta,
            probabilityMedium: pMedium,
            probabilityExamMix: pMix,
            evidence: evidence,
            attemptCount: valid.count,
            weightedCorrect: weightedCorrect,
            distinctCorrectQuestions: distinct.count,
            spacedSuccesses: spaced,
            hardOrTransferCorrect: hardCorrect,
            lapses: lapses,
            stabilityDays: stability,
            lastReviewAt: lastReview,
            retrievability: retention,
            reviewDueAt: due,
            firstExposureAttempts: firstExposure,
            firstExposureScoreSum: firstExposureSum,
            averageSecondsPerQuestion: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
            recentScores: Array(recent)
        )
    }

    // MARK: - Kriterien

    func makeCriteria(weightedCorrect: Double, distinct: Int, pMedium: Double, recent: [Double], spaced: Int, hard: Int, stability: Double, retention: Double) -> [MasteryCriterion] {
        let p = policy
        let correctProgress = min(1, weightedCorrect / p.requiredCorrect)
        let distinctProgress = min(1, Double(distinct) / Double(max(1, p.requiredDistinctQuestions)))
        let abilityProgress = MathUtil.clamp((pMedium - 0.5) / (p.provisionalProbability - 0.5), 0, 1)
        let recentCorrect = recent.filter { $0 >= 0.8 }.count
        let consistencyBase = min(1, Double(recentCorrect) / Double(max(1, p.consistencyRequired)))
        // Erst mit genügend Antworten erfüllbar.
        let consistencyProgress = recent.count >= p.consistencyWindow ? consistencyBase : min(consistencyBase, 0.9)
        let spacedProgress = min(1, Double(spaced) / Double(max(1, p.requiredSpacedSuccesses)))
        let hardProgress = min(1, Double(hard) / Double(max(1, p.requiredHardOrTransfer)))
        let retentionProgress = stability > 0 ? min(1, retention / p.stableRetention) : 0

        func remaining(_ needed: Double, _ unit: String) -> String? { needed > 0 ? "Noch \(Self.format(needed)) \(unit)" : nil }

        return [
            MasteryCriterion(id: .correctAnswers, title: "Richtige Antworten ohne Hilfe", progress: correctProgress,
                             remainingHint: remaining((p.requiredCorrect - weightedCorrect).rounded(.up), "richtige Antwort(en) ohne Hilfe")),
            MasteryCriterion(id: .distinctQuestions, title: "Verschiedene Fragen richtig", progress: distinctProgress,
                             remainingHint: remaining(Double(p.requiredDistinctQuestions - distinct), "andere Frage(n) zum selben Inhalt")),
            MasteryCriterion(id: .ability, title: "Sicherheit bei mittelschweren Aufgaben", progress: abilityProgress,
                             remainingHint: abilityProgress < 0.999 ? "Noch einige Aufgaben sicher lösen" : nil),
            MasteryCriterion(id: .consistency, title: "Beständig richtig", progress: consistencyProgress,
                             remainingHint: consistencyProgress < 0.999 ? "\(p.consistencyRequired) der letzten \(p.consistencyWindow) Antworten richtig" : nil),
            MasteryCriterion(id: .spacedRecall, title: "Wiederholung an einem anderen Tag", progress: spacedProgress,
                             remainingHint: spacedProgress < 0.999 ? "Nach frühestens \(Int(p.spacedGapHours)) Stunden noch einmal richtig beantworten" : nil),
            MasteryCriterion(id: .hardOrTransfer, title: "Schwierige oder Transferaufgabe gelöst", progress: hardProgress,
                             remainingHint: hardProgress < 0.999 ? "Eine schwierigere Aufgabe richtig lösen" : nil),
            MasteryCriterion(id: .retention, title: "Wissen aktuell präsent", progress: retentionProgress,
                             remainingHint: retentionProgress < 0.999 ? (stability > 0 ? "Kurze Wiederholung fällig" : "Erst nach erfolgreichem Abruf messbar") : nil),
        ]
    }

    /// Fortschritt eines Lernziels: 60 % vorläufige Kriterien, 40 % Stabilitätskriterien.
    /// Ohne alle vorläufigen Kriterien höchstens 59 %, 100 % nur bei allen Kriterien.
    static func score(criteria: [MasteryCriterion], provisionalMet: Bool) -> Double {
        let provisionalWeights: [MasteryCriterionID: Double] = [.correctAnswers: 0.3, .distinctQuestions: 0.2, .ability: 0.3, .consistency: 0.2]
        let stableWeights: [MasteryCriterionID: Double] = [.spacedRecall: 0.4, .hardOrTransfer: 0.3, .retention: 0.3]
        let prov = criteria.reduce(0) { $0 + (provisionalWeights[$1.id] ?? 0) * $1.progress }
        let stab = criteria.reduce(0) { $0 + (stableWeights[$1.id] ?? 0) * $1.progress }
        var score = 0.6 * prov + 0.4 * stab
        if !provisionalMet { score = min(score, 0.59) }
        if !criteria.allSatisfy(\.isMet) { score = min(score, 0.99) }
        return MathUtil.clamp(score, 0, 1)
    }

    // MARK: - Modellparameter

    public static func retrievability(stability: Double, elapsedDays: Double) -> Double {
        guard stability > 0 else { return 0 }
        return 1 / (1 + elapsedDays / (9 * stability))
    }

    static func difficultyLogit(for question: Question?) -> Double {
        guard let q = question else { return 0 }
        var b = q.difficulty.logit
        if q.isTransfer { b += 0.3 }
        if q.kind.isRecall { b += 0.2 }
        return b
    }

    static func guessingRate(for question: Question?) -> Double {
        guard let q = question else { return 0 }
        switch q.kind {
        case .multipleChoice: return q.options.isEmpty ? 0.25 : 1 / Double(q.options.count)
        case .trueFalse: return 0.5
        case .matching: return 0.1
        case .cloze, .shortAnswer, .freeText, .numeric: return 0
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
