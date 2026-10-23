import Foundation

/// Zeitspanne in Minuten (bewusst keine scheinbar exakte Zahl).
public struct MinuteRange: Hashable, Sendable {
    public var low: Int
    public var high: Int

    public init(low: Int, high: Int) {
        self.low = max(0, min(low, high))
        self.high = max(0, max(low, high))
    }

    public static let zero = MinuteRange(low: 0, high: 0)

    /// "12–18 Std." bzw. "40–60 Min."
    public var text: String {
        if high == 0 { return "keine weitere Lernzeit nötig" }
        if high < 90 {
            return "\(Self.roundTo(low, 5))–\(max(Self.roundTo(high, 5), Self.roundTo(low, 5) + 5)) Min."
        }
        let lo = Double(low) / 60
        let hi = Double(high) / 60
        let loText = lo < 10 ? String(format: "%.1f", lo).replacingOccurrences(of: ".", with: ",") : String(Int(lo.rounded()))
        let hiText = hi < 10 ? String(format: "%.1f", hi).replacingOccurrences(of: ".", with: ",") : String(Int(hi.rounded()))
        return "\(loText)–\(hiText) Std."
    }

    /// Einzelwert, z. B. "6 Std." oder "45 Min."
    public static func approximate(_ minutes: Int) -> String {
        if minutes < 90 { return "\(roundTo(minutes, 5)) Min." }
        let hours = Double(minutes) / 60
        if hours >= 10 { return "\(Int(hours.rounded())) Std." }
        return String(format: "%.1f", hours).replacingOccurrences(of: ".", with: ",") + " Std."
    }

    static func roundTo(_ value: Int, _ step: Int) -> Int { max(0, Int((Double(value) / Double(step)).rounded()) * step) }

    func scaled(_ f: Double) -> MinuteRange { MinuteRange(low: Int(Double(low) * f), high: Int(Double(high) * f)) }
}

public enum ScheduleFeasibility: String, Hashable, Sendable {
    case comfortable
    case tight
    case unrealistic

    public var title: String {
        switch self {
        case .comfortable: return "Gut machbar"
        case .tight: return "Knapp"
        case .unrealistic: return "Unter den aktuellen Bedingungen unrealistisch"
        }
    }
}

/// Handlungsoption, wenn das Ziel knapp oder unrealistisch wird. Das Ziel wird nie heimlich geändert.
public struct GoalScenario: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case moreTime, adjustTarget, focusCore, keepGoing }
    public var id: Kind { kind }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// Bei `adjustTarget`: vorgeschlagene Note.
    public var suggestedGradeID: String?
    /// Bei `moreTime`: zusätzliche Minuten pro Tag.
    public var extraMinutesPerDay: Int?
}

public struct TimeForecast: Hashable, Sendable {
    public var examID: UUID
    /// Bis alle Lernziele erstmals ausreichend (vorläufig) beherrscht sind.
    public var toProvisional: MinuteRange
    /// Bis alle Lernziele stabil beherrscht sind.
    public var toStable: MinuteRange
    /// Bis zur angestrebten Prüfungsleistung (nil = im Modell nicht erreichbar).
    public var toTarget: MinuteRange?
    public var availableMinutes: Int
    public var daysUntilExam: Int
    public var feasibility: ScheduleFeasibility
    public var scenarios: [GoalScenario]
    public var headline: String
    public var details: [String]
}

/// Schätzt die noch nötige konzentrierte Lernzeit – aus offenen Lernzielen, eigenem Tempo,
/// Erfolgsquote und nötigen Wiederholungen (nicht aus der Seitenzahl).
public struct TimeEstimator: Sendable {
    public var policy: MasteryPolicy
    public static let defaultSecondsPerQuestion = 75.0

    public init(policy: MasteryPolicy = .standard) {
        self.policy = policy
    }

    struct ObjectivePlan {
        var p0: Double
        var levels: [(p: Double, cost: Double)]
        var toProvisional: Double
        var toStable: Double
    }

    // Lösungswahrscheinlichkeit bei Prüfungsmischung für ausgewählte Fähigkeitswerte.
    static func examMix(theta: Double) -> Double {
        KnowledgeTracer.examDifficultyMix.sum { entry in entry.1 * MathUtil.sigmoid(theta - entry.0.logit) }
    }

