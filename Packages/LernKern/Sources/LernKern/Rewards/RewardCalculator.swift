import Foundation

public struct RewardGrant: Hashable, Sendable {
    public var minutes: Int
    public var passed: Bool
    /// Schwierigkeitsgewichtete Genauigkeit 0…1.
    public var accuracy: Double
    public var eligibleAnswers: Int
    /// Nachvollziehbare Aufschlüsselung der Berechnung.
    public var lines: [String]
    public var wasCapped: Bool
}

public struct CheckRewardInput: Sendable {
    public var attempts: [Attempt]
    public var questions: [UUID: Question]
    /// Alle Antworten VOR dieser Überprüfung (für Wiederholungs- und Abstandserkennung).
    public var earlierAttempts: [Attempt]
    public var knowledgeBefore: [UUID: ObjectiveKnowledge]
    public var knowledgeAfter: [UUID: ObjectiveKnowledge]
    public var phase: RewardPhase
    public var earnedToday: Int
    public var balance: Int

    public init(attempts: [Attempt], questions: [UUID: Question], earlierAttempts: [Attempt], knowledgeBefore: [UUID: ObjectiveKnowledge], knowledgeAfter: [UUID: ObjectiveKnowledge], phase: RewardPhase, earnedToday: Int, balance: Int) {
        self.attempts = attempts
        self.questions = questions
        self.earlierAttempts = earlierAttempts
        self.knowledgeBefore = knowledgeBefore
        self.knowledgeAfter = knowledgeAfter
        self.phase = phase
        self.earnedToday = earnedToday
        self.balance = balance
    }
}

/// Berechnet verdiente Bildschirmzeit. Dokumentation: docs/BELOHNUNGEN.md
///
/// Grundsätze:
/// - Nur geprüfte Lernleistung zählt (Antworten in einer Wissensüberprüfung), nie das Öffnen der App.
/// - Durchklicken (zu schnelle Antworten) und kürzlich schon richtig beantwortete Fragen zählen nicht.
/// - Leichte Fragen zu bereits stabil beherrschtem Stoff zählen kaum (keine "Trivialfragen-Farm").
/// - Echte Verbesserung wird auch belohnt, wenn die Überprüfung noch nicht bestanden ist.
/// - Tageslimit und Kontolimit verhindern Horten.
public struct RewardCalculator: Sendable {
    public var policy: RewardPolicy

    public init(policy: RewardPolicy = .standard) {
        self.policy = policy
    }

    public func rewardForCheck(_ input: CheckRewardInput) -> RewardGrant {
        var lines: [String] = []
        let cooldown = policy.repeatCooldownHours * 3600

        var eligible: [Attempt] = []
        var tooFast = 0
        var repeated = 0
        for a in input.attempts where !a.isVoided {
            if a.durationSeconds < policy.minSecondsPerAnswer { tooFast += 1; continue }
            let recentlyCorrect = input.earlierAttempts.contains {
                $0.questionID == a.questionID && $0.isCorrect && !$0.isVoided
                    && $0.answeredAt <= a.answeredAt && a.answeredAt.timeIntervalSince($0.answeredAt) < cooldown
            }
            if recentlyCorrect { repeated += 1; continue }
            eligible.append(a)
        }
        if tooFast > 0 { lines.append("\(tooFast) Antwort(en) zu schnell gegeben – zählen nicht.") }
        if repeated > 0 { lines.append("\(repeated) Frage(n) wurden kürzlich schon richtig beantwortet – zählen erst später wieder.") }

        // Schwierigkeitsgewichtete Genauigkeit
        var weightedScore = 0.0
        var weightSum = 0.0
        var hardCorrect = 0
        for a in eligible {
            let q = input.questions[a.questionID]
            var dw: Double
            switch q?.difficulty ?? .medium {
            case .easy: dw = 0.7
            case .medium: dw = 1.0
            case .hard: dw = 1.4
            }
            if q?.isTransfer == true { dw += 0.2 }
            if let before = input.knowledgeBefore[a.objectiveID], before.level == .stable, before.retrievability >= 0.95, q?.difficulty == .easy {
                dw *= 0.3
            }
            let gw = a.grading.evidenceWeight
            weightedScore += a.score * dw * gw
            weightSum += dw * gw
            if a.isCorrect && (q?.difficulty == .hard || q?.isTransfer == true) { hardCorrect += 1 }
        }
        let accuracy = weightSum > 0 ? weightedScore / weightSum : 0
        let threshold = input.phase.passThreshold
        let enough = eligible.count >= policy.minQuestionsPerCheck
        let passed = enough && accuracy >= threshold

        var minutes = 0
        if !enough {
            lines.append("Für eine Belohnung braucht es mindestens \(policy.minQuestionsPerCheck) gültige Antworten (hier: \(eligible.count)).")
        } else if passed {
            let quality = MathUtil.clamp((accuracy - threshold) / max(0.01, 1 - threshold), 0, 1)
            let effort = min(1, Double(eligible.count) / 6)
            let base = policy.baseMinutesPerCheck + Int((Double(policy.maxMinutesPerCheck - policy.baseMinutesPerCheck) * quality * effort).rounded())
            minutes += base
            lines.append("Wissensüberprüfung bestanden (\(Self.percent(accuracy)) richtig, nötig \(Self.percent(threshold))): +\(base) Min.")
            if input.phase == .refinement || input.phase == .maintenance, hardCorrect > 0 {
                let bonus = min(3, hardCorrect)
                minutes += bonus
                lines.append("Anspruchsvolle Aufgaben gelöst: +\(bonus) Min.")
            }
        } else {
            lines.append("Noch nicht bestanden (\(Self.percent(accuracy)) richtig, nötig \(Self.percent(threshold))) – keine Grundbelohnung.")
        }

        // Fortschrittsboni (nur mit genügend gültigen Antworten)
        if enough {
            let objectiveIDs = Set(eligible.map(\.objectiveID))
            var provisionalUps = 0
            var stableUps = 0
            var improvement = 0.0
            for id in objectiveIDs {
                let before = input.knowledgeBefore[id]
                guard let after = input.knowledgeAfter[id] else { continue }
                let beforeLevel = before?.level ?? .notStarted
                if beforeLevel < .provisional && after.level >= .provisional { provisionalUps += 1 }
                if beforeLevel < .stable && after.level == .stable { stableUps += 1 }
                improvement += max(0, after.probabilityMedium - (before?.probabilityMedium ?? after.probabilityMedium))
            }
            if provisionalUps > 0 {
                let b = provisionalUps * policy.provisionalBonus
                minutes += b
                lines.append("\(provisionalUps) Lernziel(e) jetzt vorläufig beherrscht: +\(b) Min.")
            }
            if stableUps > 0 {
                let b = stableUps * policy.stableBonus
                minutes += b
                lines.append("\(stableUps) Lernziel(e) jetzt stabil beherrscht: +\(b) Min.")
            }

            let spacedObjectives = Set(eligible.filter { a in
                guard a.isCorrect else { return false }
                guard let previous = input.earlierAttempts.filter({ $0.objectiveID == a.objectiveID && $0.isSuccess && !$0.isVoided && $0.answeredAt < a.answeredAt }).map(\.answeredAt).max() else { return false }
                return a.answeredAt.timeIntervalSince(previous) >= cooldown
            }.map(\.objectiveID))
            if !spacedObjectives.isEmpty, policy.spacedReviewBonus > 0 {
                let b = min(3, spacedObjectives.count) * policy.spacedReviewBonus
                minutes += b
                lines.append("Wissen nach zeitlichem Abstand abgerufen: +\(b) Min.")
            }

            if (input.phase == .foundation || input.phase == .building) && improvement >= 0.1 && policy.improvementBonus > 0 {
                minutes += policy.improvementBonus
                lines.append("Messbare Verbesserung: +\(policy.improvementBonus) Min.")
            }
        }

        return applyCaps(minutes: minutes, passed: passed, accuracy: accuracy, eligible: eligible.count, lines: lines, earnedToday: input.earnedToday, balance: input.balance)
    }

