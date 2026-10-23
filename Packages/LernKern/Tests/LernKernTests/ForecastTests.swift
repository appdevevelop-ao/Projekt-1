import XCTest
@testable import LernKern

final class GradePredictorTests: XCTestCase {
    func forecast(_ f: Fixture, at date: Date? = nil) -> GradeForecast {
        let now = date ?? f.now
        let knowledge = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: now)
        return GradePredictor().forecast(exam: f.exam, topics: f.state.topics(for: f.exam.id), objectives: f.state.objectives(for: f.exam.id),
                                         knowledge: knowledge, simulations: f.state.simulations, now: now)
    }

    func testInsufficientDataGivesNoPreciseClaims() {
        var f = Fixture()
        f.answer(f.objectives[0], difficulty: .medium, correct: true)
        let fc = forecast(f)
        XCTAssertEqual(fc.confidence, .insufficient)
        XCTAssertEqual(fc.targetLikelihood, .unknown)
        XCTAssertEqual(fc.headline, "Noch zu wenige Daten für eine verlässliche Prognose.")
        XCTAssertTrue(fc.details.contains("Eine Prognose ist keine Garantie."))
    }

    func testStrongBroadEvidenceGivesGoodGradeAndRange() {
        var f = Fixture()
        for o in f.objectives { f.master(o, startingAt: f.now) }
        // Zusätzliche Übung, damit genug Daten vorliegen
        var t = f.now.addingTimeInterval(2 * 86_400)
        for o in f.objectives {
            for i in 0..<6 { f.answer(o, difficulty: i % 2 == 0 ? .hard : .medium, index: i, correct: true, at: t); t = t.addingTimeInterval(60) }
        }
        let fc = forecast(f, at: t)
        XCTAssertGreaterThanOrEqual(fc.confidence, .low)
        XCTAssertLessThanOrEqual(fc.scoreLow, fc.expectedScore)
        XCTAssertGreaterThanOrEqual(fc.scoreHigh, fc.expectedScore)
        XCTAssertTrue(["1", "2"].contains(fc.predictedBand.id), "erwartet gute Note, war \(fc.predictedBand.id) bei \(fc.expectedScore)")
        XCTAssertTrue(fc.headline.contains("entspricht ungefähr"))
    }

    func testWeakTopicIsReportedAsLosingPoints() {
        var f = Fixture()
        var t = f.now
        for o in f.objectives {
            let correct = o.topicID == f.topicA.id
            for i in 0..<5 { f.answer(o, difficulty: .medium, index: i, correct: correct, at: t); t = t.addingTimeInterval(60) }
        }
        let fc = forecast(f, at: t)
        XCTAssertEqual(fc.weakestTopics.first?.topicID, f.topicB.id)
        XCTAssertEqual(fc.strongestTopics.first?.topicID, f.topicA.id)
    }

    func testSimulationShiftsForecastTowardsObservedScore() {
        var f = Fixture()
        var t = f.now
        for o in f.objectives { for i in 0..<4 { f.answer(o, difficulty: .medium, index: i, correct: true, at: t); t = t.addingTimeInterval(60) } }
        let before = forecast(f, at: t)
        let sim = ExamSimulationResult(examID: f.exam.id, startedAt: t, finishedAt: t.addingTimeInterval(3600), timeLimitMinutes: 60,
                                       questionIDs: (0..<20).map { _ in UUID() }, attemptIDs: (0..<20).map { _ in UUID() },
                                       pointsAchieved: 20, pointsPossible: 100, topicScores: [], gradeBandID: "5")
        f.state.simulations.append(sim)
        let after = forecast(f, at: t.addingTimeInterval(3700))
        XCTAssertLessThan(after.expectedScore, before.expectedScore)
        XCTAssertEqual(after.recentSimulationCount, 1)
    }

    func testEstimatedScaleWidensUncertaintyAndIsFlagged() {
        var f = Fixture()
        var t = f.now
        for o in f.objectives { for i in 0..<4 { f.answer(o, difficulty: .medium, index: i, correct: i % 2 == 0, at: t); t = t.addingTimeInterval(60) } }
        let estimated = forecast(f, at: t)
        XCTAssertTrue(estimated.scaleIsEstimate)
        XCTAssertTrue(estimated.details.contains { $0.contains("geschätzt") })

        var official = GradeScale.austrian
        official.isOfficial = true
        var g = Fixture(scale: official)
        g.state.attempts = []
        var t2 = g.now
        for o in g.objectives { for i in 0..<4 { g.answer(o, difficulty: .medium, index: i, correct: i % 2 == 0, at: t2); t2 = t2.addingTimeInterval(60) } }
        let precise = forecast(g, at: t2)
        XCTAssertLessThan(precise.scoreHigh - precise.scoreLow, estimated.scoreHigh - estimated.scoreLow)
    }

    func testGradeScaleBands() {
        let s = GradeScale.austrian
        XCTAssertEqual(s.band(for: 0.9).id, "1")
        XCTAssertEqual(s.band(for: 0.875).id, "1")
        XCTAssertEqual(s.band(for: 0.62).id, "4")
        XCTAssertEqual(s.band(for: 0.1).id, "5")
        XCTAssertTrue(s.isAtLeast("2", "3"))
        XCTAssertFalse(s.isAtLeast("4", "3"))
        XCTAssertTrue(s.validationErrors.isEmpty)
        let points = GradeScale.points(maxPoints: 60, thresholds: [("1", "Sehr gut", 54, true), ("2", "Gut", 45, true), ("3", "Befriedigend", 38, true), ("4", "Genügend", 30, true), ("5", "Nicht genügend", 0, false)], isOfficial: true)
        XCTAssertEqual(points.band(for: 45.0 / 60).id, "2")
        XCTAssertEqual(GradeScale.passFail(threshold: 0.6, isOfficial: true).band(for: 0.59).id, "fail")
        let broken = GradeScale(kind: .custom, name: "x", bands: [GradeBand(id: "a", label: "A", name: "A", minFraction: 0.5, isPassing: false)], isOfficial: false)
        XCTAssertFalse(broken.validationErrors.isEmpty)
    }
}