    public func estimate(
        exam: Exam,
        topics: [Topic],
        objectives: [LearningObjective],
        knowledge: [UUID: ObjectiveKnowledge],
        forecast: GradeForecast?,
        preferences: StudyPreferences,
        completedTasks: [StudyTask],
        now: Date,
        calendar: Calendar
    ) -> TimeForecast {
        let weights = ObjectiveWeights.compute(topics: topics, objectives: objectives)
        let allSeconds = knowledge.values.compactMap(\.averageSecondsPerQuestion)
        let personalSeconds = allSeconds.isEmpty ? Self.defaultSecondsPerQuestion : allSeconds.reduce(0, +) / Double(allSeconds.count)
        let questionMinutes = personalSeconds / 60 + 0.5
        let speed = speedFactor(completedTasks)

        var plans: [UUID: ObjectivePlan] = [:]
        var totalProvisional = 0.0
        var totalStable = 0.0
        var evidence = 0.0
        for o in objectives {
            let plan = objectivePlan(o, knowledge[o.id], prior: exam.priorKnowledge, questionMinutes: questionMinutes, speed: speed)
            plans[o.id] = plan
            totalProvisional += plan.toProvisional
            totalStable += plan.toStable
            evidence += knowledge[o.id]?.evidence ?? 0
        }

        let spread: (Double, Double) = evidence < 30 ? (0.7, 1.6) : (0.8, 1.3)
        func range(_ minutes: Double) -> MinuteRange {
            MinuteRange(low: Int((minutes * spread.0).rounded()), high: Int((minutes * spread.1).rounded()))
        }

        let modelScore = objectives.sum { o in weights.value(o.id) * (plans[o.id]?.p0 ?? 0) }
        let offset = (forecast?.expectedScore).map { $0 - modelScore } ?? 0
        let margin = exam.gradeScale.isOfficial ? 0.03 : 0.05
        let targetFraction = min(0.98, exam.targetBand.minFraction + margin)
        let targetMinutes = costToReach(targetFraction, start: modelScore + offset, objectives: objectives, weights: weights, plans: plans)

        let days = max(0, exam.daysUntilExam(from: now, calendar: calendar))
        let available = availableMinutes(preferences: preferences, from: now, days: days, completedTasks: completedTasks, calendar: calendar)

        let needed = targetMinutes.map(range) ?? range(totalStable)
        let feasibility: ScheduleFeasibility
        if targetMinutes == nil { feasibility = .unrealistic }
        else if Double(needed.high) <= Double(available) * 0.85 { feasibility = .comfortable }
        else if needed.low <= available { feasibility = .tight }
        else { feasibility = .unrealistic }

        var scenarios: [GoalScenario] = []
        if feasibility != .comfortable {
            if days > 0, targetMinutes != nil {
                let deficit = max(0, Double(needed.low) - Double(available) * 0.85)
                let perDay = Int((deficit / Double(days) / 15).rounded(.up)) * 15
                if perDay > 0 && perDay <= 180 {
                    scenarios.append(GoalScenario(kind: .moreTime, title: "Mehr Lernzeit einplanen",
                                                  detail: "Mit etwa \(perDay) Minuten mehr pro Tag wird deine Zielnote realistischer.",
                                                  suggestedGradeID: nil, extraMinutesPerDay: perDay))
                }
            }
            if let achievable = bestAchievableBand(exam: exam, start: modelScore + offset, available: Double(available) / spread.1 * 0.85,
                                                   objectives: objectives, weights: weights, plans: plans),
               achievable.id != exam.targetGradeID {
                scenarios.append(GoalScenario(kind: .adjustTarget, title: "Ziel anpassen",
                                              detail: "Mit deiner verfügbaren Zeit ist voraussichtlich eine \(achievable.label) (\(achievable.name)) gut erreichbar. Du entscheidest, ob du dein Ziel änderst.",
                                              suggestedGradeID: achievable.id, extraMinutesPerDay: nil))
            }
            let coreTopics = topics.filter { $0.importance == .core }
            if !coreTopics.isEmpty {
                scenarios.append(GoalScenario(kind: .focusCore, title: "Auf Kernthemen konzentrieren",
                                              detail: "Zuerst: \(coreTopics.prefix(3).map(\.title).joined(separator: ", ")). Diese bringen die meisten Punkte.",
                                              suggestedGradeID: nil, extraMinutesPerDay: nil))
            }
        }

        var details: [String] = []
        let open = objectives.filter { knowledge[$0.id]?.level ?? .notStarted < .provisional }.count
        details.append("Berücksichtigt: \(open) noch nicht sicher beherrschte Lernziele, nötige Wiederholungen und dein Tempo (ø \(Int(personalSeconds.rounded())) s pro Frage).")
        if days > 0 { details.append("Bis zur Prüfung stehen dir etwa \(MinuteRange.approximate(available)) zur Verfügung (\(days) Tage, abzüglich Puffer).") }
        if totalStable > totalProvisional, days == 0 { details.append("Für stabile Beherrschung ist eine Wiederholung an einem anderen Tag nötig – das geht vor der Prüfung nicht mehr.") }

        let headline: String
        if let target = targetMinutes {
            headline = target < 1 ? "Dein Ziel ist in Reichweite – jetzt geht es ums Wissen-Frischhalten."
                                  : "Voraussichtlich noch \(range(target).text) konzentrierte Lernzeit, um dein aktuelles Ziel zu erreichen."
        } else {
            headline = "Deine Zielnote ist mit dem aktuellen Stoffumfang schwer erreichbar – sieh dir die Möglichkeiten an."
        }

        return TimeForecast(
            examID: exam.id,
            toProvisional: range(totalProvisional),
            toStable: range(totalStable),
            toTarget: targetMinutes.map(range),
            availableMinutes: available,
            daysUntilExam: days,
            feasibility: feasibility,
            scenarios: scenarios,
            headline: headline,
            details: details
        )
    }