    public func rewardForSimulation(_ result: ExamSimulationResult, attempts: [Attempt], targetMinFraction: Double, earnedToday: Int, balance: Int) -> RewardGrant {
        var lines: [String] = []
        let valid = attempts.filter { !$0.isVoided && $0.durationSeconds >= policy.minSecondsPerAnswer }
        let share = result.questionIDs.isEmpty ? 0 : Double(valid.count) / Double(result.questionIDs.count)
        guard share >= 0.8 else {
            lines.append("Simulation zu weniger als 80 % bearbeitet – keine Belohnung.")
            return RewardGrant(minutes: 0, passed: false, accuracy: result.scoreFraction, eligibleAnswers: valid.count, lines: lines, wasCapped: false)
        }
        let quality = MathUtil.clamp((result.scoreFraction - 0.4) / 0.5, 0, 1)
        var minutes = policy.simulationBaseMinutes + Int((Double(policy.simulationMaxMinutes - policy.simulationBaseMinutes) * quality).rounded())
        lines.append("Prüfungssimulation abgeschlossen (\(Self.percent(result.scoreFraction)) der Punkte): +\(minutes) Min.")
        let reached = result.scoreFraction >= targetMinFraction
        if reached, policy.simulationTargetBonus > 0 {
            minutes += policy.simulationTargetBonus
            lines.append("Zielnote in der Simulation erreicht: +\(policy.simulationTargetBonus) Min.")
        }
        return applyCaps(minutes: minutes, passed: reached, accuracy: result.scoreFraction, eligible: valid.count, lines: lines, earnedToday: earnedToday, balance: balance)
    }

    func applyCaps(minutes: Int, passed: Bool, accuracy: Double, eligible: Int, lines: [String], earnedToday: Int, balance: Int) -> RewardGrant {
        var lines = lines
        let remainingToday = max(0, policy.dailyEarnCap - earnedToday)
        let remainingBalance = max(0, policy.maxBalance - balance)
        let final = max(0, min(minutes, remainingToday, remainingBalance))
        let capped = final < minutes
        if capped {
            if remainingToday < minutes { lines.append("Tageslimit von \(policy.dailyEarnCap) Min. erreicht – \(minutes - final) Min. nicht gutgeschrieben.") }
            else { lines.append("Kontolimit von \(policy.maxBalance) Min. erreicht – löse zuerst Minuten ein.") }
        }
        return RewardGrant(minutes: final, passed: passed, accuracy: accuracy, eligibleAnswers: eligible, lines: lines, wasCapped: capped)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}
