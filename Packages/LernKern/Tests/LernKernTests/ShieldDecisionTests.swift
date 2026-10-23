import XCTest
@testable import ShieldLogic

final class ShieldDecisionTests: XCTestCase {
    let cal = TestCalendar.make()
    let env = ShieldEnvironment(isAuthorized: true, hasSelection: true)

    /// Freitag, 23.10.2026 – Wochentag 6 im gregorianischen Kalender (1 = Sonntag).
    var friday: Int { cal.component(.weekday, from: cal.at(2026, 10, 23)) }

    func policy(_ mode: LockMode, windows: [StudyWindow] = []) -> ShieldPolicy {
        ShieldPolicy(isEnabled: true, mode: mode, studyWindows: windows, dailyGoalLockStartMinute: 6 * 60)
    }

    func testDisabledAndMissingPermissionNeverShield() {
        let p = policy(.dailyGoal)
        var disabled = p
        disabled.isEnabled = false
        let now = cal.at(2026, 10, 23, 12)
        XCTAssertEqual(ShieldDecisionEngine.decide(policy: disabled, ledger: .init(), environment: env, now: now, calendar: cal).status, .disabled)
        let noAuth = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: .init(isAuthorized: false, hasSelection: true), now: now, calendar: cal)
        XCTAssertEqual(noAuth.status, .permissionMissing)
        XCTAssertFalse(noAuth.shouldShield)
        let noSelection = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: .init(isAuthorized: true, hasSelection: false), now: now, calendar: cal)
        XCTAssertEqual(noSelection.status, .notConfigured)
    }

    func testFocusModeLocksOnlyDuringStudyWindow() {
        let p = policy(.focus, windows: [StudyWindow(weekday: friday, startMinute: 16 * 60, endMinute: 18 * 60)])
        let before = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 15, 59), calendar: cal)
        XCTAssertFalse(before.shouldShield)
        XCTAssertEqual(before.status, .outsideLockTimes(nextLock: cal.at(2026, 10, 23, 16)))
        XCTAssertEqual(before.nextReevaluation, cal.at(2026, 10, 23, 16))

        let during = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 16, 30), calendar: cal)
        XCTAssertTrue(during.shouldShield)
        XCTAssertEqual(during.status, .locked(.studyWindow, until: cal.at(2026, 10, 23, 18)))

        let after = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 18, 0), calendar: cal)
        XCTAssertFalse(after.shouldShield)
    }

    func testCombinedModeEndsWindowLockWhenDailyGoalReached() {
        let p = policy(.combined, windows: [
            StudyWindow(weekday: friday, startMinute: 9 * 60, endMinute: 10 * 60),
            StudyWindow(weekday: friday, startMinute: 16 * 60, endMinute: 18 * 60),
        ])
        let now = cal.at(2026, 10, 23, 9, 30)
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: now, calendar: cal).shouldShield)

        let ledger = UnlockActions.grantDailyGoalUnlock(ledger: .init(), now: now, calendar: cal)
        let afterGoal = ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: now, calendar: cal)
        XCTAssertFalse(afterGoal.shouldShield)
        XCTAssertEqual(afterGoal.status, .dailyGoalReached)
        // Auch das spätere Fenster am selben Tag bleibt frei.
        XCTAssertFalse(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 23, 17), calendar: cal).shouldShield)
        // Eine Woche später gilt das Fenster wieder.
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 30, 9, 30), calendar: cal).shouldShield)
    }

    func testDailyGoalModeLocksFromStartTimeUntilGoal() {
        let p = policy(.dailyGoal)
        XCTAssertFalse(ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 5, 59), calendar: cal).shouldShield)
        let locked = ShieldDecisionEngine.decide(policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 6, 0), calendar: cal)
        XCTAssertEqual(locked.status, .locked(.dailyGoal, until: nil))
        let ledger = UnlockActions.grantDailyGoalUnlock(ledger: .init(), now: cal.at(2026, 10, 23, 14), calendar: cal)
        let free = ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 23, 23, 59, 59), calendar: cal)
        XCTAssertEqual(free.status, .dailyGoalReached)
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 24, 6, 0), calendar: cal).shouldShield)
    }

    func testFullMasteryUnlockHoldsUntilMidnightAndOverridesEverything() {
        let p = policy(.strict, windows: (1...7).map { StudyWindow(weekday: $0, startMinute: 0, endMinute: 24 * 60) })
        let granted = cal.at(2026, 10, 23, 11, 15)
        let ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: granted, calendar: cal)

        for probe in [granted, cal.at(2026, 10, 23, 18), cal.at(2026, 10, 23, 23, 59, 59)] {
            let decision = ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: probe, calendar: cal)
            XCTAssertFalse(decision.shouldShield, "Am selben Tag darf nicht erneut gesperrt werden (\(probe))")
            XCTAssertEqual(decision.status, .fullDayUnlock(DayKey(year: 2026, month: 10, day: 23)))
            XCTAssertEqual(decision.nextReevaluation, cal.at(2026, 10, 24))
        }
        let nextDay = ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 24, 0, 0, 1), calendar: cal)
        XCTAssertTrue(nextDay.shouldShield, "Am Folgetag gilt wieder die reguläre Sperrlogik")
    }

    func testFullMasteryUnlockAcrossDaylightSavingChange() {
        // 25.10.2026: Ende der Sommerzeit in Wien (Tag hat 25 Stunden).
        let p = policy(.dailyGoal)
        let ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: cal.at(2026, 10, 25, 1, 30), calendar: cal)
        XCTAssertFalse(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 25, 23, 30), calendar: cal).shouldShield)
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: cal.at(2026, 10, 26, 6, 1), calendar: cal).shouldShield)
    }

    func testTimeZoneChangeUsesCurrentLocalDay() {
        let p = policy(.dailyGoal)
        let vienna = cal
        let granted = vienna.at(2026, 10, 23, 20) // 18:00 UTC
        let ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: granted, calendar: vienna)
        // Reise nach New York: dort ist es am selben Abend noch der 23.10. → weiterhin frei.
        let newYork = TestCalendar.make("America/New_York")
        let laterInNY = newYork.at(2026, 10, 23, 22)
        XCTAssertFalse(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: laterInNY, calendar: newYork).shouldShield)
        // Reise nach Tokio: dort ist bereits der 24.10. → neue Tagesperiode.
        let tokyo = TestCalendar.make("Asia/Tokyo")
        let inTokyo = tokyo.at(2026, 10, 24, 7)
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: inTokyo, calendar: tokyo).shouldShield)
    }

    func testRewardWindowUnlocksTemporarilyAndExtends() throws {
        let p = policy(.dailyGoal)
        let now = cal.at(2026, 10, 23, 12)
        var ledger = try UnlockActions.redeemReward(minutes: 10, policy: p, ledger: .init(), environment: env, now: now, calendar: cal)
        let during = ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: now.addingTimeInterval(5 * 60), calendar: cal)
        XCTAssertEqual(during.status, .rewardWindow(until: now.addingTimeInterval(600)))
        XCTAssertFalse(during.shouldShield)

        ledger = try UnlockActions.redeemReward(minutes: 5, policy: p, ledger: ledger, environment: env, now: now.addingTimeInterval(5 * 60), calendar: cal)
        XCTAssertEqual(ledger.rewardWindow?.end, now.addingTimeInterval(15 * 60))
        XCTAssertTrue(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: now.addingTimeInterval(15 * 60), calendar: cal).shouldShield)

        let (ended, unused) = UnlockActions.endRewardEarly(ledger: ledger, now: now.addingTimeInterval(9 * 60))
        XCTAssertEqual(unused, 6)
        XCTAssertNil(ended.rewardWindow)
    }

    func testStrictModeBlocksRewardDuringStudyWindow() {
        let p = policy(.strict, windows: [StudyWindow(weekday: friday, startMinute: 16 * 60, endMinute: 18 * 60)])
        XCTAssertThrowsError(try UnlockActions.redeemReward(minutes: 10, policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 16, 10), calendar: cal)) { error in
            XCTAssertEqual(error as? UnlockActionError, .notAllowedInStrictMode)
        }
        XCTAssertThrowsError(try UnlockActions.redeemReward(minutes: 10, policy: p, ledger: .init(), environment: env, now: cal.at(2026, 10, 23, 19), calendar: cal)) { error in
            XCTAssertEqual(error as? UnlockActionError, .notNeeded)
        }
    }

    func testEmergencyPauseIsLimitedPerDay() throws {
        let p = policy(.dailyGoal)
        let now = cal.at(2026, 10, 23, 12)
        var ledger = try UnlockActions.startEmergencyPause(policy: p, ledger: .init(), now: now, calendar: cal)
        XCTAssertEqual(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: now.addingTimeInterval(60), calendar: cal).status, .emergencyPause(until: now.addingTimeInterval(600)))
        ledger = try UnlockActions.startEmergencyPause(policy: p, ledger: ledger, now: now.addingTimeInterval(3600), calendar: cal)
        XCTAssertThrowsError(try UnlockActions.startEmergencyPause(policy: p, ledger: ledger, now: now.addingTimeInterval(7200), calendar: cal))
        XCTAssertNoThrow(try UnlockActions.startEmergencyPause(policy: p, ledger: ledger, now: cal.at(2026, 10, 24, 9), calendar: cal))
    }

    func testPruningKeepsValidUnlocks() {
        let now = cal.at(2026, 10, 23, 12)
        var ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: now, calendar: cal)
        ledger.dailyGoalUnlock = DayUnlock(day: DayKey(year: 2026, month: 10, day: 22), reason: .dailyGoal, grantedAt: now.addingTimeInterval(-86400))
        let pruned = ledger.pruned(now: now, calendar: cal)
        XCTAssertNotNil(pruned.fullMasteryUnlock)
        XCTAssertNil(pruned.dailyGoalUnlock)
    }
}

