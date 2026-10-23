import Foundation

/// Fehler beim Einlösen oder Pausieren.
public enum UnlockActionError: Error, Hashable, Sendable {
    case invalidMinutes
    case notAllowedInStrictMode
    case notNeeded
    case lockNotActive
    case noEmergencyPausesLeft
}

/// Reine Funktionen, die den Freigabe-Zustand verändern.
public enum UnlockActions {
    /// Löst verdiente Minuten ein. Ein laufendes Fenster wird verlängert.
    public static func redeemReward(
        minutes: Int,
        policy: ShieldPolicy,
        ledger: UnlockLedger,
        environment: ShieldEnvironment,
        now: Date,
        calendar: Calendar
    ) throws(UnlockActionError) -> UnlockLedger {
        guard minutes > 0, minutes <= 24 * 60 else { throw .invalidMinutes }
        switch ShieldDecisionEngine.canRedeemReward(policy: policy, ledger: ledger, environment: environment, now: now, calendar: calendar) {
        case .allowed: break
        case .notNeeded: throw .notNeeded
        case .lockNotActive: throw .lockNotActive
        case .blockedByStrictMode: throw .notAllowedInStrictMode
        }
        var copy = ledger
        if let current = ledger.rewardWindow, current.contains(now) {
            copy.rewardWindow = UnlockWindow(
                start: current.start,
                end: current.end.addingTimeInterval(Double(minutes * 60)),
                minutes: current.minutes + minutes
            )
        } else {
            copy.rewardWindow = UnlockWindow(start: now, end: now.addingTimeInterval(Double(minutes * 60)), minutes: minutes)
        }
        return copy
    }

    /// Beendet ein laufendes Belohnungsfenster vorzeitig und gibt die nicht genutzten Minuten zurück.
    public static func endRewardEarly(ledger: UnlockLedger, now: Date) -> (ledger: UnlockLedger, unusedMinutes: Int) {
        guard let window = ledger.rewardWindow, window.contains(now) else { return (ledger, 0) }
        var copy = ledger
        copy.rewardWindow = nil
        let unused = Int((window.end.timeIntervalSince(now) / 60).rounded(.down))
        return (copy, max(0, unused))
    }

    /// Startet eine Notfall-Pause (begrenzte Anzahl pro Tag, wird protokolliert).
    public static func startEmergencyPause(policy: ShieldPolicy, ledger: UnlockLedger, now: Date, calendar: Calendar) throws(UnlockActionError) -> UnlockLedger {
        let today = DayKey(now, calendar: calendar)
        guard ledger.emergencyPausesUsed(on: today) < policy.emergencyPausesPerDay else { throw .noEmergencyPausesLeft }
        var copy = ledger
        copy.emergencyPause = UnlockWindow(start: now, end: now.addingTimeInterval(Double(policy.emergencyPauseMinutes * 60)), minutes: policy.emergencyPauseMinutes)
        copy.emergencyPausesUsed[today.description, default: 0] += 1
        return copy
    }

    /// Vollständige Tagesfreigabe nach Erreichen von 100 %. Gilt bis zum Ende des lokalen Kalendertags.
    public static func grantFullMasteryUnlock(ledger: UnlockLedger, now: Date, calendar: Calendar) -> UnlockLedger {
        let today = DayKey(now, calendar: calendar)
        if ledger.hasFullMasteryUnlock(on: today) { return ledger }
        var copy = ledger
        copy.fullMasteryUnlock = DayUnlock(day: today, reason: .fullMastery, grantedAt: now)
        return copy
    }

    /// Tagesziel erreicht: beendet die Tagesziel-Sperre für den Rest des Tages.
    public static func grantDailyGoalUnlock(ledger: UnlockLedger, now: Date, calendar: Calendar) -> UnlockLedger {
        let today = DayKey(now, calendar: calendar)
        if ledger.hasDailyGoalUnlock(on: today) { return ledger }
        var copy = ledger
        copy.dailyGoalUnlock = DayUnlock(day: today, reason: .dailyGoal, grantedAt: now)
        return copy
    }
}

/// Gemeinsamer, per App Group geteilter Zustand.
public struct SharedShieldState: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var policy: ShieldPolicy
    public var ledger: UnlockLedger
    /// Zuletzt tatsächlich angewendeter Zustand (für Diagnose und UI).
    public var lastApplied: AppliedShieldRecord?

    public init(policy: ShieldPolicy = ShieldPolicy(), ledger: UnlockLedger = UnlockLedger(), lastApplied: AppliedShieldRecord? = nil) {
        self.schemaVersion = Self.schemaVersion
        self.policy = policy
        self.ledger = ledger
        self.lastApplied = lastApplied
    }
}

public struct AppliedShieldRecord: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case app, monitorExtension, backgroundRefresh }
    public var shielded: Bool
    public var appliedAt: Date
    public var source: Source
    public var errorDescription: String?

    public init(shielded: Bool, appliedAt: Date, source: Source, errorDescription: String? = nil) {
        self.shielded = shielded
        self.appliedAt = appliedAt
        self.source = source
        self.errorDescription = errorDescription
    }
}