    func objectivePlan(_ o: LearningObjective, _ k: ObjectiveKnowledge?, prior: PriorKnowledge, questionMinutes: Double, speed: Double) -> ObjectivePlan {
        let p = policy
        let thetaProv = MathUtil.logit(p.provisionalProbability)
        let theta = k?.ability ?? MathUtil.logit(prior.priorProbability)
        let pMedium = max(0.35, k?.probabilityMedium ?? prior.priorProbability)
        let learn = (k?.level ?? .notStarted) == .notStarted ? Double(o.estimatedMinutes) * speed : 0

        let neededCorrect = max(0, p.requiredCorrect - (k?.weightedCorrect ?? 0))
        let neededDistinct = Double(max(0, p.requiredDistinctQuestions - (k?.distinctCorrectQuestions ?? 0)))
        let abilityAttempts = theta < thetaProv ? ((thetaProv - theta) / 0.3).rounded(.up) : 0
        let provisionalAttempts = max(neededCorrect / pMedium, neededDistinct / pMedium, abilityAttempts)
        let toProvisional = learn + provisionalAttempts * questionMinutes

        let spacedNeeded = Double(max(0, p.requiredSpacedSuccesses - (k?.spacedSuccesses ?? 0)))
        let hardNeeded = Double(max(0, p.requiredHardOrTransfer - (k?.hardOrTransferCorrect ?? 0)))
        let pHard = max(0.3, MathUtil.sigmoid(max(theta, thetaProv) - 1))
        let retentionRefresh = (k?.level == .stable && k?.criterion(.retention)?.isMet == false) ? 2 * questionMinutes : 0
        let toStable = toProvisional + spacedNeeded * 3 * questionMinutes + hardNeeded / pHard * questionMinutes * 1.5 + retentionRefresh

        let p0: Double
        if let k, k.attemptCount > 0 {
            p0 = k.probabilityExamMix * (0.55 + 0.45 * (k.stabilityDays > 0 ? k.retrievability : 0.5))
        } else {
            p0 = prior.priorProbability
        }
        let thetaExpert = 2.5
        let expertExtra = max(0, thetaExpert - max(theta, 1.6)) / 0.25 * questionMinutes * 1.2 + 3 * questionMinutes
        let levels: [(p: Double, cost: Double)] = [
            (Self.examMix(theta: max(theta, thetaProv)), toProvisional),
            (Self.examMix(theta: max(theta, 1.6)), toStable),
            (Self.examMix(theta: max(theta, thetaExpert)), toStable + expertExtra),
        ]
        return ObjectivePlan(p0: p0, levels: levels, toProvisional: toProvisional, toStable: toStable)
    }

