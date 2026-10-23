import Foundation

/// Wählt Fragen für Lerneinheiten, Wiederholungen und Simulationen aus.
///
/// - Adaptive Schwierigkeit: Ziel-Lösungswahrscheinlichkeit ca. 70 %; bei Schwierigkeiten leichtere Aufgaben.
/// - Fehlende Kriterien werden gezielt adressiert (z. B. schwere Aufgabe, Wiederholung nach Abstand).
/// - Kürzlich richtig beantwortete Fragen werden gemieden, neue Formulierungen bevorzugt.
public enum QuestionSelector {
    public static let targetProbability = 0.7

    public static func select(
        objectiveIDs: [UUID],
        count: Int,
        state: AppState,
        knowledge: [UUID: ObjectiveKnowledge],
        now: Date,
        allowFreeText: Bool,
        seed: String
    ) -> [Question] {
        guard count > 0, !objectiveIDs.isEmpty else { return [] }
        var rng = SeededGenerator(seed)
        let recentCorrect = Set(state.attempts.filter { $0.isCorrect && now.timeIntervalSince($0.answeredAt) < 20 * 3600 }.map(\.questionID))
        let seen = Set(state.attempts.map(\.questionID))
        var pools: [UUID: [Question]] = [:]
        for id in objectiveIDs {
            pools[id] = state.activeQuestions(for: id).filter { allowFreeText || $0.kind != .freeText }
        }
        // Schwächste Lernziele zuerst
        let ordered = objectiveIDs.filter { !(pools[$0]?.isEmpty ?? true) }.sorted {
            (knowledge[$0]?.score ?? 0) < (knowledge[$1]?.score ?? 0)
        }
        guard !ordered.isEmpty else { return [] }

        var selected: [Question] = []
        var used: Set<UUID> = []
        var freeTextCount = 0
        var round = 0
        while selected.count < count && round < count * 3 {
            let objectiveID = ordered[round % ordered.count]
            round += 1
            guard let pool = pools[objectiveID] else { continue }
            let k = knowledge[objectiveID]
            let desired = desiredDifficulty(k, alreadyPicked: selected.filter { $0.objectiveID == objectiveID })
            let candidates = pool.filter { !used.contains($0.id) && !($0.kind == .freeText && freeTextCount >= 1) }
            guard !candidates.isEmpty else { continue }
            let scored = candidates.map { q -> (Question, Double) in
                var score = 0.0
                score -= abs(Double(rank(q.difficulty) - rank(desired))) * 2
                if !seen.contains(q.id) { score += 1.5 }
                if recentCorrect.contains(q.id) { score -= 5 }
                if q.isTransfer && (k?.criterion(.hardOrTransfer)?.isMet == false) && (k?.level ?? .notStarted) >= .provisional { score += 2 }
                if q.kind == .freeText { score -= 0.5 }
                score += Double.random(in: 0..<0.5, using: &rng)
                return (q, score)
            }
            if let best = scored.max(by: { $0.1 < $1.1 })?.0 {
                selected.append(best)
                used.insert(best.id)
                if best.kind == .freeText { freeTextCount += 1 }
            }
        }
        return selected
    }

    static func rank(_ d: Difficulty) -> Int {
        switch d {
        case .easy: return 0
        case .medium: return 1
        case .hard: return 2
        }
    }

    /// Schwierigkeit, deren Lösungswahrscheinlichkeit am nächsten bei 70 % liegt.
    public static func desiredDifficulty(_ k: ObjectiveKnowledge?, alreadyPicked: [Question]) -> Difficulty {
        guard let k, k.attemptCount > 0 else { return alreadyPicked.isEmpty ? .easy : .medium }
        if k.isStruggling { return .easy }
        if k.level >= .provisional, k.criterion(.hardOrTransfer)?.isMet == false, !alreadyPicked.contains(where: { $0.difficulty == .hard }) {
            return .hard
        }
        let options: [Difficulty] = [.easy, .medium, .hard]
        return options.min { abs(MathUtil.sigmoid(k.ability - $0.logit) - targetProbability) < abs(MathUtil.sigmoid(k.ability - $1.logit) - targetProbability) } ?? .medium
    }

