import Foundation

public struct ReadinessComponent: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 0…1 oder nil, wenn noch keine Daten vorliegen.
    public var value: Double?
    public var weight: Double
    public var explanation: String
}

/// Prüfungstauglichkeit: Wie gut bist du auf DIESE Prüfung vorbereitet?
/// Unterscheidet sich vom Lernfortschritt, weil sie Prüfungsbedingungen abbildet
/// (neue Fragen, Simulationen, Behalten) statt erfüllter Lernkriterien.
public struct ExamReadiness: Hashable, Sendable {
    public var score: Int?
    public var components: [ReadinessComponent]
    public var headline: String
    public var isLimited: Bool
}

public enum ReadinessCalculator {
    public static func readiness(
        exam: Exam,
        objectives: [LearningObjective],
        weights: [UUID: Double],
        knowledge: [UUID: ObjectiveKnowledge],
        forecast: GradeForecast,
        simulations: [ExamSimulationResult],
        now: Date
    ) -> ExamReadiness {
        let target = max(0.3, exam.targetBand.minFraction)
        let practiced = objectives.filter { (knowledge[$0.id]?.stabilityDays ?? 0) > 0 }
        let practicedWeight = practiced.sum { o in weights.value(o.id) }
        let retention: Double? = practicedWeight > 0
            ? practiced.sum { o in weights.value(o.id) * (knowledge[o.id]?.retrievability ?? 0) } / practicedWeight
            : nil
        let consistencyBase = objectives.filter { (knowledge[$0.id]?.attemptCount ?? 0) >= 3 }
        let consistency: Double? = consistencyBase.isEmpty ? nil
            : Double(consistencyBase.filter { knowledge[$0.id]?.criterion(.consistency)?.isMet == true }.count) / Double(consistencyBase.count)
        let latestSim = simulations
            .filter { $0.examID == exam.id && $0.answeredShare >= 0.8 && now.timeIntervalSince($0.finishedAt) <= 21 * 86_400 }
            .max { $0.finishedAt < $1.finishedAt }
        let newQuestions = forecast.firstExposureAccuracy.map { min(1, $0 / target) }

        let components = [
            ReadinessComponent(id: "coverage", title: "Stoffabdeckung", value: objectives.isEmpty ? nil : forecast.coverage, weight: 0.25,
                               explanation: "Anteil der Lernziele, zu denen du schon mehrere Aufgaben gelöst hast."),
            ReadinessComponent(id: "retention", title: "Behalten", value: retention, weight: 0.2,
                               explanation: "Wie präsent dein geübtes Wissen gerade ist (Vergessenskurve)."),
            ReadinessComponent(id: "newQuestions", title: "Neue Fragen", value: newQuestions, weight: 0.2,
                               explanation: "Leistung bei Fragen, die du zum ersten Mal gesehen hast – im Verhältnis zu deinem Ziel."),
            ReadinessComponent(id: "simulation", title: "Prüfungssimulation", value: latestSim.map { min(1, $0.scoreFraction / target) }, weight: 0.25,
                               explanation: "Ergebnis deiner letzten Simulation (max. 3 Wochen alt) im Verhältnis zu deinem Ziel."),
            ReadinessComponent(id: "consistency", title: "Beständigkeit", value: consistency, weight: 0.1,
                               explanation: "Anteil der Lernziele, bei denen deine letzten Antworten beständig richtig waren."),
        ]
        let available = components.filter { $0.value != nil }
        let weightSum = available.sum { $0.weight }
        guard weightSum >= 0.45 else {
            return ExamReadiness(score: nil, components: components, headline: "Noch zu wenige Daten für einen Prüfungstauglichkeits-Score.", isLimited: true)
        }
        var score = available.sum { c in c.weight * (c.value ?? 0) } / weightSum * 100
        let limited = latestSim == nil
        if limited { score = min(score, 85) }
        let rounded = Int(score.rounded())
        let headline: String
        switch rounded {
        case 85...: headline = "Du bist sehr gut auf diese Prüfung vorbereitet."
        case 70..<85: headline = "Du bist gut vorbereitet – an einzelnen Stellen geht noch mehr."
        case 50..<70: headline = "Solide Basis, aber noch deutliche Lücken."
        default: headline = "Noch ein gutes Stück Weg bis zur Prüfungsreife."
        }
        return ExamReadiness(score: rounded, components: components,
                             headline: limited ? headline + " Eine Prüfungssimulation macht den Wert aussagekräftiger." : headline,
                             isLimited: limited)
    }
}
