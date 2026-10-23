import Foundation

/// Warum die Sperre gerade aktiv ist.
public struct LockCause: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Eine festgelegte Lernzeit läuft.
    public static let studyWindow = LockCause(rawValue: 1 << 0)
    /// Das Tagesziel ist noch nicht erreicht.
    public static let dailyGoal = LockCause(rawValue: 1 << 1)
}

/// Der fachliche Sperrstatus – eine eindeutige Zustandsbeschreibung für UI und Erweiterungen.
public enum LockStatus: Hashable, Sendable {
    /// Die Sperrfunktion ist ausgeschaltet.
    case disabled
    /// Es wurden noch keine Apps oder Kategorien ausgewählt.
    case notConfigured
    /// Die Bildschirmzeit-Berechtigung fehlt (oder wurde entzogen).
    case permissionMissing
    /// 100 % erreicht: alles frei bis Mitternacht.
    case fullDayUnlock(DayKey)
    /// Notfall-Pause läuft.
    case emergencyPause(until: Date)
    /// Eingelöste Belohnung läuft.
    case rewardWindow(until: Date)
    /// Tagesziel erreicht, und es läuft gerade keine Lernzeit.
    case dailyGoalReached
    /// Keine Lernzeit und kein offenes Tagesziel – aktuell keine Sperre.
    case outsideLockTimes(nextLock: Date?)
    /// Sperre aktiv.
    case locked(LockCause, until: Date?)
}

/// Ergebnis einer Auswertung: Soll die Sperre JETZT aktiv sein, und wann muss neu ausgewertet werden?
public struct ShieldDecision: Hashable, Sendable {
    public var status: LockStatus
    public var shouldShield: Bool
    /// Nächster Zeitpunkt, zu dem sich die Entscheidung ändern kann.
    public var nextReevaluation: Date?

    public init(status: LockStatus, shouldShield: Bool, nextReevaluation: Date?) {
        self.status = status
        self.shouldShield = shouldShield
        self.nextReevaluation = nextReevaluation
    }
}

/// Rahmenbedingungen, die nur das Betriebssystem kennt.
public struct ShieldEnvironment: Hashable, Sendable {
    public var isAuthorized: Bool
    public var hasSelection: Bool

    public init(isAuthorized: Bool, hasSelection: Bool) {
        self.isAuthorized = isAuthorized
        self.hasSelection = hasSelection
    }
}

/// Reine Entscheidungslogik für die App-Sperre.
///
/// App und Erweiterungen rufen dieselbe Funktion mit demselben gespeicherten Zustand auf.
/// Dadurch gibt es keine widersprüchlichen Zustände: Die Sperre wird nie über verteilte
/// Ereignisse "umgeschaltet", sondern stets aus dem aktuellen Zustand neu abgeleitet.
public enum ShieldDecisionEngine {
    public static func decide(
        policy: ShieldPolicy,
        ledger: UnlockLedger,
        environment: ShieldEnvironment,
        now: Date,
        calendar: Calendar
    ) -> ShieldDecision {
        guard policy.isEnabled else {
            return ShieldDecision(status: .disabled, shouldShield: false, nextReevaluation: nil)
        }
        guard environment.hasSelection else {
            return ShieldDecision(status: .notConfigured, shouldShield: false, nextReevaluation: nil)
        }
        guard environment.isAuthorized else {
            return ShieldDecision(status: .permissionMissing, shouldShield: false, nextReevaluation: nil)
        }

        let today = DayKey(now, calendar: calendar)
        let endOfToday = today.endDate(calendar: calendar)

        // 1. Vollständige Tagesfreigabe hat Vorrang vor allem anderen – bis Mitternacht.
        if ledger.hasFullMasteryUnlock(on: today) {
            return ShieldDecision(status: .fullDayUnlock(today), shouldShield: false, nextReevaluation: endOfToday)
        }

        let boundaries = upcomingBoundaries(policy: policy, ledger: ledger, now: now, calendar: calendar)
        let nextBoundary = boundaries.first

        // 2. Notfall-Pause.
        if let pause = ledger.emergencyPause, pause.contains(now) {
            return ShieldDecision(status: .emergencyPause(until: pause.end), shouldShield: false, nextReevaluation: pause.end)
        }

        // 3. Muss gerade gesperrt sein?
        let cause = lockCause(policy: policy, ledger: ledger, today: today, now: now, calendar: calendar)
        if cause.isEmpty {
            let nextLock = nextLockStart(policy: policy, ledger: ledger, now: now, calendar: calendar)
            let goalReached = policy.usesDailyGoal && ledger.hasDailyGoalUnlock(on: today)
            let lockLaterToday = nextLock.map { lock in endOfToday.map { lock < $0 } ?? false } ?? false
            if goalReached && !lockLaterToday {
                return ShieldDecision(status: .dailyGoalReached, shouldShield: false, nextReevaluation: nextBoundary)
            }
            return ShieldDecision(status: .outsideLockTimes(nextLock: nextLock), shouldShield: false, nextReevaluation: nextBoundary)
        }

        // 4. Eingelöste Belohnung (im strengen Modus nicht während der Lernzeit).
        if let window = ledger.rewardWindow, window.contains(now), canUseReward(policy: policy, cause: cause) {
            return ShieldDecision(status: .rewardWindow(until: window.end), shouldShield: false, nextReevaluation: window.end)
        }

        let until = lockEnd(policy: policy, cause: cause, now: now, calendar: calendar)
        return ShieldDecision(status: .locked(cause, until: until), shouldShield: true, nextReevaluation: nextBoundary)
    }

