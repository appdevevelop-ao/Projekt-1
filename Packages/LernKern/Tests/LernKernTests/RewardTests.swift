import XCTest
@testable import LernKern

final class RewardCalculatorTests: XCTestCase {
    func input(_ f: Fixture, attempts: [Attempt], earlier: [Attempt], phase: RewardPhase = .building, earnedToday: Int = 0, balance: Int = 0) -> CheckRewardInput {
        var beforeState = f.state
        let ids = Set(attempts.map(\.id))
        beforeState.attempts.removeAll { ids.contains($0.id) }
        let end = attempts.map(\.answeredAt).max() ?? f.now
        let before = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: beforeState, now: end)
        let after = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: end)
        return CheckRewardInput(attempts: attempts, questions: f.state.questionIndex, earlierAttempts: earlier, knowledgeBefore: before, knowledgeAfter: after, phase: phase, earnedToday: earnedToday, balance: balance)
    }

    func testPassedCheckEarnsFiveToTenMinutes() {
        var f = Fixture()
        var attempts: [Attempt] = []
        for i in 0..<6 { attempts.append(f.answer(f.objectives[i % 2], difficulty: .medium, index: i, correct: true, at: f.now.addingTimeInterval(Double(i) * 45))) }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: attempts, earlier: []))
        XCTAssertTrue(grant.passed)
        XCTAssertGreaterThanOrEqual(grant.minutes, 5)
        XCTAssertLessThanOrEqual(grant.minutes, 10 + 2 * 2 + 2) // Grund + mögliche Fortschrittsboni
        XCTAssertFalse(grant.lines.isEmpty)
    }

    func testClickingThroughEarnsNothing() {
        var f = Fixture()
        var attempts: [Attempt] = []
        for i in 0..<6 { attempts.append(f.answer(f.objectives[0], difficulty: .medium, index: i, correct: true, at: f.now.addingTimeInterval(Double(i)), seconds: 1)) }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: attempts, earlier: []))
        XCTAssertEqual(grant.minutes, 0)
        XCTAssertFalse(grant.passed)
        XCTAssertTrue(grant.lines.contains { $0.contains("zu schnell") })
    }

    func testRepeatingRecentlyAnsweredQuestionsEarnsNothing() {
        var f = Fixture()
        var first: [Attempt] = []
        for i in 0..<4 { first.append(f.answer(f.objectives[0], difficulty: .medium, index: i, correct: true, at: f.now.addingTimeInterval(Double(i) * 60))) }
        var repeatAttempts: [Attempt] = []
        let later = f.now.addingTimeInterval(3600)
        for i in 0..<4 { repeatAttempts.append(f.answer(f.objectives[0], difficulty: .medium, index: i, correct: true, at: later.addingTimeInterval(Double(i) * 60))) }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: repeatAttempts, earlier: first))
        XCTAssertEqual(grant.minutes, 0)
        XCTAssertTrue(grant.lines.contains { $0.contains("kürzlich") })
    }

    func testFailedCheckStillRewardsRealImprovementInFoundationPhase() {
        var f = Fixture(prior: .none)
        var attempts: [Attempt] = []
        let pattern = [true, false, true, false, false, true]
        for (i, ok) in pattern.enumerated() { attempts.append(f.answer(f.objectives[0], difficulty: .hard, index: i, correct: ok, at: f.now.addingTimeInterval(Double(i) * 60))) }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: attempts, earlier: [], phase: .building))
        XCTAssertFalse(grant.passed)
        XCTAssertGreaterThan(grant.minutes, 0, "Messbare Verbesserung soll auch ohne Bestehen zählen")
        XCTAssertTrue(grant.lines.contains { $0.contains("Verbesserung") })
    }

    func testFoundationPhaseHasLowerPassThreshold() {
        XCTAssertLessThan(RewardPhase.foundation.passThreshold, RewardPhase.refinement.passThreshold)
    }

    func testDailyCapIsApplied() {
        var f = Fixture()
        var attempts: [Attempt] = []
        for i in 0..<6 { attempts.append(f.answer(f.objectives[i % 4], difficulty: .medium, index: i, correct: true, at: f.now.addingTimeInterval(Double(i) * 45))) }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: attempts, earlier: [], earnedToday: 118))
        XCTAssertEqual(grant.minutes, 2)
        XCTAssertTrue(grant.wasCapped)
    }

    func testTrivialQuestionsOnStableMaterialBarelyCount() {
        var f = Fixture()
        f.master(f.objectives[0], startingAt: f.now)
        let t = f.now.addingTimeInterval(26 * 3600 + 600)
        // Nur leichte Fragen zu bereits stabil beherrschtem Stoff, plus eine falsche mittlere Frage zu neuem Stoff.
        var attempts: [Attempt] = []
        attempts.append(f.answer(f.objectives[1], difficulty: .medium, index: 0, correct: false, at: t))
        attempts.append(f.answer(f.objectives[1], difficulty: .medium, index: 1, correct: false, at: t.addingTimeInterval(60)))
        attempts.append(f.answer(f.objectives[0], difficulty: .easy, correct: true, at: t.addingTimeInterval(120)))
        let earlier = f.state.attempts.filter { a in !attempts.contains { $0.id == a.id } }
        let grant = RewardCalculator().rewardForCheck(input(f, attempts: attempts, earlier: earlier, phase: .building))
        XCTAssertFalse(grant.passed, "Die leichte Frage zu bekanntem Stoff darf die Fehler nicht ausgleichen")
    }

    func testSimulationReward() {
        let calc = RewardCalculator()
        let ids = (0..<10).map { _ in UUID() }
        let attempts = ids.map { Attempt(examID: UUID(), objectiveID: UUID(), questionID: $0, answeredAt: Date(), durationSeconds: 60, score: 1) }
        let sim = ExamSimulationResult(examID: UUID(), startedAt: Date(), finishedAt: Date(), timeLimitMinutes: 30, questionIDs: ids, attemptIDs: attempts.map(\.id), pointsAchieved: 80, pointsPossible: 100, topicScores: [], gradeBandID: "2")
        let grant = calc.rewardForSimulation(sim, attempts: attempts, targetMinFraction: 0.75, earnedToday: 0, balance: 0)
        XCTAssertEqual(grant.minutes, 10 + 8 + 5) // Grund + Qualität (80 %) + Zielbonus
        let incomplete = calc.rewardForSimulation(sim, attempts: Array(attempts.prefix(5)), targetMinFraction: 0.75, earnedToday: 0, balance: 0)
        XCTAssertEqual(incomplete.minutes, 0)
    }

    func testRewardPhaseFromForecast() {
        XCTAssertEqual(RewardPhase.from(forecast: nil, targetMinFraction: 0.75), .building)
    }
}

