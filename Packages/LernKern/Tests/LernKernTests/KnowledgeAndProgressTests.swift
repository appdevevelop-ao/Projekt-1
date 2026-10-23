import XCTest
@testable import LernKern

final class KnowledgeTracerTests: XCTestCase {
    func testNoAttemptsMeansNotStartedAndZeroProgress() {
        let f = Fixture()
        let p = ProgressCalculator().progress(examID: f.exam.id, state: f.state, now: f.now)
        XCTAssertEqual(p.percent, 0)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.levelCounts[.notStarted], 4)
        XCTAssertEqual(p.missing.first?.kind, .notStarted)
    }

    func testOpeningOrSingleCorrectAnswerIsNotMastery() {
        var f = Fixture()
        f.answer(f.objectives[0], difficulty: .medium, correct: true)
        let k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now)[f.objectives[0].id]!
        XCTAssertEqual(k.level, .learned)
        XCTAssertLessThan(k.score, 0.6)
    }

    func testProvisionalNeedsDistinctQuestionsAndConsistency() {
        var f = Fixture()
        let o = f.objectives[0]
        // Fünfmal DIESELBE Frage richtig → keine unterschiedlichen Formulierungen.
        for i in 0..<5 { f.answer(o, difficulty: .medium, index: 0, correct: true, at: f.now.addingTimeInterval(Double(i) * 60)) }
        var k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(600))[o.id]!
        XCTAssertEqual(k.level, .learned)
        XCTAssertFalse(k.criterion(.distinctQuestions)!.isMet)
        // Eine zweite Formulierung richtig → vorläufig beherrscht.
        f.answer(o, difficulty: .medium, index: 1, correct: true, at: f.now.addingTimeInterval(400))
        k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(600))[o.id]!
        XCTAssertEqual(k.level, .provisional)
        XCTAssertGreaterThanOrEqual(k.score, 0.6)
        XCTAssertLessThan(k.score, 1)
    }

    func testStableRequiresSpacedRecallAndHardQuestion() {
        var f = Fixture()
        let o = f.objectives[0]
        // Alles am selben Tag, inkl. schwerer Aufgabe → nur vorläufig.
        for (i, d) in [Difficulty.medium, .medium, .medium, .hard, .medium].enumerated() {
            f.answer(o, difficulty: d, index: i, correct: true, at: f.now.addingTimeInterval(Double(i) * 60))
        }
        var k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(3600))[o.id]!
        XCTAssertEqual(k.level, .provisional)
        XCTAssertFalse(k.criterion(.spacedRecall)!.isMet)
        XCTAssertTrue(k.criterion(.hardOrTransfer)!.isMet)
        // Am nächsten Tag erneut richtig → stabil.
        let nextDay = f.now.addingTimeInterval(25 * 3600)
        f.answer(o, difficulty: .medium, index: 1, correct: true, at: nextDay)
        k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: nextDay.addingTimeInterval(60))[o.id]!
        XCTAssertEqual(k.level, .stable)
        XCTAssertTrue(k.isComplete)
        XCTAssertEqual(k.score, 1, accuracy: 1e-9)
    }

    func testForgettingMakesReviewDueWithoutDowngradingLevel() {
        var f = Fixture()
        let o = f.objectives[0]
        f.master(o, startingAt: f.now)
        let shortlyAfter = f.now.addingTimeInterval(27 * 3600)
        let k1 = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: shortlyAfter)[o.id]!
        XCTAssertTrue(k1.isComplete)
        // 60 Tage später ist die Erinnerung verblasst.
        let later = f.now.addingTimeInterval(60 * 86_400)
        let k2 = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: later)[o.id]!
        XCTAssertEqual(k2.level, .stable, "Erreichte Stufe bleibt erhalten – kein künstliches Zurücksetzen")
        XCTAssertFalse(k2.isComplete, "Aber 100 % verlangt präsentes Wissen")
        XCTAssertTrue(k2.isReviewDue(at: later))
        XCTAssertLessThan(k2.retrievability, 0.85)
    }

    func testFailuresLowerAbilityAndCountLapses() {
        var f = Fixture()
        let o = f.objectives[0]
        f.master(o, startingAt: f.now)
        let before = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(30 * 3600))[o.id]!
        let t = f.now.addingTimeInterval(4 * 86_400)
        for i in 0..<3 { f.answer(o, difficulty: .medium, index: i, correct: false, at: t.addingTimeInterval(Double(i) * 60)) }
        let after = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: t.addingTimeInterval(600))[o.id]!
        XCTAssertLessThan(after.ability, before.ability)
        XCTAssertGreaterThanOrEqual(after.lapses, 1)
        XCTAssertLessThan(after.level, .stable)
    }

    func testReportedQuestionsAndVoidedAttemptsDoNotCount() {
        var f = Fixture()
        let o = f.objectives[0]
        let a = f.answer(o, difficulty: .medium, correct: true)
        if let qi = f.state.questions.firstIndex(where: { $0.id == a.questionID }) { f.state.questions[qi].status = .reported }
        let k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(60))[o.id]!
        XCTAssertEqual(k.attemptCount, 0)
        XCTAssertEqual(k.level, .notStarted)
    }

    func testSelfAssessmentCountsLessThanAutomaticGrading() {
        var f = Fixture()
        let o = f.objectives[0]
        let q = f.questions(for: o)[1]
        for i in 0..<3 {
            f.state.attempts.append(Attempt(examID: f.exam.id, objectiveID: o.id, questionID: q.id, answeredAt: f.now.addingTimeInterval(Double(i) * 60), durationSeconds: 30, score: 1, grading: .selfAssessed))
        }
        let k = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(600))[o.id]!
        XCTAssertEqual(k.weightedCorrect, 1.5, accuracy: 1e-9)
        XCTAssertFalse(k.criterion(.correctAnswers)!.isMet)
    }
}

