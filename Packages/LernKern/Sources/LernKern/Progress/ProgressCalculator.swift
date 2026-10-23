import Foundation

public struct TopicProgress: Hashable, Sendable, Identifiable {
    public var id: UUID { topic.id }
    public var topic: Topic
    public var objectiveCount: Int
    public var completeCount: Int
    /// Gewichteter Fortschritt innerhalb des Themas (0…1).
    public var fraction: Double
    /// Anteil dieses Themas an der Prüfung (0…1).
    public var weight: Double
    public var levelCounts: [MasteryLevel: Int]

    public var percent: Int { ProgressCalculator.displayPercent(fraction, isComplete: objectiveCount > 0 && completeCount == objectiveCount) }
}

/// Was bis 100 % noch fehlt – gruppiert und verständlich formuliert.
public struct MissingRequirement: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case noObjectives
        case notStarted
        case needsPractice
        case needsSpacedRecall
        case needsHardQuestion
        case reviewDue
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var objectiveIDs: [UUID]
    public var text: String
}

public struct ExamProgress: Hashable, Sendable {
    public var examID: UUID
    /// Gewichteter Fortschritt 0…1.
    public var fraction: Double
    /// Alle Kriterien aller Lernziele erfüllt.
    public var isComplete: Bool
    public var objectiveCount: Int
    public var completeCount: Int
    public var levelCounts: [MasteryLevel: Int]
    public var topics: [TopicProgress]
    public var missing: [MissingRequirement]
    public var knowledge: [UUID: ObjectiveKnowledge]
    public var weights: [UUID: Double]

    /// Angezeigter Prozentwert. Zeigt nur dann 100, wenn wirklich alles erfüllt ist.
    public var percent: Int { ProgressCalculator.displayPercent(fraction, isComplete: isComplete) }
}

/// Berechnet den Lernfortschritt einer Prüfung.
///
/// Definition von 100 %: Jedes aktive Lernziel ist stabil beherrscht (vorläufige Kriterien,
/// Wiederholung nach zeitlichem Abstand, schwierige/Transferaufgabe) UND aktuell präsent
/// (Erinnerungswahrscheinlichkeit ≥ Schwelle). Ein sehr gutes Thema kann Lücken in einem
/// anderen nicht ausgleichen, weil 100 % für jedes einzelne Lernziel gelten muss.
public struct ProgressCalculator: Sendable {
    public var tracer: KnowledgeTracer

    public init(policy: MasteryPolicy = .standard) {
        tracer = KnowledgeTracer(policy: policy)
    }

    public static func displayPercent(_ fraction: Double, isComplete: Bool) -> Int {
        if isComplete { return 100 }
        return min(99, max(0, Int((fraction * 100).rounded(.down))))
    }

    public func knowledgeMap(examID: UUID, state: AppState, now: Date) -> [UUID: ObjectiveKnowledge] {
        guard let exam = state.exam(examID) else { return [:] }
        let objectives = state.objectives(for: examID)
        let questions = state.questionIndex
        let attemptsByObjective = Dictionary(grouping: state.attempts.filter { $0.examID == examID }, by: \.objectiveID)
        var result: [UUID: ObjectiveKnowledge] = [:]
        for o in objectives {
            result[o.id] = tracer.knowledge(for: o.id, attempts: attemptsByObjective[o.id] ?? [], questions: questions, prior: exam.priorKnowledge, now: now)
        }
        return result
    }

    public func progress(examID: UUID, state: AppState, now: Date) -> ExamProgress {
        let topics = state.topics(for: examID)
        let objectives = state.objectives(for: examID)
        let knowledge = knowledgeMap(examID: examID, state: state, now: now)
        return progress(examID: examID, topics: topics, objectives: objectives, knowledge: knowledge)
    }

    public func progress(examID: UUID, topics: [Topic], objectives: [LearningObjective], knowledge: [UUID: ObjectiveKnowledge]) -> ExamProgress {
        let weights = ObjectiveWeights.compute(topics: topics, objectives: objectives)
        var levelCounts: [MasteryLevel: Int] = [:]
        var fraction = 0.0
        var completeCount = 0
        for o in objectives {
            let k = knowledge[o.id]
            levelCounts[k?.level ?? .notStarted, default: 0] += 1
            fraction += weights.value(o.id) * (k?.score ?? 0)
            if k?.isComplete == true { completeCount += 1 }
        }
        let isComplete = !objectives.isEmpty && completeCount == objectives.count

        let byTopic = Dictionary(grouping: objectives, by: \.topicID)
        let topicProgress: [TopicProgress] = topics.compactMap { t in
            guard let objs = byTopic[t.id], !objs.isEmpty else { return nil }
            let w = objs.sum { o in weights.value(o.id) }
            let f = w > 0 ? objs.sum { o in weights.value(o.id) * (knowledge[o.id]?.score ?? 0) } / w : 0
            var counts: [MasteryLevel: Int] = [:]
            for o in objs { counts[knowledge[o.id]?.level ?? .notStarted, default: 0] += 1 }
            return TopicProgress(
                topic: t, objectiveCount: objs.count,
                completeCount: objs.filter { knowledge[$0.id]?.isComplete == true }.count,
                fraction: f, weight: w, levelCounts: counts
            )
        }

        return ExamProgress(
            examID: examID,
            fraction: isComplete ? 1 : min(fraction, 0.999),
            isComplete: isComplete,
            objectiveCount: objectives.count,
            completeCount: completeCount,
            levelCounts: levelCounts,
            topics: topicProgress,
            missing: missingRequirements(objectives: objectives, knowledge: knowledge),
            knowledge: knowledge,
            weights: weights
        )
    }