final class TimeEstimatorTests: XCTestCase {
    func estimate(_ f: Fixture, days: Int? = nil, prefs: StudyPreferences = StudyPreferences()) -> TimeForecast {
        let knowledge = ProgressCalculator().knowledgeMap(examID: f.exam.id, state: f.state, now: f.now)
        let fc = GradePredictor().forecast(exam: f.exam, topics: f.state.topics(for: f.exam.id), objectives: f.state.objectives(for: f.exam.id), knowledge: knowledge, simulations: [], now: f.now)
        return TimeEstimator().estimate(exam: f.exam, topics: f.state.topics(for: f.exam.id), objectives: f.state.objectives(for: f.exam.id),
                                        knowledge: knowledge, forecast: fc, preferences: prefs, completedTasks: [], now: f.now, calendar: f.calendar)
    }

    func testRangesAreOrderedAndStableNeedsMoreThanProvisional() {
        let f = Fixture()
        let t = estimate(f)
        XCTAssertLessThan(t.toProvisional.low, t.toProvisional.high)
        XCTAssertGreaterThan(t.toStable.low, t.toProvisional.low)
        XCTAssertNotNil(t.toTarget)
        XCTAssertGreaterThan(t.availableMinutes, 0)
        XCTAssertTrue(t.headline.contains("Voraussichtlich noch"))
    }

    func testMasteredMaterialNeedsLittleTime() {
        var f = Fixture()
        let fresh = estimate(f)
        for o in f.objectives { f.master(o, startingAt: f.now) }
        f.now = f.now.addingTimeInterval(27 * 3600)
        let done = estimate(f)
        XCTAssertLessThan(done.toStable.high, fresh.toStable.low)
    }

    func testUnrealisticPlanOffersHonestOptionsWithoutChangingTarget() {
        let f = Fixture(examInDays: 1, prior: .none, target: "1")
        let t = estimate(f, prefs: StudyPreferences(minutesPerWeekday: Array(repeating: 15, count: 7)))
        XCTAssertNotEqual(t.feasibility, .comfortable)
        XCTAssertFalse(t.scenarios.isEmpty)
        XCTAssertEqual(f.exam.targetGradeID, "1", "Das Ziel wird nie stillschweigend geändert")
    }

    func testAvailableMinutesRespectBlockedDaysAndBuffer() {
        let cal = TestCalendar.make()
        let now = cal.at(2026, 10, 23, 8)
        var prefs = StudyPreferences(minutesPerWeekday: Array(repeating: 100, count: 7), bufferShare: 0.1)
        prefs.blockedDays = [DayKey(year: 2026, month: 10, day: 24)]
        let minutes = TimeEstimator().availableMinutes(preferences: prefs, from: now, days: 3, completedTasks: [], calendar: cal)
        XCTAssertEqual(minutes, 180) // 2 Tage × 100 × 0,9
    }

    func testMinuteRangeText() {
        XCTAssertEqual(MinuteRange(low: 720, high: 1080).text, "12–18 Std.")
        XCTAssertEqual(MinuteRange(low: 38, high: 62).text, "40–60 Min.")
        XCTAssertEqual(MinuteRange.approximate(150), "2,5 Std.")
    }
}