    /// Ob eine Belohnung gerade eingelöst werden darf (fachliche Regel, ohne Kontostand).
    public static func canRedeemReward(policy: ShieldPolicy, ledger: UnlockLedger, environment: ShieldEnvironment, now: Date, calendar: Calendar) -> RedemptionCheck {
        let decision = decide(policy: policy, ledger: ledger, environment: environment, now: now, calendar: calendar)
        switch decision.status {
        case .locked(let cause, _):
            return canUseReward(policy: policy, cause: cause) ? .allowed : .blockedByStrictMode
        case .rewardWindow:
            return .allowed
        case .disabled, .notConfigured, .permissionMissing:
            return .lockNotActive
        case .fullDayUnlock, .dailyGoalReached, .outsideLockTimes, .emergencyPause:
            return .notNeeded
        }
    }

    public enum RedemptionCheck: Hashable, Sendable {
        case allowed
        case notNeeded
        case lockNotActive
        case blockedByStrictMode
    }

    static func canUseReward(policy: ShieldPolicy, cause: LockCause) -> Bool {
        !(policy.mode == .strict && cause.contains(.studyWindow))
    }

    static func lockCause(policy: ShieldPolicy, ledger: UnlockLedger, today: DayKey, now: Date, calendar: Calendar) -> LockCause {
        let inWindow = policy.activeStudyWindow(at: now, calendar: calendar) != nil
        let goalOpen = !ledger.hasDailyGoalUnlock(on: today)
        switch policy.mode {
        case .focus, .strict:
            return inWindow ? .studyWindow : []
        case .combined:
            return inWindow && goalOpen ? [.studyWindow, .dailyGoal] : []
        case .dailyGoal:
            return goalOpen && minuteOfDay(now, calendar: calendar) >= policy.dailyGoalLockStartMinute ? .dailyGoal : []
        }
    }

    /// Bis wann die Sperre voraussichtlich gilt (nil = bis zum Erreichen des Tagesziels).
    static func lockEnd(policy: ShieldPolicy, cause: LockCause, now: Date, calendar: Calendar) -> Date? {
        if policy.mode == .dailyGoal { return nil }
        guard let window = policy.activeStudyWindow(at: now, calendar: calendar) else { return nil }
        return date(minute: window.endMinute, sameDayAs: now, calendar: calendar)
    }

    static func nextLockStart(policy: ShieldPolicy, ledger: UnlockLedger, now: Date, calendar: Calendar) -> Date? {
        for boundary in upcomingBoundaries(policy: policy, ledger: ledger, now: now, calendar: calendar) {
            let probe = boundary.addingTimeInterval(1)
            let day = DayKey(probe, calendar: calendar)
            if ledger.hasFullMasteryUnlock(on: day) { continue }
            if !lockCause(policy: policy, ledger: ledger, today: day, now: probe, calendar: calendar).isEmpty {
                return boundary
            }
        }
        return nil
    }

    /// Alle Zeitpunkte in den nächsten 48 Stunden, an denen sich die Entscheidung ändern kann (sortiert).
    public static func upcomingBoundaries(policy: ShieldPolicy, ledger: UnlockLedger, now: Date, calendar: Calendar) -> [Date] {
        var result: Set<Date> = []
        let today = DayKey(now, calendar: calendar)
        for offset in 0...2 {
            let day = today.adding(days: offset, calendar: calendar)
            guard let dayStart = day.startDate(calendar: calendar) else { continue }
            result.insert(dayStart)
            let weekday = calendar.component(.weekday, from: dayStart)
            if policy.usesStudyWindows {
                for window in policy.studyWindows where window.weekday == weekday {
                    if let s = date(minute: window.startMinute, sameDayAs: dayStart, calendar: calendar) { result.insert(s) }
                    if let e = date(minute: window.endMinute, sameDayAs: dayStart, calendar: calendar) { result.insert(e) }
                }
            }
            if policy.mode == .dailyGoal, let s = date(minute: policy.dailyGoalLockStartMinute, sameDayAs: dayStart, calendar: calendar) {
                result.insert(s)
            }
        }
        if let w = ledger.rewardWindow { result.insert(w.end) }
        if let p = ledger.emergencyPause { result.insert(p.end) }
        return result.filter { $0 > now }.sorted()
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    static func date(minute: Int, sameDayAs reference: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: reference)
        if minute >= 24 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: start)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start)
    }
}