    func missingRequirements(objectives: [LearningObjective], knowledge: [UUID: ObjectiveKnowledge]) -> [MissingRequirement] {
        guard !objectives.isEmpty else {
            return [MissingRequirement(kind: .noObjectives, objectiveIDs: [], text: "Es gibt noch keine Lernziele. Lade Unterlagen hoch oder lege Themen an.")]
        }
        var groups: [MissingRequirement.Kind: [UUID]] = [:]
        for o in objectives {
            guard let k = knowledge[o.id], !k.isComplete else { continue }
            if k.level == .notStarted {
                groups[.notStarted, default: []].append(o.id)
            } else if k.level < .provisional {
                groups[.needsPractice, default: []].append(o.id)
            } else {
                if k.criterion(.spacedRecall)?.isMet == false { groups[.needsSpacedRecall, default: []].append(o.id) }
                if k.criterion(.hardOrTransfer)?.isMet == false { groups[.needsHardQuestion, default: []].append(o.id) }
                if k.level == .stable, k.criterion(.retention)?.isMet == false { groups[.reviewDue, default: []].append(o.id) }
            }
        }
        func n(_ count: Int, _ singular: String, _ plural: String) -> String { count == 1 ? "1 \(singular)" : "\(count) \(plural)" }
        let order: [MissingRequirement.Kind] = [.notStarted, .needsPractice, .needsSpacedRecall, .needsHardQuestion, .reviewDue]
        return order.compactMap { kind in
            guard let ids = groups[kind], !ids.isEmpty else { return nil }
            let text: String
            switch kind {
            case .noObjectives: text = ""
            case .notStarted: text = "\(n(ids.count, "Lernziel ist", "Lernziele sind")) noch nicht begonnen."
            case .needsPractice: text = "\(n(ids.count, "Lernziel braucht", "Lernziele brauchen")) noch sichere, richtige Antworten."
            case .needsSpacedRecall: text = "\(n(ids.count, "Lernziel braucht", "Lernziele brauchen")) eine Wiederholung an einem anderen Tag."
            case .needsHardQuestion: text = "\(n(ids.count, "Lernziel braucht", "Lernziele brauchen")) noch eine schwierigere Aufgabe."
            case .reviewDue: text = "\(n(ids.count, "Lernziel ist", "Lernziele sind")) zur Wiederholung fällig, damit das Wissen präsent bleibt."
            }
            return MissingRequirement(kind: kind, objectiveIDs: ids, text: text)
        }
    }
}

/// Prüft, ob die Kriterien für die vollständige Tagesfreigabe (100 %) erfüllt sind.
public struct FullMasteryStatus: Hashable, Sendable {
    public struct ExamEntry: Hashable, Sendable {
        public var examID: UUID
        public var title: String
        public var percent: Int
        public var isComplete: Bool
        public var missing: [MissingRequirement]
    }

    public var isComplete: Bool
    public var entries: [ExamEntry]
    public var explanation: String
}

public enum FullMasteryEvaluator {
    /// 100 % gilt, wenn JEDE aktive Prüfung vollständig beherrscht ist.
    /// Ohne aktive Prüfung mit Lernzielen gibt es keine Freigabe.
    public static func evaluate(state: AppState, now: Date, calendar: Calendar) -> FullMasteryStatus {
        let calculator = ProgressCalculator(policy: state.masteryPolicy)
        let exams = state.activeExams(now: now, calendar: calendar)
        let entries = exams.map { exam -> FullMasteryStatus.ExamEntry in
            let p = calculator.progress(examID: exam.id, state: state, now: now)
            return .init(examID: exam.id, title: exam.title, percent: p.percent, isComplete: p.isComplete, missing: p.missing)
        }
        if entries.isEmpty {
            return FullMasteryStatus(isComplete: false, entries: [], explanation: "Lege eine Prüfung mit Lernzielen an, um 100 % erreichen zu können.")
        }
        let complete = entries.allSatisfy(\.isComplete)
        let explanation: String
        if complete {
            explanation = "Alle Lernziele sind stabil beherrscht und aktuell präsent."
        } else {
            let open = entries.filter { !$0.isComplete }.map { "\($0.title): \($0.percent) %" }
            explanation = "Noch nicht vollständig: " + open.joined(separator: ", ")
        }
        return FullMasteryStatus(isComplete: complete, entries: entries, explanation: explanation)
    }
}
