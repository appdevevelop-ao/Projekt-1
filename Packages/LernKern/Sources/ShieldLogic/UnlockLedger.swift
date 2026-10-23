import Foundation

/// Grund für eine Freigabe bis zum Tagesende.
public enum DayUnlockReason: String, Codable, Sendable {
    /// Alle Kriterien für 100 % Lernfortschritt sind erfüllt.
    case fullMastery
    /// Das Tagesziel wurde erreicht (beendet nur die Tagesziel-Sperre).
    case dailyGoal
}

public struct DayUnlock: Codable, Hashable, Sendable {
    public var day: DayKey
    public var reason: DayUnlockReason
    public var grantedAt: Date

    public init(day: DayKey, reason: DayUnlockReason, grantedAt: Date) {
        self.day = day
        self.reason = reason
        self.grantedAt = grantedAt
    }
}

/// Ein Zeitraum, in dem die Sperre aufgehoben ist (eingelöste Belohnung oder Notfall-Pause).
public struct UnlockWindow: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var minutes: Int

    public init(start: Date, end: Date, minutes: Int) {
        self.start = start
        self.end = end
        self.minutes = minutes
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Persistenter Freigabe-Zustand. Quelle der Wahrheit für App UND Erweiterungen.
public struct UnlockLedger: Codable, Hashable, Sendable {
    public var fullMasteryUnlock: DayUnlock?
    public var dailyGoalUnlock: DayUnlock?
    public var rewardWindow: UnlockWindow?
    public var emergencyPause: UnlockWindow?
    /// Anzahl genutzter Notfall-Pausen pro Tag ("JJJJ-MM-TT" → Anzahl).
    public var emergencyPausesUsed: [String: Int]

    public init(
        fullMasteryUnlock: DayUnlock? = nil,
        dailyGoalUnlock: DayUnlock? = nil,
        rewardWindow: UnlockWindow? = nil,
        emergencyPause: UnlockWindow? = nil,
        emergencyPausesUsed: [String: Int] = [:]
    ) {
        self.fullMasteryUnlock = fullMasteryUnlock
        self.dailyGoalUnlock = dailyGoalUnlock
        self.rewardWindow = rewardWindow
        self.emergencyPause = emergencyPause
        self.emergencyPausesUsed = emergencyPausesUsed
    }

    public func hasFullMasteryUnlock(on day: DayKey) -> Bool { fullMasteryUnlock?.day == day }
    public func hasDailyGoalUnlock(on day: DayKey) -> Bool { dailyGoalUnlock?.day == day }

    public func emergencyPausesUsed(on day: DayKey) -> Int { emergencyPausesUsed[day.description] ?? 0 }

    /// Entfernt abgelaufene Einträge, ohne gültige Freigaben anzutasten.
    public func pruned(now: Date, calendar: Calendar) -> UnlockLedger {
        var copy = self
        let today = DayKey(now, calendar: calendar)
        if let unlock = copy.fullMasteryUnlock, unlock.day < today { copy.fullMasteryUnlock = nil }
        if let unlock = copy.dailyGoalUnlock, unlock.day < today { copy.dailyGoalUnlock = nil }
        if let window = copy.rewardWindow, window.end <= now { copy.rewardWindow = nil }
        if let pause = copy.emergencyPause, pause.end <= now { copy.emergencyPause = nil }
        let cutoff = today.adding(days: -7, calendar: calendar)
        copy.emergencyPausesUsed = copy.emergencyPausesUsed.filter { key, _ in
            guard let day = DayKey(string: key) else { return false }
            return day >= cutoff
        }
        return copy
    }
}
