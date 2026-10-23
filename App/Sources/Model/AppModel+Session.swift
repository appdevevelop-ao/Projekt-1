import Foundation
import LernKern

struct LevelChange: Identifiable {
    var id: String { title }
    var title: String
    var from: MasteryLevel
    var to: MasteryLevel
}

struct SessionSummary {
    var correct: Int
    var total: Int
    var grant: RewardGrant?
    var check: CompletedCheck?
    var simulation: ExamSimulationResult?
    var levelChanges: [LevelChange]
    var dailyGoal: DailyGoalStatus?
    var unlockedForDay: Bool
}

extension AppModel {
    // MARK: - Starten

    func startSession(for task: StudyTask) async {
        switch task.kind {
        case .simulation:
            await startSimulation(examID: task.examID, taskID: task.id)
        case .errorAnalysis:
            let wrong = lastSimulationMistakes(examID: task.examID)
            if wrong.isEmpty {
                await startPractice(examID: task.examID, objectiveIDs: [], kind: .mixedPractice, taskID: task.id)
            } else {
                begin(examID: task.examID, taskID: task.id, kind: .errorAnalysis, objectiveIDs: Array(Set(wrong.map(\.objectiveID))), questionIDs: wrong.prefix(8).map(\.id), phase: .questions)
            }
        default:
            await startPractice(examID: task.examID, objectiveIDs: task.objectiveIDs, kind: task.kind, taskID: task.id, durationMinutes: task.durationMinutes)
        }
    }

    func startPractice(examID: UUID, objectiveIDs: [UUID], kind: StudyTaskKind, taskID: UUID? = nil, durationMinutes: Int = 20, extraQuestions: [Question] = []) async {
        var ids = objectiveIDs
        if ids.isEmpty {
            ids = QuestionSelector.mixedObjectives(examID: examID, state: state, knowledge: snapshot.knowledge, limit: 6)
        }
        if ids.isEmpty {
            ids = Array(state.objectives(for: examID).prefix(3).map(\.id))
        }
        await ensureQuestions(objectiveIDs: ids, examID: examID)
        let count: Int
        switch kind {
        case .learn: count = 4
        case .review: count = min(8, max(3, ids.count * 2))
        case .mixedPractice: count = 6
        default: count = min(8, max(4, durationMinutes / 3))
        }
        let selected = QuestionSelector.select(objectiveIDs: ids, count: count, state: state, knowledge: snapshot.knowledge, now: Date(),
                                               allowFreeText: true, seed: UUID().uuidString)
        let questionIDs = extraQuestions.map(\.id) + selected.map(\.id).filter { id in !extraQuestions.contains { $0.id == id } }
        begin(examID: examID, taskID: taskID, kind: kind, objectiveIDs: ids, questionIDs: questionIDs, phase: kind == .learn ? .learning : .questions)
    }

    func startSimulation(examID: UUID, taskID: UUID? = nil) async {
        guard let exam = state.exam(examID) else { return }
        await ensureQuestions(objectiveIDs: state.objectives(for: examID).map(\.id), examID: examID, maxAIObjectives: 4)
        let limit = taskID.flatMap { id in state.tasks.first { $0.id == id }?.durationMinutes } ?? min(max(exam.durationMinutes ?? 45, 10), 180)
        let blueprint = SimulationBuilder.build(exam: exam, state: state, timeLimitMinutes: limit, seed: UUID().uuidString)
        guard !blueprint.questionIDs.isEmpty else {
            banner = Banner(kind: .warning, title: "Simulation nicht möglich", message: blueprint.limitation ?? "Es gibt noch keine Fragen.")
            return
        }
        if let limitation = blueprint.limitation { banner = Banner(kind: .info, title: "Hinweis zur Simulation", message: limitation) }
        var s = StudySessionState(examID: examID, taskID: taskID, kind: .simulation, mode: .simulation, objectiveIDs: [], phase: .questions,
                                  questionIDs: blueprint.questionIDs, startedAt: Date(), timeLimitMinutes: limit)
        s.resume(at: Date())
        session = s
        levelsAtStart = snapshot.knowledge.mapValues(\.level)
        markTaskInProgress(taskID)
        persistSession()
    }

