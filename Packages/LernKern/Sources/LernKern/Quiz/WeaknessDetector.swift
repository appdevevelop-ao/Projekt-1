import Foundation

public struct WeaknessInsight: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Zwei Begriffe/Antworten werden wiederholt verwechselt.
        case confusion(String, String)
        case unitErrors
        /// Grundlagen sitzen, Anwendung auf neue/schwere Aufgaben noch nicht.
        case transferGap
        /// Wissen geht schnell verloren.
        case forgetting
        /// Wiederholte Schwierigkeiten mit einem Lernziel.
        case struggling
    }

    public var id: String
    public var kind: Kind
    public var objectiveIDs: [UUID]
    public var title: String
    public var detail: String
    public var suggestion: String
}

/// Erkennt wiederkehrende Fehlermuster statt nur einzelner falscher Antworten.
public enum WeaknessDetector {
    public static func detect(
        attempts: [Attempt],
        questions: [UUID: Question],
        objectives: [LearningObjective],
        knowledge: [UUID: ObjectiveKnowledge],
        now: Date,
        windowDays: Double = 30
    ) -> [WeaknessInsight] {
        let recent = attempts.filter { !$0.isVoided && now.timeIntervalSince($0.answeredAt) <= windowDays * 86_400 }
        let objectiveTitles = Dictionary(uniqueKeysWithValues: objectives.map { ($0.id, $0.title) })
        var insights: [WeaknessInsight] = []

        // 1. Verwechslungen
        var confusionCounts: [String: (a: String, b: String, objectives: Set<UUID>, count: Int)] = [:]
        for a in recent where !a.isCorrect {
            guard let distractor = a.chosenDistractor, let q = questions[a.questionID], q.kind == .multipleChoice,
                  let correctIndex = q.correctOptionIndices.first, q.options.indices.contains(correctIndex) else { continue }
            let correct = q.options[correctIndex]
            let pair = [TextNormalizer.normalize(correct), TextNormalizer.normalize(distractor)].sorted()
            let key = pair.joined(separator: "|")
            var entry = confusionCounts[key] ?? (correct, distractor, [], 0)
            entry.count += 1
            entry.objectives.insert(a.objectiveID)
            confusionCounts[key] = entry
        }
        for (key, entry) in confusionCounts where entry.count >= 2 && entry.a.count <= 80 && entry.b.count <= 80 {
            insights.append(WeaknessInsight(
                id: "confusion:\(key)", kind: .confusion(entry.a, entry.b), objectiveIDs: Array(entry.objectives),
                title: "„\(entry.a)“ und „\(entry.b)“ werden verwechselt",
                detail: "Das ist dir in den letzten Wochen \(entry.count)-mal passiert.",
                suggestion: "Eine Vergleichsübung zeigt die Unterschiede und prüft sie später erneut."
            ))
        }

        // 2. Einheitenfehler
        let unitErrors = recent.filter { $0.feedbackTags.contains("unitMissing") || $0.feedbackTags.contains("unitWrong") }
        if unitErrors.count >= 2 {
            insights.append(WeaknessInsight(
                id: "units", kind: .unitErrors, objectiveIDs: Array(Set(unitErrors.map(\.objectiveID))),
                title: "Einheiten fehlen oder stimmen nicht",
                detail: "\(unitErrors.count) Rechenaufgaben waren zahlenmäßig richtig, aber die Einheit fehlte oder war falsch.",
                suggestion: "Schreibe bei jedem Ergebnis die Einheit dazu und prüfe sie am Ende."
            ))
        }

        // 3.–5. je Lernziel
        let byObjective = Dictionary(grouping: recent, by: \.objectiveID)
        for (objectiveID, list) in byObjective {
            let title = objectiveTitles[objectiveID] ?? "Lernziel"
            let basic = list.filter { a in questions[a.questionID].map { $0.difficulty != .hard && !$0.isTransfer } ?? false }
            let advanced = list.filter { a in questions[a.questionID].map { $0.difficulty == .hard || $0.isTransfer } ?? false }
            if basic.count >= 3, advanced.count >= 2 {
                let basicRate = Double(basic.filter(\.isCorrect).count) / Double(basic.count)
                let advancedRate = Double(advanced.filter(\.isCorrect).count) / Double(advanced.count)
                if basicRate >= 0.8 && advancedRate <= 0.34 {
                    insights.append(WeaknessInsight(
                        id: "transfer:\(objectiveID)", kind: .transferGap, objectiveIDs: [objectiveID],
                        title: "„\(title)“: Grundlagen sitzen, Anwendung noch nicht",
                        detail: "Einfache Fragen gelingen dir meist, schwierigere Anwendungsaufgaben noch selten.",
                        suggestion: "Übe Schritt für Schritt mit Anwendungsaufgaben und lies die Lösungswege genau."
                    ))
                }
            }
            if let k = knowledge[objectiveID] {
                if k.lapses >= 2 {
                    insights.append(WeaknessInsight(
                        id: "forgetting:\(objectiveID)", kind: .forgetting, objectiveIDs: [objectiveID],
                        title: "„\(title)“ gerät schnell in Vergessenheit",
                        detail: "Du hast dieses Wissen schon \(k.lapses)-mal wieder verloren.",
                        suggestion: "Kürzere Wiederholungsabstände helfen – die App plant sie automatisch ein."
                    ))
                } else if k.isStruggling {
                    insights.append(WeaknessInsight(
                        id: "struggling:\(objectiveID)", kind: .struggling, objectiveIDs: [objectiveID],
                        title: "„\(title)“ bereitet Schwierigkeiten",
                        detail: "Die letzten Antworten waren überwiegend falsch.",
                        suggestion: "Lies die einfachere Erklärung und beginne mit leichteren Aufgaben."
                    ))
                }
            }
        }
        return insights.sorted { $0.id < $1.id }
    }
}