final class MonitoringPlanTests: XCTestCase {
    let cal = TestCalendar.make()

    func testShortRewardWindowIsRegisteredWithMinimumLength() throws {
        let now = cal.at(2026, 10, 23, 12)
        var ledger = UnlockLedger()
        ledger.rewardWindow = UnlockWindow(start: now, end: now.addingTimeInterval(5 * 60), minutes: 5)
        let p = ShieldPolicy(isEnabled: true, mode: .dailyGoal)
        let activities = MonitoringPlan.activities(policy: p, ledger: ledger, now: now, calendar: cal)
        let reward = try XCTUnwrap(activities.first { $0.kind == .rewardWindow })
        let start = try XCTUnwrap(cal.date(from: reward.start))
        let end = try XCTUnwrap(cal.date(from: reward.end))
        XCTAssertEqual(end, now.addingTimeInterval(300))
        XCTAssertGreaterThanOrEqual(end.timeIntervalSince(start), 15 * 60)
        XCTAssertFalse(reward.repeats)
        XCTAssertTrue(activities.contains { $0.kind == .daily && $0.repeats })
        XCTAssertTrue(activities.contains { $0.kind == .dailyGoalStart })
    }

    func testStudyWindowsBecomeRepeatingWeekdaySchedules() {
        let p = ShieldPolicy(isEnabled: true, mode: .focus, studyWindows: [
            StudyWindow(weekday: 2, startMinute: 16 * 60, endMinute: 17 * 60 + 30),
            StudyWindow(weekday: 3, startMinute: 8 * 60, endMinute: 8 * 60 + 10), // zu kurz für DeviceActivity
        ])
        let activities = MonitoringPlan.activities(policy: p, ledger: .init(), now: cal.at(2026, 10, 23, 12), calendar: cal)
        let windows = activities.filter { $0.kind == .studyWindow }
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.name, "lf.window.2.960.1050")
        XCTAssertEqual(windows.first?.start.weekday, 2)
        XCTAssertEqual(MonitoringPlan.kind(ofActivityNamed: "lf.window.2.960.1050"), .studyWindow)
        XCTAssertNil(MonitoringPlan.kind(ofActivityNamed: "fremd"))
    }

    func testEarlyCallbacksAreEvaluatedAtTheBoundary() {
        let ledger = UnlockLedger()
        // Ende des Lernfensters 17:30 wird 20 s zu früh gemeldet.
        let early = cal.at(2026, 10, 26, 17, 29, 40)
        let evaluated = MonitoringPlan.evaluationDate(activityName: "lf.window.2.960.1050", isEnd: true, now: early, ledger: ledger, calendar: cal)
        XCTAssertEqual(evaluated, cal.at(2026, 10, 26, 17, 30, 1))
        // Tagesstart kurz vor Mitternacht → als neuer Tag.
        let beforeMidnight = cal.at(2026, 10, 23, 23, 59, 30)
        XCTAssertEqual(MonitoringPlan.evaluationDate(activityName: "lf.daily", isEnd: false, now: beforeMidnight, ledger: ledger, calendar: cal), cal.at(2026, 10, 24, 0, 0, 1))
        // Ende des Tagesintervalls (23:59) wird NICHT vorgezogen.
        XCTAssertEqual(MonitoringPlan.evaluationDate(activityName: "lf.daily", isEnd: true, now: beforeMidnight, ledger: ledger, calendar: cal), beforeMidnight)
    }

    func testFullUnlockSurvivesDailyIntervalEndCallback() {
        // Szenario: 100 % am Abend, iOS meldet um 23:59 das Ende des Tagesintervalls.
        let p = ShieldPolicy(isEnabled: true, mode: .dailyGoal)
        let env = ShieldEnvironment(isAuthorized: true, hasSelection: true)
        let ledger = UnlockActions.grantFullMasteryUnlock(ledger: .init(), now: cal.at(2026, 10, 23, 21), calendar: cal)
        let callback = cal.at(2026, 10, 23, 23, 59)
        let at = MonitoringPlan.evaluationDate(activityName: "lf.daily", isEnd: true, now: callback, ledger: ledger, calendar: cal)
        XCTAssertFalse(ShieldDecisionEngine.decide(policy: p, ledger: ledger, environment: env, now: at, calendar: cal).shouldShield)
    }
}
