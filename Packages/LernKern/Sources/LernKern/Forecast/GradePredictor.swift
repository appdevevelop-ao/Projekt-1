import Foundation

public enum ForecastConfidence: Int, Codable, Comparable, CaseIterable, Sendable {
    case insufficient = 0
    case low = 1
    case medium = 2
    case high = 3

    public var title: String {
        switch self {
        case .insufficient: return "Noch zu wenige Daten"
        case .low: return "Geringe Sicherheit"
        case .medium: return "Mittlere Sicherheit"
        case .high: return "Hohe Sicherheit"
        }
    }

    public static func < (lhs: ForecastConfidence, rhs: ForecastConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Wie wahrscheinlich das Ziel ist – nur so genau, wie die Datenlage es erlaubt.
public enum TargetLikelihood: Hashable, Sendable {
    /// Keine Aussage möglich.
    case unknown
    /// Grobe sprachliche Einschätzung (mittlere Sicherheit).
    case qualitative(String)
    /// Prozent-Spanne (nur bei hoher Sicherheit).
    case range(low: Int, high: Int)

    public var text: String {
        switch self {
        case .unknown: return "Noch keine Einschätzung möglich"
        case .qualitative(let s): return s
        case .range(let lo, let hi): return "etwa \(lo)–\(hi) %"
        }
    }
}

public struct TopicForecast: Hashable, Sendable, Identifiable {
    public var id: UUID { topicID }
    public var topicID: UUID
    public var title: String
    public var expectedFraction: Double
    /// Anteil der Gesamtpunkte, die in diesem Thema voraussichtlich verloren gehen.
    public var lostShare: Double
    public var weight: Double
    public var hasEvidence: Bool
}

public struct GradeForecast: Hashable, Sendable {
    public var examID: UUID
    public var expectedScore: Double
    public var scoreLow: Double
    public var scoreHigh: Double
    public var predictedBand: GradeBand
    public var bestBand: GradeBand
    public var worstBand: GradeBand
    public var targetBand: GradeBand
    public var confidence: ForecastConfidence
    public var targetLikelihood: TargetLikelihood
    /// Rohwert – wird nur bei hoher Sicherheit als Spanne gezeigt.
    public var targetProbability: Double
    public var topics: [TopicForecast]
    public var strongestTopics: [TopicForecast]
    public var weakestTopics: [TopicForecast]
    /// Gewichteter Anteil der Lernziele mit mindestens zwei Antworten.
    public var coverage: Double
    public var attemptCount: Int
    public var recentSimulationCount: Int
    public var firstExposureAccuracy: Double?
    public var scaleIsEstimate: Bool
    public var headline: String
    public var details: [String]
}

/// Notenprognose: "Welche Note würdest du erreichen, wenn die Prüfung heute wäre?"
///
/// Datengrundlage (dokumentiert in docs/LERNMODELL.md):
/// - je Lernziel die geschätzte Lösungswahrscheinlichkeit bei prüfungstypischer Schwierigkeit,
///   abgeschwächt durch Vergessen;
/// - Leistung bei neuen, zuvor nicht gesehenen Fragen;
/// - Ergebnisse aktueller Prüfungssimulationen (stärker gewichtet, je mehr und je aktueller);
/// - Unsicherheit aus Datenmenge, Abdeckung und (geschätzter) Notenskala.
public struct GradePredictor: Sendable {
    public init() {}

    public func forecast(
        exam: Exam,
        topics: [Topic],
        objectives: [LearningObjective],
        knowledge: [UUID: ObjectiveKnowledge],
        simulations: [ExamSimulationResult],
        now: Date
    ) -> GradeForecast {
        let scale = exam.gradeScale
        let target = exam.targetBand
        let weights = ObjectiveWeights.compute(topics: topics, objectives: objectives)

        guard !objectives.isEmpty else {
            let band = scale.band(for: 0)
            return GradeForecast(
                examID: exam.id, expectedScore: 0, scoreLow: 0, scoreHigh: 1, predictedBand: band,
                bestBand: scale.bands[0], worstBand: band, targetBand: target, confidence: .insufficient,
                targetLikelihood: .unknown, targetProbability: 0, topics: [], strongestTopics: [], weakestTopics: [],
                coverage: 0, attemptCount: 0, recentSimulationCount: 0, firstExposureAccuracy: nil,
                scaleIsEstimate: !scale.isOfficial,
                headline: "Noch zu wenige Daten für eine verlässliche Prognose.",
                details: ["Es gibt noch keine Lernziele. Lade zuerst Unterlagen hoch."]
            )
        }

        // 1. Modellschätzung je Lernziel
        var modelScore = 0.0
        var modelVariance = 0.0
        var coverage = 0.0
        var attempts = 0
        var feCount = 0
        var feSum = 0.0
        var pByObjective: [UUID: Double] = [:]
        for o in objectives {
            let w = weights[o.id] ?? 0
            let p: Double
            let v: Double
            if let k = knowledge[o.id], k.attemptCount > 0 {
                let retention = k.stabilityDays > 0 ? k.retrievability : 0.5
                p = k.probabilityExamMix * (0.55 + 0.45 * retention)
                v = p * (1 - p) / (k.evidence + 2) + 0.005
                if k.attemptCount >= 2 { coverage += w }
                attempts += k.attemptCount
                feCount += k.firstExposureAttempts
                feSum += k.firstExposureScoreSum
            } else {
                p = exam.priorKnowledge.priorProbability
                v = 0.06
            }
            pByObjective[o.id] = p
            modelScore += w * p
            modelVariance += w * w * v
        }
        let feAccuracy = feCount >= 10 ? feSum / Double(feCount) : nil
        if let fe = feAccuracy { modelScore = 0.85 * modelScore + 0.15 * fe }

        // 2. Prüfungssimulationen (letzte 21 Tage, max. 3, neuere stärker gewichtet)
        let recentSims = simulations
            .filter { $0.examID == exam.id && $0.answeredShare >= 0.8 && now.timeIntervalSince($0.finishedAt) <= 21 * 86_400 && $0.finishedAt <= now }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(3)
        var expected = modelScore
        var variance = modelVariance
        if let latest = recentSims.first {
            var wSum = 0.0
            var sSum = 0.0
            var n = 0
            for (i, s) in recentSims.enumerated() {
                let w = pow(0.6, Double(i))
                wSum += w
                sSum += w * s.scoreFraction
                n += s.questionIDs.count
            }
            let simScore = sSum / wSum
            let ageDays = now.timeIntervalSince(latest.finishedAt) / 86_400
            let alpha = min(0.6, 0.35 * Double(recentSims.count)) * exp(-ageDays / 14)
            let simVariance = simScore * (1 - simScore) / Double(max(5, n))
            expected = alpha * simScore + (1 - alpha) * modelScore
            variance = (1 - alpha) * (1 - alpha) * modelVariance + alpha * alpha * simVariance
        }
        let recentSimCount14 = recentSims.filter { now.timeIntervalSince($0.finishedAt) <= 14 * 86_400 }.count

        // 3. Unsicherheit
        var modelError = 0.06
        if !scale.isOfficial { modelError += 0.03 }
        if coverage < 0.5 { modelError += 0.04 }
        let sigma = (variance + modelError * modelError).squareRoot()
        let low = MathUtil.clamp(expected - 1.28 * sigma, 0, 1)
        let high = MathUtil.clamp(expected + 1.28 * sigma, 0, 1)

        // 4. Sicherheit der Prognose
        let confidence: ForecastConfidence
        if (coverage < 0.3 || attempts < 12) && !(recentSimCount14 >= 1 && coverage >= 0.2) {
            confidence = .insufficient
        } else if coverage < 0.6 || (attempts < 40 && recentSimCount14 == 0) {
            confidence = .low
        } else if coverage >= 0.85 && recentSimCount14 >= 1 && attempts >= 80 {
            confidence = .high
        } else {
            confidence = .medium
        }

        let targetProbability = 1 - MathUtil.normalCDF((target.minFraction - expected) / max(sigma, 0.01))
        let likelihood: TargetLikelihood
        switch confidence {
        case .insufficient, .low:
            likelihood = .unknown
        case .medium:
            if targetProbability < 0.25 { likelihood = .qualitative("eher unwahrscheinlich") }
            else if targetProbability < 0.6 { likelihood = .qualitative("offen") }
            else if targetProbability < 0.85 { likelihood = .qualitative("wahrscheinlich") }
            else { likelihood = .qualitative("sehr wahrscheinlich") }
        case .high:
            let center = (targetProbability * 20).rounded() * 5
            likelihood = .range(low: Int(max(0, center - 10)), high: Int(min(100, center + 10)))
        }

        // 5. Themen
        let byTopic = Dictionary(grouping: objectives, by: \.topicID)
        let topicForecasts: [TopicForecast] = topics.compactMap { t in
            guard let objs = byTopic[t.id], !objs.isEmpty else { return nil }
            let w = objs.sum { o in weights.value(o.id) }
            guard w > 0 else { return nil }
            let expectedFraction = objs.sum { o in weights.value(o.id) * pByObjective.value(o.id) } / w
            let lost = objs.sum { o in weights.value(o.id) * (1 - pByObjective.value(o.id)) }
            let evidence = objs.contains { (knowledge[$0.id]?.attemptCount ?? 0) > 0 }
            return TopicForecast(topicID: t.id, title: t.title, expectedFraction: expectedFraction, lostShare: lost, weight: w, hasEvidence: evidence)
        }
        let strongest = Array(topicForecasts.filter { $0.hasEvidence && $0.expectedFraction >= 0.6 }.sorted { $0.expectedFraction > $1.expectedFraction }.prefix(2))
        let weakest = Array(topicForecasts.filter { $0.lostShare > 0.02 }.sorted { $0.lostShare > $1.lostShare }.prefix(2))

        let predicted = scale.band(for: expected)
        let best = scale.band(for: high)
        let worst = scale.band(for: low)

        // 6. Texte
        var headline: String
        var details: [String] = []
        if confidence == .insufficient {
            headline = "Noch zu wenige Daten für eine verlässliche Prognose."
            details.append("Beantworte Fragen zu möglichst vielen Themen – dann wird die Einschätzung genauer.")
        } else {
            headline = "Deine aktuelle Leistung entspricht ungefähr einer \(predicted.label) (\(predicted.name))."
            if best.id != worst.id { details.append("Wahrscheinlicher Bereich: \(best.label) bis \(worst.label).") }
            if !strongest.isEmpty { details.append("Deine stärksten Themen: \(strongest.map(\.title).joined(separator: " und ")).") }
            if !weakest.isEmpty { details.append("Die meisten Punkte verlierst du noch bei: \(weakest.map(\.title).joined(separator: " und ")).") }
            if likelihood != .unknown { details.append("Chance auf deine Zielnote \(target.label): \(likelihood.text).") }
        }
        if let fe = feAccuracy { details.append("Bei neuen, unbekannten Fragen: \(Int((fe * 100).rounded())) % richtig.") }
        if !recentSims.isEmpty { details.append("\(recentSims.count) aktuelle Prüfungssimulation(en) fließen ein.") }
        if !scale.isOfficial { details.append("Die Notengrenzen sind geschätzt. Trage offizielle Grenzen ein, falls du sie kennst.") }
        details.append("Eine Prognose ist keine Garantie.")

        return GradeForecast(
            examID: exam.id, expectedScore: expected, scoreLow: low, scoreHigh: high,
            predictedBand: predicted, bestBand: best, worstBand: worst, targetBand: target,
            confidence: confidence, targetLikelihood: likelihood, targetProbability: targetProbability,
            topics: topicForecasts, strongestTopics: strongest, weakestTopics: weakest,
            coverage: coverage, attemptCount: attempts, recentSimulationCount: recentSimCount14,
            firstExposureAccuracy: feAccuracy, scaleIsEstimate: !scale.isOfficial,
            headline: headline, details: details
        )
    }

    /// Erwartete Punktzahl, wenn bestimmte Lernziele eine Ziel-Lösungswahrscheinlichkeit erreichen.
    static func projectedScore(objectives: [LearningObjective], weights: [UUID: Double], probability: [UUID: Double]) -> Double {
        objectives.sum { o in weights.value(o.id) * probability.value(o.id) }
    }
}
