import XCTest
@testable import LernKern

final class StudyPlannerTests: XCTestCase {
    func plan(_ f: Fixture, triggers: [ReplanTrigger] = [.initial], at date: Date? = nil) -> PlanResult {
        let now = date ?? f.now
        var knowledge: [UUID: ObjectiveKnowledge] = [:]
        for exam in f.state.exams { knowledge.merge(ProgressCalculator().knowledgeMap(examID: exam.id, state: f.state, now: now)) { a, _ in a } }
        return StudyPlanner().plan(state: f.state, knowledge: knowledge, triggers: triggers, now: now, calendar: f.calendar)
    }

    func testInitialPlanRespectsTimesCapacityAndOrder() {
        let f = Fixture(examInDays: 14)
        let result = plan(f)
        let tasks = result.tasks
        XCTAssertFalse(tasks.isEmpty)
        XCTAssertEqual(result.change.reasons.first, "Lernplan erstellt.")
        let cal = f.calendar
        let prefs = f.state.preferences
        let byDay = Dictionary(grouping: tasks, by: { DayKey($0.start, calendar: cal) })
        for (day, list) in byDay {
            let dayStart = day.startDate(calendar: cal)!
            let capacity = Double(prefs.minutes(on: dayStart, calendar: cal)) * (1 - prefs.bufferShare)
            let used = list.filter { $0.kind != .simulation }.reduce(0) { $0 + $1.durationMinutes }
            if !list.contains(where: { $0.kind == .simulation }) {
                XCTAssertLessThanOrEqual(Double(used), capacity + 0.5, "Tag \(day) überladen")
            }
            let sorted = list.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                XCTAssertLessThanOrEqual(a.end, b.start, "Überschneidung am \(day)")
            }
            for t in list {
                let endMinute = cal.component(.hour, from: t.end) * 60 + cal.component(.minute, from: t.end)
                XCTAssertLessThanOrEqual(endMinute == 0 ? 24 * 60 : endMinute, prefs.latestEndMinute)
                XCTAssertGreaterThanOrEqual(t.start, f.now)
                XCTAssertLessThan(t.start, f.exam.examDate)
            }
        }
        // Lernen vor Üben je Lernziel
        for o in f.objectives {
            let learn = tasks.filter { $0.kind == .learn && $0.objectiveIDs.contains(o.id) }.map(\.start).min()
            let practice = tasks.filter { $0.kind == .practice && $0.objectiveIDs.contains(o.id) }.map(\.start).min()
            XCTAssertNotNil(learn)
            if let learn, let practice { XCTAssertLessThan(learn, practice) }
        }
        XCTAssertTrue(tasks.contains { $0.kind == .simulation }, "Vor der Prüfung ist eine Simulation geplant")
        XCTAssertTrue(tasks.contains { $0.kind == .review }, "Wiederholungen nach zeitlichem Abstand sind geplant")
        XCTAssertTrue(tasks.allSatisfy { !$0.reason.isEmpty }, "Jede Einheit hat eine Begründung")
    }

    func testReplanningIsStableWhenNothingChanged() {
        var f = Fixture()
        let first = plan(f)
        f.state.tasks = first.tasks
        let second = plan(f, triggers: [.routine])
        XCTAssertEqual(Set(first.tasks.map(\.id)), Set(second.tasks.map(\.id)))
        XCTAssertEqual(second.change.added, 0)
        XCTAssertEqual(second.change.removed, 0)
        XCTAssertEqual(second.change.moved, 0)
    }

    func testMissedTasksAreMarkedAndRedistributedWithoutOverload() {
        var f = Fixture(examInDays: 10)
        let first = plan(f)
        f.state.tasks = first.tasks
        let twoDaysLater = f.calendar.date(byAdding: .day, value: 2, to: f.calendar.at(2026, 10, 23, 7))!
        let result = plan(f, triggers: [.routine], at: twoDaysLater)
        let missed = result.tasks.filter { $0.status == .missed }
        XCTAssertFalse(missed.isEmpty)
        XCTAssertTrue(missed.allSatisfy { $0.end <= twoDaysLater })
        XCTAssertTrue(result.change.reasons.contains { $0.contains("verpasste") })
        // Lernstoff der verpassten Einheiten taucht wieder in der Zukunft auf
        let missedObjectives = Set(missed.filter { $0.kind == .learn }.flatMap(\.objectiveIDs))
        let futureObjectives = Set(result.tasks.filter { $0.start >= twoDaysLater && $0.kind == .learn }.flatMap(\.objectiveIDs))
        XCTAssertTrue(missedObjectives.isSubset(of: futureObjectives))
        // Kein Tag über Kapazität
        let cal = f.calendar
        for (day, list) in Dictionary(grouping: result.tasks.filter { $0.start >= twoDaysLater && $0.kind != .simulation }, by: { DayKey($0.start, calendar: cal) }) {
            let capacity = Double(f.state.preferences.minutes(on: day.startDate(calendar: cal)!, calendar: cal)) * 0.9
            XCTAssertLessThanOrEqual(Double(list.reduce(0) { $0 + $1.durationMinutes }), capacity + 0.5)
        }
    }

    func testPinnedTasksAreNeverChanged() {
        var f = Fixture()
        var tasks = plan(f).tasks
        let index = tasks.firstIndex { $0.kind == .practice }!
        tasks[index].isPinned = true
        tasks[index].start = f.calendar.at(2026, 10, 27, 7, 30)
        let pinned = tasks[index]
        f.state.tasks = tasks
        let result = plan(f, triggers: [.taskMovedByUser])
        XCTAssertEqual(result.tasks.first { $0.id == pinned.id }, pinned)
        let sameDay = result.tasks.filter { $0.id != pinned.id && f.calendar.isDate($0.start, inSameDayAs: pinned.start) }
        for t in sameDay { XCTAssertTrue(t.end <= pinned.start || t.start >= pinned.end, "Keine Überschneidung mit verschobener Einheit") }
    }

    func testMasteredObjectivesGetNoNewLearningTasks() {
        var f = Fixture()
        f.master(f.objectives[0], startingAt: f.now.addingTimeInterval(-3 * 86_400))
        let result = plan(f)
        XCTAssertFalse(result.tasks.contains { ($0.kind == .learn || $0.kind == .practice) && $0.objectiveIDs.contains(f.objectives[0].id) })
    }

    func testStrugglingObjectiveGetsExtraPracticeWithReason() {
        var f = Fixture()
        let o = f.objectives[1]
        for i in 0..<5 { f.answer(o, difficulty: .medium, index: i, correct: false, at: f.now.addingTimeInterval(Double(i) * 60 - 3600)) }
        let result = plan(f, triggers: [.routine])
        let practice = result.tasks.filter { $0.kind == .practice && $0.objectiveIDs.contains(o.id) }
        XCTAssertFalse(practice.isEmpty)
        XCTAssertTrue(practice.contains { $0.reason.contains("Zusätzliche Übung") })
        XCTAssertTrue(result.change.reasons.contains { $0.contains("Meiose erklären") })
    }

    func testInsufficientTimeIsReportedHonestly() {
        var f = Fixture(examInDays: 2)
        f.state.preferences = StudyPreferences(minutesPerWeekday: Array(repeating: 20, count: 7))
        let result = plan(f)
        XCTAssertTrue(result.warnings.contains { $0.kind == .insufficientTime })
        XCTAssertFalse(result.unplacedMinutes.isEmpty)
    }

    func testMultipleExamsShareTimeAndCloseExamsAreFlagged() {
        var f = Fixture(examInDays: 6)
        let second = Exam(title: "Chemie", examDate: f.exam.examDate.addingTimeInterval(86_400))
        let topic = Topic(examID: second.id, title: "Säuren", order: 0, origin: .local, reviewStatus: .confirmed)
        let obj = LearningObjective(examID: second.id, topicID: topic.id, title: "pH-Wert", origin: .local, reviewStatus: .confirmed)
        f.state.exams.append(second)
        f.state.topics.append(topic)
        f.state.objectives.append(obj)
        let result = plan(f)
        XCTAssertTrue(result.tasks.contains { $0.examID == second.id })
        XCTAssertTrue(result.tasks.contains { $0.examID == f.exam.id })
        XCTAssertTrue(result.warnings.contains { $0.kind == .overlappingExams })
    }

    func testBlockedDaysStayFree() {
        var f = Fixture(examInDays: 7)
        let blocked = DayKey(year: 2026, month: 10, day: 25)
        f.state.preferences.blockedDays = [blocked]
        let result = plan(f)
        XCTAssertFalse(result.tasks.contains { DayKey($0.start, calendar: f.calendar) == blocked })
    }

    func testExamModePrioritizesReviewAndSimulation() {
        let f = Fixture(examInDays: 2)
        let result = plan(f)
        XCTAssertTrue(result.tasks.contains { $0.kind == .simulation })
    }
}
