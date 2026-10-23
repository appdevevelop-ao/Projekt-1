import Foundation

public struct ExamSnapshot: Sendable, Identifiable {
    public var id: UUID { exam.id }
    public var exam: Exam
    public var progress: ExamProgress
    public var forecast: GradeForecast
    public var time: TimeForecast
    public var readiness: ExamReadiness
    public var weaknesses: [WeaknessInsight]
    public var phase: RewardPhase
    public var daysUntilExam: Int
    /// Letzte Tage vor der Prüfung: Simulationen, Wiederholungen und Schwachstellen zuerst.
    public var isExamMode: Bool { daysUntilExam <= StudyPlanner.examModeDays }
}

public enum ScheduleStatus: Hashable, Sendable {
    case noPlan
    case onTrack
    case behind(missedTasks: Int, missedMinutes: Int)
}

/// Konkrete Empfehlung mit Begründung (transparenter Lerncoach).
public struct Recommendation: Hashable, Sendable {
    public var title: String
    public var reason: String
    public var taskID: UUID?
    public var examID: UUID?
    public var objectiveIDs: [UUID]
    public var kind: StudyTaskKind
}

public struct CoachSnapshot: Sendable {
    public var now: Date
    public var exams: [ExamSnapshot]
    public var knowledge: [UUID: ObjectiveKnowledge]
    public var todayTasks: [StudyTask]
    public var nextTask: StudyTask?
    public var dailyGoal: DailyGoalStatus?
    public var fullMastery: FullMasteryStatus
    /// 100 % erreicht UND heute durch eine bestandene Überprüfung bestätigt → Apps bis Mitternacht frei.
    public var fullDayUnlockEarned: Bool
    public var rewardBalance: Int
    public var earnedToday: Int
    public var schedule: ScheduleStatus
    public var recommendation: Recommendation?
    public var todayPlannedMinutes: Int
    public var todayCompletedMinutes: Int

    public func exam(_ id: UUID) -> ExamSnapshot? { exams.first { $0.exam.id == id } }
}

public enum CoachError: Error, Equatable, LocalizedError {
    case insufficientBalance(available: Int)
    case invalidMinutes
    case unknownExam

    public var errorDescription: String? {
        switch self {
        case .insufficientBalance(let available): return "Nicht genug Bildschirmzeit verdient (verfügbar: \(available) Min.)."
        case .invalidMinutes: return "Bitte wähle eine gültige Anzahl Minuten."
        case .unknownExam: return "Diese Prüfung gibt es nicht mehr."
        }
    }
}

