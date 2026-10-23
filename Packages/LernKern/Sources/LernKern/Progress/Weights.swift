import Foundation

/// Gewichtung der Lernziele innerhalb einer Prüfung (Summe = 1).
///
/// - Bekannte Prüfungsanteile von Themen (z. B. aus dem Lehrplan) haben Vorrang.
/// - Sonst zählt die Wichtigkeit von Thema und Lernziel.
public enum ObjectiveWeights {
    public static func compute(topics: [Topic], objectives: [LearningObjective]) -> [UUID: Double] {
        let byTopic = Dictionary(grouping: objectives, by: \.topicID)
        let usedTopics = topics.filter { !(byTopic[$0.id]?.isEmpty ?? true) }
        guard !usedTopics.isEmpty else { return [:] }

        // Thema-Gewichte
        var topicWeight: [UUID: Double] = [:]
        let explicit = usedTopics.compactMap { t in t.examWeight.map { (t.id, max(0, $0)) } }
        let explicitSum = explicit.sum { $0.1 }
        let implicitTopics = usedTopics.filter { $0.examWeight == nil }
        func naturalWeight(_ t: Topic) -> Double {
            (byTopic[t.id] ?? []).sum { $0.importance.weight } * t.importance.weight
        }
        if explicit.isEmpty {
            for t in usedTopics { topicWeight[t.id] = naturalWeight(t) }
        } else {
            let remaining = max(0, 1 - explicitSum)
            for (id, w) in explicit { topicWeight[id] = w }
            let naturalSum = implicitTopics.sum { naturalWeight($0) }
            for t in implicitTopics {
                topicWeight[t.id] = naturalSum > 0 ? remaining * naturalWeight(t) / naturalSum : 0
            }
            // Wenn keine Restgewichte übrig sind, erhalten Themen ohne Angabe ein kleines Mindestgewicht,
            // damit sie nicht völlig unsichtbar werden.
            if remaining <= 0 {
                for t in implicitTopics { topicWeight[t.id] = 0.02 }
            }
        }

        var result: [UUID: Double] = [:]
        for t in usedTopics {
            let objs = byTopic[t.id] ?? []
            let inner = objs.sum { $0.importance.weight }
            for o in objs {
                let share: Double = inner > 0 ? o.importance.weight / inner : 0
                result[o.id] = topicWeight.value(t.id) * share
            }
        }
        let total = result.values.reduce(0, +)
        guard total > 0 else {
            let equal = 1 / Double(objectives.count)
            return Dictionary(uniqueKeysWithValues: objectives.map { ($0.id, equal) })
        }
        return result.mapValues { $0 / total }
    }
}
