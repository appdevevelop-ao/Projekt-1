import XCTest
@testable import LernKern

/// Ende-zu-Ende-Abläufe der Kernlogik (entsprechen den Abnahmeszenarien, soweit ohne iOS prüfbar).
final class CoachTests: XCTestCase {
    func importSample(into state: inout AppState, exam: Exam) throws -> (SourceDocument, DocumentAnalysis) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample.docx", withExtension: nil, subdirectory: "Resources"))
        var document = SourceDocument(examID: exam.id, fileName: "Skript.docx", kind: .docx)
        let extracted = try DocumentPipeline.extract(data: try Data(contentsOf: url), kind: .docx)
        let analysis = try DocumentPipeline.analyze(extracted, documentID: document.id, kind: .docx, existingChunks: [])
        document.pageCount = analysis.pageCount
        document.state = ProcessingState(stage: .completed)
        state.documents.append(document)
        _ = MaterialIntegrator.integrate(&state, document: document, analysis: analysis, aiResult: nil)
        return (document, analysis)
    }

    /// Szenario 1 + 2 + 5: Prüfung anlegen, Unterlagen verarbeiten, Plan erstellen, lernen, belohnt werden.
    func testCreateExamPlanLearnAndEarn() throws {
        let cal = TestCalendar.make()
        let coach = LearningCoach(calendar: cal)
        var now = cal.at(2026, 10, 23, 15)
        let exam = Exam(title: "Biologie", examDate: cal.at(2026, 11, 6, 9), format: .written, durationMinutes: 45)
        var state = AppState(exams: [exam])
        _ = try importSample(into: &state, exam: exam)
        XCTAssertFalse(state.objectives(for: exam.id).isEmpty)
        XCTAssertFalse(state.questions.isEmpty)

        let plan = coach.replan(&state, triggers: [.initial], now: now)
        XCTAssertFalse(plan.tasks.isEmpty)
        XCTAssertEqual(state.planLog.count, 1)
        coach.ensureDailyGoal(&state, now: now)
        let goal = try XCTUnwrap(state.dailyGoal(for: DayKey(now, calendar: cal)))
        XCTAssertGreaterThanOrEqual(goal.requiredChecks, 1)

        // Erste Einheit des Tages bearbeiten
        let snapshot = coach.snapshot(state: state, now: now)
        let task = try XCTUnwrap(snapshot.nextTask)
        let knowledge = coach.knowledge(state: state, now: now)
        let questions = QuestionSelector.select(objectiveIDs: task.objectiveIDs, count: 6, state: state, knowledge: knowledge, now: now, allowFreeText: false, seed: "t")
        XCTAssertGreaterThanOrEqual(questions.count, 3)
        var attemptIDs: [UUID] = []
        for q in questions {
            now = now.addingTimeInterval(45)
            let response = correctResponse(for: q)
            let evaluation = AnswerEvaluator.evaluate(q, response: response)
            XCTAssertEqual(evaluation.score, 1, "Musterantwort muss als richtig erkannt werden: \(q.prompt)")
            let attempt = coach.makeAttempt(question: q, response: response, evaluation: evaluation, sessionID: nil, durationSeconds: 40, context: .check, usedHint: false, state: state, now: now)
            state.attempts.append(attempt)
            attemptIDs.append(attempt.id)
        }
        let checkID = UUID()
        let (check, grant) = coach.completeCheck(&state, checkID: checkID, examID: exam.id, taskID: task.id, attemptIDs: attemptIDs, activeMinutes: 12, now: now)
        XCTAssertTrue(check.passed)
        XCTAssertGreaterThanOrEqual(grant.minutes, 5)
        XCTAssertEqual(state.rewardBalance, grant.minutes)
        XCTAssertEqual(state.tasks.first { $0.id == task.id }?.status, .completed)

        // Idempotent: erneuter Abschluss (z. B. nach Neustart) bucht nicht doppelt
        _ = coach.completeCheck(&state, checkID: checkID, examID: exam.id, taskID: task.id, attemptIDs: attemptIDs, activeMinutes: 12, now: now)
        XCTAssertEqual(state.rewardBalance, grant.minutes)
        XCTAssertEqual(state.rewardLedger.filter { $0.kind == .earned }.count, 1)

        // Einlösen
        try coach.redeem(&state, minutes: 5, now: now)
        XCTAssertEqual(state.rewardBalance, grant.minutes - 5)
        XCTAssertThrowsError(try coach.redeem(&state, minutes: 999, now: now))
        coach.returnUnused(&state, minutes: 2, now: now)
        XCTAssertEqual(state.rewardBalance, grant.minutes - 3)

        let after = coach.snapshot(state: state, now: now)
        XCTAssertGreaterThan(after.exams.first!.progress.fraction, 0)
        XCTAssertGreaterThan(after.dailyGoal!.credits, 0)
    }

    /// Szenario 3: Einheit verpasst / Thema scheitert → realistischer neuer Plan.
    func testMissedDayLeadsToRealisticReplan() throws {
        let cal = TestCalendar.make()
        let coach = LearningCoach(calendar: cal)
        let start = cal.at(2026, 10, 23, 9)
        let exam = Exam(title: "Biologie", examDate: cal.at(2026, 11, 6, 9))
        var state = AppState(exams: [exam])
        _ = try importSample(into: &state, exam: exam)
        coach.replan(&state, triggers: [.initial], now: start)
        let later = cal.at(2026, 10, 25, 8)
        let result = coach.replan(&state, triggers: [.routine], now: later)
        XCTAssertTrue(result.change.reasons.contains { $0.contains("verpasste") })
        XCTAssertTrue(result.tasks.filter { $0.start >= later }.contains { $0.kind == .learn })
        if case .behind(let n, _) = coach.snapshot(state: state, now: later).schedule { XCTAssertGreaterThan(n, 0) } else { XCTFail("Rückstand erwartet") }
    }

    /// Szenario 2: Prüfungssimulation aktualisiert Prognose und Schwächen.
    func testSimulationFlow() throws {
        let cal = TestCalendar.make()
        let coach = LearningCoach(calendar: cal)
        var now = cal.at(2026, 10, 23, 15)
        let exam = Exam(title: "Biologie", examDate: cal.at(2026, 11, 6, 9), durationMinutes: 30)
        var state = AppState(exams: [exam])
        _ = try importSample(into: &state, exam: exam)
        let blueprint = SimulationBuilder.build(exam: exam, state: state, timeLimitMinutes: 30, seed: "sim")
        XCTAssertGreaterThanOrEqual(blueprint.questionIDs.count, 5)
        XCTAssertNil(blueprint.limitation.flatMap { $0.contains("zu wenige") ? $0 : nil })
        var session = StudySessionState(examID: exam.id, taskID: nil, kind: .simulation, mode: .simulation, objectiveIDs: [], phase: .questions,
                                        questionIDs: blueprint.questionIDs, startedAt: now, timeLimitMinutes: 30)
        let questions = state.questionIndex
        for (i, id) in blueprint.questionIDs.enumerated() {
            let q = questions[id]!
            now = now.addingTimeInterval(60)
            let response = i % 2 == 0 ? correctResponse(for: q) : AttemptResponse(selectedIndices: [99], text: "falsch", matching: [])
            let evaluation = q.kind == .freeText ? AnswerEvaluator.evaluate(q, response: AttemptResponse(text: "x", selfRating: 0.5)) : AnswerEvaluator.evaluate(q, response: response)
            let attempt = coach.makeAttempt(question: q, response: response, evaluation: evaluation, sessionID: session.id, durationSeconds: 50, context: .simulation, usedHint: false, state: state, now: now)
            state.attempts.append(attempt)
            session.recordAnswer(attemptID: attempt.id)
        }
        let (result, grant) = try XCTUnwrap(coach.completeSimulation(&state, session: session, now: now))
        XCTAssertGreaterThan(result.pointsPossible, 0)
        XCTAssertGreaterThan(result.scoreFraction, 0.2)
        XCTAssertLessThan(result.scoreFraction, 0.9)
        XCTAssertGreaterThanOrEqual(grant.minutes, 10)
        XCTAssertEqual(state.simulations.count, 1)
        // Zweiter Abschluss bucht nicht doppelt
        _ = coach.completeSimulation(&state, session: session, now: now)
        XCTAssertEqual(state.simulations.count, 1)
        let snap = coach.snapshot(state: state, now: now)
        XCTAssertEqual(snap.exams.first?.forecast.recentSimulationCount, 1)
    }

    /// Szenario 6: 100 % wird erkannt (Grundlage für die Tagesfreigabe).
    func testFullMasteryDetection() {
        var f = Fixture()
        for o in f.objectives { f.master(o, startingAt: f.now) }
        let coach = LearningCoach(calendar: f.calendar)
        let check = f.now.addingTimeInterval(27 * 3600)
        let snapshot = coach.snapshot(state: f.state, now: check)
        XCTAssertTrue(snapshot.fullMastery.isComplete)
        XCTAssertEqual(snapshot.exams.first?.progress.percent, 100)
        // Freigabe-Logik: 100 % → bis Mitternacht frei
        let ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: check, calendar: f.calendar)
        let decision = ShieldDecisionEngine.decide(policy: ShieldPolicy(isEnabled: true, mode: .dailyGoal), ledger: ledger,
                                                   environment: .init(isAuthorized: true, hasSelection: true), now: check, calendar: f.calendar)
        XCTAssertEqual(decision.status, .fullDayUnlock(DayKey(check, calendar: f.calendar)))
    }

    /// Szenario 7 + 9: neuer Tag / Neustart – Daten bleiben erhalten, neues Tagesziel.
    func testPersistenceRoundTripAndNewDay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lernkern-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        XCTAssertNil(try store.loadState())
        var f = Fixture()
        f.answer(f.objectives[0], difficulty: .medium, correct: true)
        let coach = LearningCoach(calendar: f.calendar)
        coach.ensureDailyGoal(&f.state, now: f.now)
        f.state.rewardLedger.append(RewardLedgerEntry(date: f.now, minutes: 7, kind: .earned, sourceID: "check:x", title: "x"))
        try store.saveState(f.state)
        let session = StudySessionState(examID: f.exam.id, taskID: nil, kind: .practice, mode: .practice, objectiveIDs: [], phase: .questions, questionIDs: [UUID()], startedAt: f.now)
        try store.saveSession(session)

        var loaded = try XCTUnwrap(store.loadState())
        XCTAssertEqual(loaded.attempts.count, 1)
        XCTAssertEqual(loaded.rewardBalance, 7)
        XCTAssertEqual(store.loadSession()?.id, session.id)
        let nextDay = f.now.addingTimeInterval(86_400)
        coach.ensureDailyGoal(&loaded, now: nextDay)
        XCTAssertEqual(loaded.dailyGoals.count, 2, "Neuer Tag → neues Tagesziel, altes bleibt erhalten")
        XCTAssertEqual(loaded.rewardBalance, 7, "Verdiente Minuten bleiben über den Tageswechsel erhalten")

        // Beschädigte Datei → Rückfall auf Sicherung
        try store.saveState(loaded)
        try Data("kaputt".utf8).write(to: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.loadState()?.attempts.count, 1)

        try store.deleteEverything()
        XCTAssertNil(try store.loadState())
    }

    func testDailyGoalIsFrozenForTheDay() {
        var f = Fixture()
        let coach = LearningCoach(calendar: f.calendar)
        coach.replan(&f.state, triggers: [.initial], now: f.now)
        let first = coach.ensureDailyGoal(&f.state, now: f.now)
        f.state.tasks.removeAll()
        let second = coach.ensureDailyGoal(&f.state, now: f.now.addingTimeInterval(3600))
        XCTAssertEqual(first, second)
    }

    func testReportingQuestionVoidsItsAttempts() {
        var f = Fixture()
        let a = f.answer(f.objectives[0], difficulty: .medium, correct: false)
        LearningCoach(calendar: f.calendar).reportQuestion(&f.state, questionID: a.questionID)
        XCTAssertTrue(f.state.attempts.first!.isVoided)
        XCTAssertEqual(f.state.questions.first { $0.id == a.questionID }?.status, .reported)
    }

    func testDocumentRemovalKeepsPracticedObjectives() throws {
        let cal = TestCalendar.make()
        let exam = Exam(title: "Bio", examDate: cal.at(2026, 11, 20))
        var state = AppState(exams: [exam])
        let (document, analysis) = try importSample(into: &state, exam: exam)
        let practiced = state.objectives[0]
        let q = state.questions.first { $0.objectiveID == practiced.id }!
        state.attempts.append(Attempt(examID: exam.id, objectiveID: practiced.id, questionID: q.id, answeredAt: cal.at(2026, 10, 23), durationSeconds: 20, score: 1))
        MaterialIntegrator.removeDocument(&state, documentID: document.id, chunkIDs: Set(analysis.chunks.map(\.id)))
        XCTAssertEqual(state.objectives.map(\.id), [practiced.id])
        XCTAssertTrue(state.terms.isEmpty)
        XCTAssertTrue(state.questions.allSatisfy { $0.status == .retired })
    }

    func testSyllabusAddsMissingTopicsAndWeights() throws {
        let cal = TestCalendar.make()
        let exam = Exam(title: "Bio", examDate: cal.at(2026, 11, 20))
        var state = AppState(exams: [exam])
        _ = try importSample(into: &state, exam: exam)
        let entries = SyllabusParser.entries(from: ExtractedDocument.fromPages(["- Genetik (40 %)\n- Ökologie (20 %)"]))
        let summary = MaterialIntegrator.integrateSyllabus(&state, examID: exam.id, entries: entries)
        XCTAssertEqual(summary.newTopics, 1)
        XCTAssertEqual(state.topics.first { $0.title == "Genetik" }?.examWeight, 0.4)
        let ecology = try XCTUnwrap(state.topics.first { $0.title == "Ökologie" })
        XCTAssertFalse(ecology.hasMaterial)
        let progress = ProgressCalculator().progress(examID: exam.id, state: state, now: cal.at(2026, 10, 23))
        XCTAssertTrue(progress.missing.contains { $0.objectiveIDs.contains { id in state.objectives.first { $0.id == id }?.topicID == ecology.id } },
                      "Lehrplan-Themen ohne Material zählen zur Stoffabdeckung")
    }

    func testQuestionSelectorAdaptsDifficulty() {
        var f = Fixture()
        let o = f.objectives[0]
        for i in 0..<5 { f.answer(o, difficulty: .medium, index: i, correct: false, at: f.now.addingTimeInterval(Double(i) * 60)) }
        let k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(600))
        XCTAssertEqual(QuestionSelector.desiredDifficulty(k[o.id], alreadyPicked: []), .easy)
        var g = Fixture()
        for (i, d) in [Difficulty.medium, .medium, .medium, .medium, .medium].enumerated() { g.answer(g.objectives[0], difficulty: d, index: i, correct: true, at: g.now.addingTimeInterval(Double(i) * 60)) }
        let k2 = ProgressCalculator().knowledgeMap(examID: g.exam.id, state: g.state, now: g.now.addingTimeInterval(600))
        XCTAssertEqual(QuestionSelector.desiredDifficulty(k2[g.objectives[0].id], alreadyPicked: []), .hard, "Fehlende schwere Aufgabe wird gezielt gestellt")
    }

    func testSessionTracksOnlyActiveTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var s = StudySessionState(examID: UUID(), taskID: nil, kind: .practice, mode: .practice, objectiveIDs: [], phase: .questions, questionIDs: [UUID(), UUID()], startedAt: start)
        s.pause(at: start.addingTimeInterval(300))
        s.resume(at: start.addingTimeInterval(3600))
        XCTAssertEqual(s.activeSeconds(at: start.addingTimeInterval(3660)), 360, accuracy: 0.1)
        s.recordAnswer(attemptID: UUID())
        XCTAssertEqual(s.currentIndex, 1)
        XCTAssertFalse(s.isFinishedAnswering)
    }

    func correctResponse(for q: Question) -> AttemptResponse {
        switch q.kind {
        case .multipleChoice, .trueFalse: return AttemptResponse(selectedIndices: q.correctOptionIndices)
        case .cloze, .shortAnswer: return AttemptResponse(text: q.acceptedAnswers.first)
        case .numeric: return AttemptResponse(text: "\(q.numeric!.value) \(q.numeric!.unit ?? "")")
        case .matching: return AttemptResponse(matching: Array(q.pairs.indices))
        case .freeText: return AttemptResponse(text: q.referenceAnswer, selfRating: 1)
        }
    }
}