final class DailyGoalTests: XCTestCase {
    let cal = TestCalendar.make()

    func testRestDayHasNoGoal() {
        let day = DayKey(year: 2026, month: 10, day: 24)
        let goal = DailyGoalPlanner.makeGoal(day: day, tasksToday: [], isStudyDay: false, hasActiveExam: true, phase: .building, dueReviews: 0)
        XCTAssertEqual(goal.requiredChecks, 0)
        XCTAssertTrue(DailyGoalPlanner.status(record: goal, checks: [], simulations: [], calendar: cal).isReached)
    }

    func testGoalCountsPassedAndHalfCreditsForHonestEffort() {
        let day = DayKey(year: 2026, month: 10, day: 23)
        let tasks = (0..<2).map { i in StudyTask(examID: UUID(), kind: .practice, title: "T\(i)", start: cal.at(2026, 10, 23, 16 + i), durationMinutes: 25) }
        let goal = DailyGoalPlanner.makeGoal(day: day, tasksToday: tasks, isStudyDay: true, hasActiveExam: true, phase: .building, dueReviews: 0)
        XCTAssertEqual(goal.requiredChecks, 2)
        let passed = CompletedCheck(examID: UUID(), taskID: nil, completedAt: cal.at(2026, 10, 23, 17), attemptIDs: [], accuracy: 0.9, passed: true, rewardMinutes: 6, dailyGoalCredit: 1)
        let effort = CompletedCheck(examID: UUID(), taskID: nil, completedAt: cal.at(2026, 10, 23, 18), attemptIDs: [], accuracy: 0.4, passed: false, rewardMinutes: 0, dailyGoalCredit: 0.5)
        var status = DailyGoalPlanner.status(record: goal, checks: [passed, effort], simulations: [], calendar: cal)
        XCTAssertFalse(status.isReached)
        XCTAssertEqual(status.progress, 0.75, accuracy: 1e-9)
        status = DailyGoalPlanner.status(record: goal, checks: [passed, effort, effort], simulations: [], calendar: cal)
        XCTAssertTrue(status.isReached)
        // Gestrige Überprüfungen zählen nicht.
        let yesterday = CompletedCheck(examID: UUID(), taskID: nil, completedAt: cal.at(2026, 10, 22, 17), attemptIDs: [], accuracy: 1, passed: true, rewardMinutes: 6, dailyGoalCredit: 1)
        XCTAssertEqual(DailyGoalPlanner.status(record: goal, checks: [yesterday], simulations: [], calendar: cal).credits, 0)
    }

    func testMaintenancePhaseNeedsOnlyOneShortReview() {
        let tasks = (0..<5).map { i in StudyTask(examID: UUID(), kind: .practice, title: "T\(i)", start: cal.at(2026, 10, 23, 10 + i), durationMinutes: 25) }
        let goal = DailyGoalPlanner.makeGoal(day: DayKey(year: 2026, month: 10, day: 23), tasksToday: tasks, isStudyDay: true, hasActiveExam: true, phase: .maintenance, dueReviews: 2)
        XCTAssertEqual(goal.requiredChecks, 1)
    }
}