    func startComparison(for insight: WeaknessInsight, examID: UUID) async {
        var comparison: Question?
        mutate { state in comparison = coach.comparisonQuestion(&state, insight: insight) }
        await startPractice(examID: examID, objectiveIDs: insight.objectiveIDs, kind: .practice, extraQuestions: comparison.map { [$0] } ?? [])
    }

    private func begin(examID: UUID, taskID: UUID?, kind: StudyTaskKind, objectiveIDs: [UUID], questionIDs: [UUID], phase: StudySessionState.Phase) {
        var s = StudySessionState(examID: examID, taskID: taskID, kind: kind, mode: .practice, objectiveIDs: objectiveIDs, phase: phase, questionIDs: questionIDs, startedAt: Date())
        s.resume(at: Date())
        session = s
        levelsAtStart = snapshot.knowledge.mapValues(\.level)
        markTaskInProgress(taskID)
        persistSession()
    }

    private func markTaskInProgress(_ taskID: UUID?) {
        guard let taskID else { return }
        mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == taskID }), state.tasks[i].status != .completed { state.tasks[i].status = .inProgress }
        }
    }

    func lastSimulationMistakes(examID: UUID) -> [Question] {
        guard let sim = state.simulations.filter({ $0.examID == examID }).max(by: { $0.finishedAt < $1.finishedAt }) else { return [] }
        let ids = Set(sim.attemptIDs)
        let wrong = state.attempts.filter { ids.contains($0.id) && !$0.isCorrect }.map(\.questionID)
        let answered = Set(state.attempts.filter { ids.contains($0.id) }.map(\.questionID))
        let unanswered = sim.questionIDs.filter { !answered.contains($0) }
        let index = state.questionIndex
        return (wrong + unanswered).compactMap { index[$0] }.filter { $0.status == .active }
    }

    // MARK: - Fragen bereitstellen

    /// Lokale Fragen sicherstellen und – falls eingerichtet – mit KI ergänzen (adaptive Schwierigkeit).
    func ensureQuestions(objectiveIDs: [UUID], examID: UUID, maxAIObjectives: Int = 3) async {
        let examChunks = chunks(forExam: examID)
        mutate { state in coach.ensureLocalQuestions(&state, objectiveIDs: objectiveIDs, chunks: examChunks) }
        guard state.settings.isAIUsable, let exam = state.exam(examID) else { return }
        let needing = objectiveIDs.filter { id in
            let active = state.activeQuestions(for: id)
            let level = snapshot.knowledge[id]?.level ?? .notStarted
            let lacksHard = level >= .provisional && !active.contains { $0.difficulty == .hard || $0.isTransfer }
            return active.count < 6 || lacksHard
        }.prefix(maxAIObjectives)
        guard !needing.isEmpty else { return }
        isGeneratingQuestions = true
        defer { isGeneratingQuestions = false }
        for id in needing {
            guard let objective = state.objectives.first(where: { $0.id == id }) else { continue }
            let sources = examChunks.filter { objective.sourceChunkIDs.contains($0.id) && $0.duplicateOf == nil }.prefix(5)
            guard !sources.isEmpty else { continue }
            let level = snapshot.knowledge[id]?.level ?? .notStarted
            let mix: AIContracts.DifficultyMix
            switch level {
            case .notStarted: mix = .init(easy: 2, medium: 3, hard: 1)
            case .learned: mix = .init(easy: 1, medium: 3, hard: 2)
            case .provisional, .stable: mix = .init(easy: 0, medium: 2, hard: 3)
            }
            let request = AIContracts.QuestionsRequest(
                exam: .init(exam: exam), objective: .init(objective: objective), language: "de",
                chunks: sources.map { AIContracts.ChunkPayload(chunk: $0) }, difficulties: mix, kinds: Self.questionKinds(for: exam.format),
                avoidPrompts: state.questions.filter { $0.objectiveID == id }.suffix(25).map(\.prompt))
            do {
                let response = try await ai.questions(request, settings: state.settings)
                let result = AIResponseValidator.questions(response, objective: objective, chunks: Array(sources), existing: state.questions.filter { $0.objectiveID == id })
                if !result.questions.isEmpty { mutate { $0.questions.append(contentsOf: result.questions) } }
            } catch {
                banner = Banner(kind: .info, title: "KI-Fragen gerade nicht verfügbar", message: ((error as? LocalizedError)?.errorDescription ?? "") + " Du übst mit den Fragen aus deinen Unterlagen.")
                break
            }
        }
    }

    static func questionKinds(for format: ExamFormat) -> [String] {
        switch format {
        case .multipleChoice: return ["multipleChoice", "trueFalse", "matching", "cloze"]
        case .oral: return ["freeText", "shortAnswer", "multipleChoice", "cloze"]
        case .practical: return ["numeric", "shortAnswer", "multipleChoice", "freeText", "cloze"]
        case .written, .mixed, .unknown: return QuestionKind.allCases.map(\.rawValue)
        }
    }

    // MARK: - Antworten

    func question(_ id: UUID?) -> Question? {
        guard let id else { return nil }
        return state.questions.first { $0.id == id }
    }

    var currentQuestion: Question? { question(session?.currentQuestionID) }

    func beginQuestions() {
        guard var s = session else { return }
        s.phase = .questions
        session = s
        persistSession()
    }

    /// Bewertet eine Antwort. Offene Antworten: KI-Bewertung (falls eingerichtet), sonst Selbsteinschätzung.
    func evaluate(_ question: Question, response: AttemptResponse) async -> AnswerEvaluation {
        if question.kind == .freeText, response.selfRating == nil, state.settings.isAIUsable, let text = response.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let excerpt = question.source.flatMap { chunk(for: $0) }?.text ?? question.source?.quote ?? ""
            let request = AIContracts.GradeRequest(language: "de", prompt: question.prompt, referenceAnswer: question.referenceAnswer ?? "",
                                                   rubric: question.rubric, sourceExcerpt: String(excerpt.prefix(5_000)), answer: text)
            if let response = try? await ai.grade(request, settings: state.settings), var evaluation = AIResponseValidator.grade(response) {
                evaluation.correctAnswer = question.referenceAnswer ?? ""
                return evaluation
            }
        }
        return AnswerEvaluator.evaluate(question, response: response)
    }

    /// Speichert die bewertete Antwort sofort (kein Datenverlust bei Abbruch).
    func record(_ question: Question, response: AttemptResponse, evaluation: AnswerEvaluation, usedHint: Bool, seconds: Double, advance: Bool) {
        guard var s = session, s.currentAnswered != true else { return }
        let context: AttemptContext = s.mode == .simulation ? .simulation : (s.kind == .review ? .review : .check)
        let attempt = coach.makeAttempt(question: question, response: response, evaluation: evaluation, sessionID: s.id, durationSeconds: seconds,
                                        context: context, usedHint: usedHint, state: state, now: Date())
        s.recordAnswer(attemptID: attempt.id, advance: advance)
        session = s
        persistSession()
        mutate { $0.attempts.append(attempt) }
    }

    /// Zur nächsten Frage (nach der Rückmeldung).
    func advanceQuestion() {
        guard var s = session else { return }
        s.advance()
        session = s
        persistSession()
    }

    func reportCurrentQuestion(_ questionID: UUID) {
        mutate { coach.reportQuestion(&$0, questionID: questionID) }
        if var s = session, s.currentQuestionID == questionID {
            s.advance()
            session = s
            persistSession()
        }
        banner = Banner(kind: .info, title: "Danke für den Hinweis", message: "Die Frage wird nicht mehr gestellt und zählt nicht für deinen Fortschritt.")
    }

    // MARK: - Abschließen

    func finishSession() -> SessionSummary? {
        guard var s = session else { return nil }
        let now = Date()
        s.pause(at: now)
        var summary = SessionSummary(correct: 0, total: s.questionIDs.count, grant: nil, check: nil, simulation: nil, levelChanges: [], dailyGoal: nil, unlockedForDay: false)
        let ids = Set(s.attemptIDs)
        summary.correct = state.attempts.filter { ids.contains($0.id) && $0.isCorrect }.count

        if s.mode == .simulation {
            var outcome: (ExamSimulationResult, RewardGrant)?
            mutate { state in outcome = coach.completeSimulation(&state, session: s, now: now) }
            summary.simulation = outcome?.0
            summary.grant = outcome?.1
        } else if !s.attemptIDs.isEmpty {
            var outcome: (CompletedCheck, RewardGrant)?
            mutate { state in
                outcome = coach.completeCheck(&state, checkID: s.id, examID: s.examID, taskID: s.taskID, attemptIDs: s.attemptIDs,
                                              activeMinutes: s.activeSeconds(at: now) / 60, now: now)
            }
            summary.check = outcome?.0
            summary.grant = outcome?.1
        }
        let titles = Dictionary(uniqueKeysWithValues: state.objectives.map { ($0.id, $0.title) })
        let touched = Set(state.attempts.filter { ids.contains($0.id) }.map(\.objectiveID))
        for id in touched {
            let before = levelsAtStart[id] ?? .notStarted
            let after = snapshot.knowledge[id]?.level ?? .notStarted
            if before != after, let title = titles[id] { summary.levelChanges.append(LevelChange(title: title, from: before, to: after)) }
        }
        summary.dailyGoal = snapshot.dailyGoal
        summary.unlockedForDay = snapshot.fullMastery.isComplete
        s.phase = .summary
        s.completedCheckID = s.id
        session = s
        persistSession()
        if s.taskID != nil { autoSyncCalendar() }
        return summary
    }

    func closeSession() {
        session = nil
        levelsAtStart = [:]
        persistSession()
        refresh()
    }

    /// Sitzung abbrechen: Bisherige Antworten bleiben gespeichert, eine Belohnung gibt es nur für abgeschlossene Überprüfungen.
    func abandonSession() {
        if let taskID = session?.taskID {
            mutate { state in
                if let i = state.tasks.firstIndex(where: { $0.id == taskID }), state.tasks[i].status == .inProgress { state.tasks[i].status = .planned }
            }
        }
        closeSession()
    }

    func startBreak(minutes: Int) {
        guard var s = session else { return }
        s.breakUntil = Date().addingTimeInterval(Double(minutes * 60))
        session = s
        persistSession()
    }

    // MARK: - Erklärungen

    func explanation(for question: Question, mode: String, userAnswer: String?) async -> (text: String, fromAI: Bool)? {
        if mode == "simpler", let simple = question.simplerExplanation, !simple.isEmpty { return (simple, false) }
        guard state.settings.isAIUsable, let objective = state.objectives.first(where: { $0.id == question.objectiveID }) else { return nil }
        var sources: [SourceChunk] = []
        if let ref = question.source, let c = chunk(for: ref) { sources.append(c) }
        sources += chunks(ids: objective.sourceChunkIDs, examID: objective.examID).filter { c in !sources.contains { $0.id == c.id } }.prefix(3)
        guard !sources.isEmpty else { return nil }
        let request = AIContracts.ExplainRequest(language: "de", mode: mode, objective: .init(objective: objective), chunks: Array(sources.prefix(4)).map { AIContracts.ChunkPayload(chunk: $0) },
                                                 questionPrompt: question.prompt, correctAnswer: question.referenceAnswer ?? question.acceptedAnswers.first, userAnswer: userAnswer)
        guard let response = try? await ai.explain(request, settings: state.settings) else { return nil }
        var text = response.explanation
        if response.outsideMaterial { text += "\n\nHinweis: Ein Teil davon steht nicht in deinen Unterlagen." }
        return (text, true)
    }
}