/// Zentrale Fachlogik der App. Alle Operationen sind deterministische Funktionen auf `AppState`,
/// damit sie testbar sind und nach einem Neustart zu identischen Ergebnissen führen.
public struct LearningCoach: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: - Auswertung

    public func knowledge(state: AppState, now: Date) -> [UUID: ObjectiveKnowledge] {
        let calculator = ProgressCalculator(policy: state.masteryPolicy)
        var result: [UUID: ObjectiveKnowledge] = [:]
        for exam in state.exams {
            result.merge(calculator.knowledgeMap(examID: exam.id, state: state, now: now)) { a, _ in a }
        }
        return result
    }

    public func examSnapshot(_ exam: Exam, state: AppState, knowledge: [UUID: ObjectiveKnowledge], now: Date) -> ExamSnapshot {
        let topics = state.topics(for: exam.id)
        let objectives = state.objectives(for: exam.id)
        let calculator = ProgressCalculator(policy: state.masteryPolicy)
        let progress = calculator.progress(examID: exam.id, topics: topics, objectives: objectives, knowledge: knowledge)
        let forecast = GradePredictor().forecast(exam: exam, topics: topics, objectives: objectives, knowledge: knowledge, simulations: state.simulations, now: now)
        let time = TimeEstimator(policy: state.masteryPolicy).estimate(exam: exam, topics: topics, objectives: objectives, knowledge: knowledge, forecast: forecast,
                                                                       preferences: state.preferences, completedTasks: state.tasks.filter { $0.examID == exam.id }, now: now, calendar: calendar)
        let readiness = ReadinessCalculator.readiness(exam: exam, objectives: objectives, weights: progress.weights, knowledge: knowledge, forecast: forecast, simulations: state.simulations, now: now)
        let weaknesses = WeaknessDetector.detect(attempts: state.attempts.filter { $0.examID == exam.id }, questions: state.questionIndex, objectives: objectives, knowledge: knowledge, now: now)
        return ExamSnapshot(exam: exam, progress: progress, forecast: forecast, time: time, readiness: readiness, weaknesses: weaknesses,
                            phase: RewardPhase.from(forecast: forecast, targetMinFraction: exam.targetBand.minFraction),
                            daysUntilExam: exam.daysUntilExam(from: now, calendar: calendar))
    }

    public func snapshot(state: AppState, now: Date) -> CoachSnapshot {
        let knowledge = knowledge(state: state, now: now)
        let exams = state.activeExams(now: now, calendar: calendar).map { examSnapshot($0, state: state, knowledge: knowledge, now: now) }
        let today = DayKey(now, calendar: calendar)
        let todayTasks = state.tasks.filter { DayKey($0.start, calendar: calendar) == today }.sorted { $0.start < $1.start }
        let next = todayTasks.first { $0.isOpen && $0.end > now } ?? state.tasks.filter { $0.isOpen && $0.start > now }.min { $0.start < $1.start }
        let goal = state.dailyGoal(for: today).map { DailyGoalPlanner.status(record: $0, checks: state.checks, simulations: state.simulations, calendar: calendar) }
        let fullMastery = FullMasteryEvaluator.evaluate(state: state, now: now, calendar: calendar)
        return CoachSnapshot(
            now: now,
            exams: exams,
            knowledge: knowledge,
            todayTasks: todayTasks,
            nextTask: next,
            dailyGoal: goal,
            fullMastery: fullMastery,
            fullDayUnlockEarned: FullMasteryEvaluator.unlockEarnedToday(fullMastery, state: state, now: now, calendar: calendar),
            rewardBalance: state.rewardBalance,
            earnedToday: state.earnedMinutes(on: today, calendar: calendar),
            schedule: scheduleStatus(state: state, now: now),
            recommendation: recommendation(state: state, exams: exams, knowledge: knowledge, next: next, now: now),
            todayPlannedMinutes: todayTasks.filter { $0.status != .skipped }.reduce(0) { $0 + $1.durationMinutes },
            todayCompletedMinutes: Int(todayTasks.filter { $0.status == .completed }.sum { t in t.actualMinutes ?? Double(t.durationMinutes) }.rounded())
        )
    }

    func scheduleStatus(state: AppState, now: Date) -> ScheduleStatus {
        guard !state.tasks.isEmpty else { return .noPlan }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let missed = state.tasks.filter { $0.start >= weekAgo && $0.end <= now && ($0.status == .missed || $0.status == .planned) }
        if missed.isEmpty { return .onTrack }
        return .behind(missedTasks: missed.count, missedMinutes: missed.reduce(0) { $0 + $1.durationMinutes })
    }

    func recommendation(state: AppState, exams: [ExamSnapshot], knowledge: [UUID: ObjectiveKnowledge], next: StudyTask?, now: Date) -> Recommendation? {
        if let next, calendar.isDate(next.start, inSameDayAs: now) {
            return Recommendation(title: next.title, reason: next.reason.isEmpty ? "Laut deinem Lernplan als Nächstes dran." : next.reason,
                                  taskID: next.id, examID: next.examID, objectiveIDs: next.objectiveIDs, kind: next.kind)
        }
        for snapshot in exams.sorted(by: { $0.daysUntilExam < $1.daysUntilExam }) {
            let objectives = state.objectives(for: snapshot.exam.id)
            let due = objectives.filter { knowledge[$0.id]?.isReviewDue(at: now) == true }
            if !due.isEmpty {
                return Recommendation(title: "Wiederholen: " + due.prefix(2).map(\.title).joined(separator: ", "),
                                      reason: "Laut Vergessenskurve ist jetzt eine Wiederholung fällig – so bleibt das Wissen präsent.",
                                      taskID: nil, examID: snapshot.exam.id, objectiveIDs: Array(due.prefix(5).map(\.id)), kind: .review)
            }
            func missingPoints(_ o: LearningObjective) -> Double {
                let weight: Double = snapshot.progress.weights[o.id] ?? 0
                let score: Double = knowledge[o.id]?.score ?? 0
                return weight * (1 - score)
            }
            let open = objectives
                .filter { o in (knowledge[o.id]?.level ?? MasteryLevel.notStarted) < MasteryLevel.provisional }
                .sorted { a, b in missingPoints(a) > missingPoints(b) }
            if let first = open.first {
                let started = (knowledge[first.id]?.level ?? .notStarted) > .notStarted
                return Recommendation(title: (started ? "Üben: " : "Verstehen: ") + first.title,
                                      reason: "Hier gewinnst du für \(snapshot.exam.title) gerade die meisten Punkte.",
                                      taskID: nil, examID: snapshot.exam.id, objectiveIDs: [first.id], kind: started ? .practice : .learn)
            }
            let missingHardOrSpaced = objectives.filter { knowledge[$0.id].map { !$0.isComplete && $0.level >= .provisional } ?? false }
            if let first = missingHardOrSpaced.first, let k = knowledge[first.id] {
                let spacedOK = k.lastReviewAt.map { now.timeIntervalSince($0) >= state.masteryPolicy.spacedGapHours * 3600 } ?? true
                if spacedOK || k.criterion(.hardOrTransfer)?.isMet == false {
                    return Recommendation(title: "Festigen: " + first.title,
                                          reason: "Für „stabil beherrscht“ fehlt noch eine Wiederholung nach zeitlichem Abstand oder eine schwierigere Aufgabe.",
                                          taskID: nil, examID: snapshot.exam.id, objectiveIDs: [first.id], kind: .review)
                }
            }
        }
        return nil
    }

    // MARK: - Planung

    /// Legt das Tagesziel für heute fest (einmal pro Tag, danach unverändert).
    @discardableResult
    public func ensureDailyGoal(_ state: inout AppState, now: Date) -> DailyGoalRecord {
        let today = DayKey(now, calendar: calendar)
        if let existing = state.dailyGoal(for: today) { return existing }
        let knowledge = knowledge(state: state, now: now)
        let exams = state.activeExams(now: now, calendar: calendar).filter { !state.objectives(for: $0.id).isEmpty }
        let tasksToday = state.tasks.filter { DayKey($0.start, calendar: calendar) == today }
        let phase = exams.first.map { examSnapshot($0, state: state, knowledge: knowledge, now: now).phase } ?? .building
        let due = exams.flatMap { state.objectives(for: $0.id) }.filter { knowledge[$0.id]?.isReviewDue(at: now) == true }.count
        let record = DailyGoalPlanner.makeGoal(day: today, tasksToday: tasksToday, isStudyDay: state.preferences.minutes(on: now, calendar: calendar) > 0,
                                               hasActiveExam: !exams.isEmpty, phase: phase, dueReviews: due)
        state.dailyGoals.append(record)
        state.dailyGoals = Array(state.dailyGoals.suffix(60))
        return record
    }

    @discardableResult
    public func replan(_ state: inout AppState, triggers: [ReplanTrigger], now: Date) -> PlanResult {
        let result = StudyPlanner().plan(state: state, knowledge: knowledge(state: state, now: now), triggers: triggers, now: now, calendar: calendar)
        state.tasks = result.tasks
        if !result.change.reasons.isEmpty || result.change.added + result.change.removed + result.change.moved > 0 {
            state.planLog.append(result.change)
            state.planLog = Array(state.planLog.suffix(50))
        }
        return result
    }

    /// Verschiebt eine Einheit manuell; sie wird angeheftet und bei Neuplanung nicht verändert.
    public func moveTask(_ state: inout AppState, taskID: UUID, to start: Date, durationMinutes: Int? = nil) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        state.tasks[index].start = start
        if let d = durationMinutes { state.tasks[index].durationMinutes = max(5, d) }
        state.tasks[index].isPinned = true
        if state.tasks[index].status == .missed { state.tasks[index].status = .planned }
    }

    public func skipTask(_ state: inout AppState, taskID: UUID) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        state.tasks[index].status = .skipped
    }

    // MARK: - Antworten und Überprüfungen

    public func makeAttempt(question: Question, response: AttemptResponse, evaluation: AnswerEvaluation, sessionID: UUID?, durationSeconds: Double,
                            context: AttemptContext, usedHint: Bool, state: AppState, now: Date) -> Attempt {
        Attempt(examID: question.examID, objectiveID: question.objectiveID, questionID: question.id, sessionID: sessionID,
                answeredAt: now, durationSeconds: durationSeconds, response: response, score: evaluation.score,
                grading: evaluation.grading, usedHint: usedHint, context: context,
                wasFirstExposure: !state.attempts.contains { $0.questionID == question.id },
                chosenDistractor: evaluation.chosenDistractor, feedbackTags: evaluation.tags)
    }

    /// Schließt eine Wissensüberprüfung ab: Belohnung, Tagesziel, Einheit erledigt. Idempotent über `checkID`.
    public func completeCheck(_ state: inout AppState, checkID: UUID, examID: UUID, taskID: UUID?, attemptIDs: [UUID], activeMinutes: Double, now: Date) -> (CompletedCheck, RewardGrant) {
        if let existing = state.checks.first(where: { $0.id == checkID }) {
            return (existing, RewardGrant(minutes: existing.rewardMinutes, passed: existing.passed, accuracy: existing.accuracy, eligibleAnswers: existing.attemptIDs.count,
                                          lines: ["Bereits gutgeschrieben."], wasCapped: false))
        }
        let ids = Set(attemptIDs)
        let attempts = state.attempts.filter { ids.contains($0.id) }
        var before = state
        before.attempts.removeAll { ids.contains($0.id) }
        let knowledgeBefore = knowledge(state: before, now: now)
        let knowledgeAfter = knowledge(state: state, now: now)
        let phase: RewardPhase
        if let exam = state.exam(examID) {
            phase = examSnapshot(exam, state: before, knowledge: knowledgeBefore, now: now).phase
        } else {
            phase = .building
        }
        let today = DayKey(now, calendar: calendar)
        let grant = RewardCalculator(policy: state.rewardPolicy).rewardForCheck(CheckRewardInput(
            attempts: attempts, questions: state.questionIndex, earlierAttempts: before.attempts,
            knowledgeBefore: knowledgeBefore, knowledgeAfter: knowledgeAfter, phase: phase,
            earnedToday: state.earnedMinutes(on: today, calendar: calendar), balance: state.rewardBalance))
        let credit = grant.passed ? 1 : (grant.eligibleAnswers >= state.rewardPolicy.minQuestionsPerCheck ? 0.5 : 0)
        let check = CompletedCheck(id: checkID, examID: examID, taskID: taskID, completedAt: now, attemptIDs: attemptIDs,
                                   accuracy: grant.accuracy, passed: grant.passed, rewardMinutes: grant.minutes, dailyGoalCredit: credit)
        state.checks.append(check)
        if grant.minutes > 0 {
            state.rewardLedger.append(RewardLedgerEntry(date: now, minutes: grant.minutes, kind: .earned, sourceID: "check:\(checkID)",
                                                        title: "Wissensüberprüfung", breakdown: grant.lines))
        }
        if let taskID, let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[index].status = .completed
            state.tasks[index].completedAt = now
            state.tasks[index].actualMinutes = activeMinutes
            state.tasks[index].checkPassed = grant.passed
        }
        markDailyGoalIfReached(&state, now: now)
        return (check, grant)
    }

    /// Wertet eine Prüfungssimulation aus.
    public func completeSimulation(_ state: inout AppState, session: StudySessionState, now: Date) -> (ExamSimulationResult, RewardGrant)? {
        guard let exam = state.exam(session.examID) else { return nil }
        if let existing = state.simulations.first(where: { $0.id == session.id }) {
            let minutes = state.rewardLedger.first { $0.sourceID == "sim:\(session.id)" }?.minutes ?? 0
            return (existing, RewardGrant(minutes: minutes, passed: true, accuracy: existing.scoreFraction, eligibleAnswers: existing.attemptIDs.count, lines: ["Bereits ausgewertet."], wasCapped: false))
        }
        let questions = state.questionIndex
        let attemptIDs = Set(session.attemptIDs)
        let attempts = state.attempts.filter { attemptIDs.contains($0.id) }
        let attemptByQuestion = Dictionary(attempts.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
        let objectiveTopic = Dictionary(uniqueKeysWithValues: state.objectives.map { ($0.id, $0.topicID) })
        var possible = 0.0
        var achieved = 0.0
        var perTopic: [UUID: (Double, Double)] = [:]
        for qid in session.questionIDs {
            guard let q = questions[qid] else { continue }
            let points = q.points
            let score = attemptByQuestion[qid]?.score ?? 0
            possible += points
            achieved += points * score
            if let topic = objectiveTopic[q.objectiveID] {
                var entry = perTopic[topic] ?? (0, 0)
                entry.0 += points * score
                entry.1 += points
                perTopic[topic] = entry
            }
        }
        let fraction = possible > 0 ? achieved / possible : 0
        let result = ExamSimulationResult(id: session.id, examID: exam.id, startedAt: session.startedAt, finishedAt: now,
                                          timeLimitMinutes: session.timeLimitMinutes ?? 0, questionIDs: session.questionIDs, attemptIDs: session.attemptIDs,
                                          pointsAchieved: achieved, pointsPossible: possible,
                                          topicScores: perTopic.map { TopicScore(topicID: $0.key, achieved: $0.value.0, possible: $0.value.1) }.sorted { $0.fraction < $1.fraction },
                                          gradeBandID: exam.gradeScale.band(for: fraction).id)
        let today = DayKey(now, calendar: calendar)
        let grant = RewardCalculator(policy: state.rewardPolicy).rewardForSimulation(result, attempts: attempts, targetMinFraction: exam.targetBand.minFraction,
                                                                                     earnedToday: state.earnedMinutes(on: today, calendar: calendar), balance: state.rewardBalance)
        state.simulations.append(result)
        if grant.minutes > 0 {
            state.rewardLedger.append(RewardLedgerEntry(date: now, minutes: grant.minutes, kind: .earned, sourceID: "sim:\(session.id)", title: "Prüfungssimulation", breakdown: grant.lines))
        }
        if let taskID = session.taskID, let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[index].status = .completed
            state.tasks[index].completedAt = now
            state.tasks[index].actualMinutes = now.timeIntervalSince(session.startedAt) / 60
            state.tasks[index].checkPassed = grant.passed
        }
        markDailyGoalIfReached(&state, now: now)
        return (result, grant)
    }

    func markDailyGoalIfReached(_ state: inout AppState, now: Date) {
        let today = DayKey(now, calendar: calendar)
        guard let index = state.dailyGoals.firstIndex(where: { $0.day == today }), state.dailyGoals[index].reachedAt == nil else { return }
        let status = DailyGoalPlanner.status(record: state.dailyGoals[index], checks: state.checks, simulations: state.simulations, calendar: calendar)
        if status.isReached { state.dailyGoals[index].reachedAt = now }
    }

    // MARK: - Bildschirmzeit-Konto

    /// Bucht Minuten vom Konto ab (das Freischalten selbst übernimmt die Sperrsteuerung).
    @discardableResult
    public func redeem(_ state: inout AppState, minutes: Int, now: Date) throws -> RewardLedgerEntry {
        guard minutes > 0 else { throw CoachError.invalidMinutes }
        let balance = state.rewardBalance
        guard minutes <= balance else { throw CoachError.insufficientBalance(available: balance) }
        let entry = RewardLedgerEntry(date: now, minutes: -minutes, kind: .redeemed, sourceID: "redeem:\(UUID().uuidString)", title: "Bildschirmzeit eingelöst")
        state.rewardLedger.append(entry)
        return entry
    }

    /// Nicht genutzte Minuten nach vorzeitigem Beenden zurückbuchen.
    public func returnUnused(_ state: inout AppState, minutes: Int, now: Date) {
        guard minutes > 0 else { return }
        state.rewardLedger.append(RewardLedgerEntry(date: now, minutes: minutes, kind: .returned, title: "Nicht genutzte Minuten zurückgebucht"))
    }

    // MARK: - Fragen

    /// Erzeugt lokale Fragen für Lernziele mit zu wenig Fragen. Gibt die Anzahl neuer Fragen zurück.
    @discardableResult
    public func ensureLocalQuestions(_ state: inout AppState, objectiveIDs: [UUID], chunks: [SourceChunk], minimum: Int = 4) -> Int {
        var added = 0
        for id in objectiveIDs {
            guard let objective = state.objectives.first(where: { $0.id == id }) else { continue }
            let existing = state.questions.filter { $0.objectiveID == id }
            guard existing.filter({ $0.status == .active }).count < minimum else { continue }
            let examTerms = state.terms.filter { $0.examID == objective.examID }
            let new = LocalQuestionGenerator.questions(for: objective, terms: examTerms, allTerms: examTerms, chunks: chunks, existing: existing)
            state.questions.append(contentsOf: new)
            added += new.count
        }
        return added
    }

    /// Meldet eine fehlerhafte Frage: Sie wird nicht mehr gestellt, bisherige Antworten zählen nicht.
    public func reportQuestion(_ state: inout AppState, questionID: UUID) {
        guard let index = state.questions.firstIndex(where: { $0.id == questionID }) else { return }
        state.questions[index].status = .reported
        for i in state.attempts.indices where state.attempts[i].questionID == questionID {
            state.attempts[i].isVoided = true
        }
    }

    /// Vergleichsübung für eine erkannte Verwechslung erzeugen (falls beide Begriffe im Material definiert sind).
    public func comparisonQuestion(_ state: inout AppState, insight: WeaknessInsight) -> Question? {
        guard case .confusion(let a, let b) = insight.kind else { return nil }
        let terms = state.terms
        guard let ta = terms.first(where: { TextNormalizer.normalize($0.term) == TextNormalizer.normalize(a) }),
              let tb = terms.first(where: { TextNormalizer.normalize($0.term) == TextNormalizer.normalize(b) }),
              let objectiveID = insight.objectiveIDs.first else { return nil }
        let q = LocalQuestionGenerator.comparison(between: ta, and: tb, objectiveID: objectiveID)
        if let existing = state.questions.first(where: { $0.variantGroup == q.variantGroup && $0.status == .active }) { return existing }
        state.questions.append(q)
        return q
    }
}