    /// Gierige Auswahl: Lernziele mit dem größten Punktgewinn pro Minute zuerst.
    func costToReach(_ target: Double, start: Double, objectives: [LearningObjective], weights: [UUID: Double], plans: [UUID: ObjectivePlan]) -> Double? {
        var expected = start
        if expected >= target {
            // Ziel erreicht: nur fällige Auffrischungen
            return 0
        }
        var levelIndex: [UUID: Int] = [:]
        var currentP: [UUID: Double] = [:]
        var currentCost: [UUID: Double] = [:]
        for o in objectives {
            levelIndex[o.id] = 0
            currentP[o.id] = plans[o.id]?.p0 ?? 0
            currentCost[o.id] = 0
        }
        var total = 0.0
        var guardCounter = 0
        while expected < target && guardCounter < objectives.count * 4 {
            guardCounter += 1
            var best: (id: UUID, gain: Double, cost: Double, ratio: Double, nextIndex: Int)?
            for o in objectives {
                guard let plan = plans[o.id], let idx = levelIndex[o.id] else { continue }
                var i = idx
                while i < plan.levels.count {
                    let level = plan.levels[i]
                    let gain: Double = weights.value(o.id) * (level.p - currentP.value(o.id))
                    if gain > 1e-6 {
                        let cost = max(0.5, level.cost - (currentCost[o.id] ?? 0))
                        let ratio = gain / cost
                        if best == nil || ratio > best!.ratio { best = (o.id, gain, cost, ratio, i) }
                        break
                    }
                    i += 1
                }
            }
            guard let pick = best else { return nil }
            expected += pick.gain
            total += pick.cost
            currentP[pick.id] = plans[pick.id]!.levels[pick.nextIndex].p
            currentCost[pick.id] = plans[pick.id]!.levels[pick.nextIndex].cost
            levelIndex[pick.id] = pick.nextIndex + 1
        }
        return expected >= target ? total : nil
    }

    func bestAchievableBand(exam: Exam, start: Double, available: Double, objectives: [LearningObjective], weights: [UUID: Double], plans: [UUID: ObjectivePlan]) -> GradeBand? {
        let margin = exam.gradeScale.isOfficial ? 0.03 : 0.05
        for band in exam.gradeScale.bands where band.isPassing {
            let target = min(0.98, band.minFraction + margin)
            if let cost = costToReach(target, start: start, objectives: objectives, weights: weights, plans: plans), cost <= available {
                return band
            }
        }
        return nil
    }

    /// Verhältnis tatsächlicher zu geplanter Lernzeit (begrenzt), nur aus abgeschlossenen Einheiten.
    func speedFactor(_ tasks: [StudyTask]) -> Double {
        let done = tasks.filter { $0.status == .completed && ($0.actualMinutes ?? 0) > 0 && $0.kind == .learn }
        guard done.count >= 3 else { return 1 }
        let planned = done.sum { Double($0.durationMinutes) }
        let actual = done.sum { $0.actualMinutes ?? 0 }
        guard planned > 0 else { return 1 }
        return MathUtil.clamp(actual / planned, 0.6, 1.8)
    }

    /// Verfügbare Lernminuten ab heute bis zum Vortag der Prüfung (abzüglich Puffer).
    public func availableMinutes(preferences: StudyPreferences, from now: Date, days: Int, completedTasks: [StudyTask], calendar: Calendar) -> Int {
        guard days > 0 else { return 0 }
        var total = 0.0
        let today = calendar.startOfDay(for: now)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            var minutes = Double(preferences.minutes(on: day, calendar: calendar))
            if offset == 0 {
                let doneToday = completedTasks.filter { $0.status == .completed && calendar.isDate($0.completedAt ?? $0.start, inSameDayAs: now) }
                    .sum { t in t.actualMinutes ?? Double(t.durationMinutes) }
                minutes = max(0, minutes - doneToday)
                let latest = Double(preferences.latestEndMinute)
                let nowMinute = Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
                minutes = min(minutes, max(0, latest - nowMinute))
            }
            total += minutes * (1 - preferences.bufferShare)
        }
        return Int(total.rounded())
    }
}