    /// Gemischte Übung: bereits begonnene Lernziele, bevorzugt mit nachlassender Erinnerung.
    public static func mixedObjectives(examID: UUID, state: AppState, knowledge: [UUID: ObjectiveKnowledge], limit: Int) -> [UUID] {
        state.objectives(for: examID)
            .filter { (knowledge[$0.id]?.level ?? .notStarted) >= .learned }
            .sorted { (knowledge[$0.id]?.retrievability ?? 0) < (knowledge[$1.id]?.retrievability ?? 0) }
            .prefix(limit).map(\.id)
    }
}

/// Zusammenstellung einer Prüfungssimulation.
public struct SimulationBlueprint: Hashable, Sendable {
    public var examID: UUID
    public var questionIDs: [UUID]
    public var timeLimitMinutes: Int
    public var pointsPossible: Double
    /// Hinweis, falls zu wenige Fragen vorhanden sind.
    public var limitation: String?
}

public enum SimulationBuilder {
    /// Gemischte Aufgaben, gewichtet nach Prüfungsanteil der Themen, bevorzugt ungesehene Fragen,
    /// Schwierigkeitsmischung ca. 30/45/25 %, Gesamtbearbeitungszeit passend zum Zeitlimit.
    public static func build(exam: Exam, state: AppState, timeLimitMinutes: Int, seed: String) -> SimulationBlueprint {
        var rng = SeededGenerator(seed)
        let objectives = state.objectives(for: exam.id)
        let weights = ObjectiveWeights.compute(topics: state.topics(for: exam.id), objectives: objectives)
        let seen = Set(state.attempts.map(\.questionID))
        let budgetSeconds = Double(timeLimitMinutes * 60) * 0.85
        var pool = objectives.flatMap { o in state.activeQuestions(for: o.id).map { (o.id, $0) } }
        pool.shuffle(using: &rng)
        // Ungesehene Fragen zuerst, dann nach Gewicht des Lernziels
        pool.sort { a, b in
            let ua = seen.contains(a.1.id) ? 1 : 0
            let ub = seen.contains(b.1.id) ? 1 : 0
            if ua != ub { return ua < ub }
            return (weights[a.0] ?? 0) > (weights[b.0] ?? 0)
        }
        let targetShare: [Difficulty: Double] = [.easy: 0.3, .medium: 0.45, .hard: 0.25]
        var chosen: [Question] = []
        var seconds = 0.0
        var perObjective: [UUID: Int] = [:]
        var perDifficulty: [Difficulty: Double] = [:]
        // Mehrere Durchläufe: erst breite Abdeckung (je Lernziel max. 1), dann auffüllen
        for maxPerObjective in [1, 2, 4] {
            for (objectiveID, q) in pool where !chosen.contains(where: { $0.id == q.id }) {
                guard seconds + Double(q.estimatedSeconds) <= budgetSeconds else { continue }
                guard perObjective[objectiveID, default: 0] < maxPerObjective else { continue }
                let total = max(1, seconds)
                if (perDifficulty[q.difficulty] ?? 0) / total > (targetShare[q.difficulty] ?? 0.34) + 0.15, chosen.count > 4 { continue }
                chosen.append(q)
                seconds += Double(q.estimatedSeconds)
                perObjective[objectiveID, default: 0] += 1
                perDifficulty[q.difficulty, default: 0] += Double(q.estimatedSeconds)
            }
        }
        let coveredObjectives = Set(chosen.map(\.objectiveID)).count
        var limitation: String?
        if chosen.count < 5 {
            limitation = "Es gibt noch zu wenige Fragen für eine aussagekräftige Simulation. Lass zuerst weitere Fragen erzeugen."
        } else if coveredObjectives < objectives.count {
            limitation = "Die Simulation deckt \(coveredObjectives) von \(objectives.count) Lernzielen ab."
        }
        // Reihenfolge: gemischt, nicht nach Thema sortiert
        chosen.shuffle(using: &rng)
        return SimulationBlueprint(examID: exam.id, questionIDs: chosen.map(\.id), timeLimitMinutes: timeLimitMinutes,
                                   pointsPossible: chosen.reduce(0) { $0 + $1.points }, limitation: limitation)
    }
}