final class ProgressTests: XCTestCase {
    func testHundredPercentOnlyWhenEveryObjectiveIsComplete() {
        var f = Fixture()
        for o in f.objectives.dropLast() { f.master(o, startingAt: f.now) }
        let check = f.now.addingTimeInterval(27 * 3600)
        var p = ProgressCalculator().progress(examID: f.exam.id, state: f.state, now: check)
        XCTAssertFalse(p.isComplete)
        XCTAssertLessThanOrEqual(p.percent, 99)
        XCTAssertGreaterThan(p.percent, 50)
        XCTAssertEqual(p.missing.first?.kind, .notStarted)
        XCTAssertEqual(p.missing.first?.objectiveIDs, [f.objectives[3].id])

        f.master(f.objectives[3], startingAt: f.now)
        p = ProgressCalculator().progress(examID: f.exam.id, state: f.state, now: check)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.percent, 100)
        XCTAssertTrue(p.missing.isEmpty)
    }

    func testDisplayNeverRoundsUpToHundred() {
        XCTAssertEqual(ProgressCalculator.displayPercent(0.9999, isComplete: false), 99)
        XCTAssertEqual(ProgressCalculator.displayPercent(0.92, isComplete: false), 92)
        XCTAssertEqual(ProgressCalculator.displayPercent(1, isComplete: true), 100)
    }

    func testStrongEasyTopicCannotMaskGapInOtherTopic() {
        var f = Fixture()
        // Thema A (Kernthema) vollständig, Thema B gar nicht.
        f.master(f.objectives[0], startingAt: f.now)
        f.master(f.objectives[1], startingAt: f.now)
        let p = ProgressCalculator().progress(examID: f.exam.id, state: f.state, now: f.now.addingTimeInterval(27 * 3600))
        XCTAssertFalse(p.isComplete)
        let topicB = p.topics.first { $0.topic.id == f.topicB.id }!
        XCTAssertEqual(topicB.percent, 0)
        XCTAssertTrue(p.missing.contains { $0.kind == .notStarted })
    }

    func testWeightsRespectExplicitExamShares() {
        var f = Fixture()
        f.state.topics[1].examWeight = 0.8 // Genetik = 80 % der Prüfung
        let weights = ObjectiveWeights.compute(topics: f.state.topics(for: f.exam.id), objectives: f.state.objectives(for: f.exam.id))
        let genetics = f.objectives.filter { $0.topicID == f.topicB.id }.reduce(0) { $0 + weights[$1.id]! }
        XCTAssertEqual(genetics, 0.8, accuracy: 1e-9)
        XCTAssertEqual(weights.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testFullMasteryEvaluatorRequiresActiveExamWithObjectives() {
        let cal = TestCalendar.make()
        let empty = AppState()
        XCTAssertFalse(FullMasteryEvaluator.evaluate(state: empty, now: cal.at(2026, 10, 23), calendar: cal).isComplete)

        var f = Fixture()
        for o in f.objectives { f.master(o, startingAt: f.now) }
        let check = f.now.addingTimeInterval(27 * 3600)
        XCTAssertTrue(FullMasteryEvaluator.evaluate(state: f.state, now: check, calendar: f.calendar).isComplete)

        // Eine zweite aktive Prüfung ohne Lernziele verhindert 100 %.
        let second = Exam(title: "Chemie", examDate: check.addingTimeInterval(10 * 86_400))
        f.state.exams.append(second)
        let status = FullMasteryEvaluator.evaluate(state: f.state, now: check, calendar: f.calendar)
        XCTAssertFalse(status.isComplete)
        XCTAssertTrue(status.explanation.contains("Chemie"))
    }
}