final class AnswerEvaluatorTests: XCTestCase {
    let examID = UUID()
    let objectiveID = UUID()

    func q(_ kind: QuestionKind, options: [String] = [], correct: [Int] = [], accepted: [String] = [], numeric: NumericAnswer? = nil, pairs: [MatchPair] = []) -> Question {
        Question(examID: examID, objectiveID: objectiveID, kind: kind, prompt: "?", options: options, correctOptionIndices: correct, acceptedAnswers: accepted, numeric: numeric, pairs: pairs, origin: .local)
    }

    func testMultipleChoiceRecordsDistractor() {
        let question = q(.multipleChoice, options: ["Mitose", "Meiose", "Osmose"], correct: [0])
        let wrong = AnswerEvaluator.evaluate(question, response: AttemptResponse(selectedIndices: [1]))
        XCTAssertEqual(wrong.score, 0)
        XCTAssertEqual(wrong.chosenDistractor, "Meiose")
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(selectedIndices: [0])).verdict, .correct)
    }

    func testTextAnswersTolerateCaseArticlesUmlautsAndTypos() {
        let question = q(.cloze, accepted: ["Photosynthese"])
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "die photosynthese")).score, 1)
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "Fotosynthese")).score, 1) // Tippfehler-Toleranz
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "Atmung")).score, 0)
        let umlaut = q(.shortAnswer, accepted: ["Größe"])
        XCTAssertEqual(AnswerEvaluator.evaluate(umlaut, response: AttemptResponse(text: "Groesse")).score, 1)
        let short = q(.shortAnswer, accepted: ["DNA"])
        XCTAssertEqual(AnswerEvaluator.evaluate(short, response: AttemptResponse(text: "RNA")).score, 0, "Kurze Begriffe: keine Tippfehler-Toleranz")
        XCTAssertEqual(AnswerEvaluator.evaluate(q(.cloze, accepted: ["Mitose"]), response: AttemptResponse(text: "Meiose")).score, 0)
    }

    func testNumericChecksValueUnitsAndConversion() {
        let question = q(.numeric, numeric: NumericAnswer(value: 2.5, unit: "m", relativeTolerance: 0.01))
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "2,5 m")).score, 1)
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "250 cm")).score, 1)
        let missingUnit = AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "2.5"))
        XCTAssertEqual(missingUnit.score, 0.5)
        XCTAssertTrue(missingUnit.tags.contains("unitMissing"))
        let wrongUnit = AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "2,5 kg"))
        XCTAssertTrue(wrongUnit.tags.contains("unitWrong"))
        let magnitude = AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "25 m"))
        XCTAssertEqual(magnitude.score, 0)
        XCTAssertTrue(magnitude.tags.contains("magnitude"))
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "abc")).tags, ["unparsable"])
    }

    func testNumberParserFormats() {
        XCTAssertEqual(NumberParser.parse("1.234,5")?.value, 1234.5)
        XCTAssertEqual(NumberParser.parse("1,234.5")?.value, 1234.5)
        XCTAssertEqual(NumberParser.parse("1.000")?.value, 1000)
        XCTAssertEqual(NumberParser.parse("3,5e3 J")?.value, 3500)
        XCTAssertEqual(NumberParser.parse("3,5e3 J")?.unit, "J")
        XCTAssertEqual(NumberParser.parse("2·10^-3 s")!.value, 0.002, accuracy: 1e-12)
        XCTAssertEqual(NumberParser.parse("-4 °C")?.value, -4)
    }

    func testMatchingPartialCredit() {
        let question = q(.matching, pairs: [MatchPair(left: "A", right: "1"), MatchPair(left: "B", right: "2"), MatchPair(left: "C", right: "3"), MatchPair(left: "D", right: "4")])
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(matching: [0, 1, 3, 2])).score, 0.5)
    }

    func testFreeTextNeedsReviewUnlessSelfRated() {
        let question = q(.freeText)
        XCTAssertEqual(AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "…")).verdict, .needsReview)
        let rated = AnswerEvaluator.evaluate(question, response: AttemptResponse(text: "…", selfRating: 0.75))
        XCTAssertEqual(rated.grading.kind, .selfAssessed)
        XCTAssertEqual(rated.score, 0.75)
    }

    func testRubricCoverage() {
        let result = AnswerEvaluator.rubricCoverage(answer: "Bei der Mitose entstehen zwei genetisch identische Tochterzellen.",
                                                    rubric: ["zwei identische Tochterzellen", "Chromosomen werden in der Metaphase angeordnet"])
        XCTAssertEqual(result.covered.count, 1)
        XCTAssertEqual(result.missing.count, 1)
    }
}
