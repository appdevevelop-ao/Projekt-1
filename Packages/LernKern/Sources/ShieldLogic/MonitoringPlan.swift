import Foundation

/// Eine von DeviceActivity zu überwachende Aktivität (plattformneutral beschrieben).
public struct MonitoredActivity: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case daily
        case dailyGoalStart
        case studyWindow
        case rewardWindow
        case emergencyPause
    }

    public var name: String
    public var kind: Kind
    public var start: DateComponents
    public var end: DateComponents
    public var repeats: Bool
    /// Warnung vor Ende (in Minuten), z. B. "Belohnung endet in 1 Minute".
    public var warningMinutes: Int?

    public init(name: String, kind: Kind, start: DateComponents, end: DateComponents, repeats: Bool, warningMinutes: Int? = nil) {
        self.name = name
        self.kind = kind
        self.start = start
        self.end = end
        self.repeats = repeats
        self.warningMinutes = warningMinutes
    }
}

/// Berechnet, welche DeviceActivity-Zeitpläne registriert sein müssen.
///
/// Apple verlangt für einen Zeitplan eine Mindestdauer von 15 Minuten und begrenzt die
/// Zahl gleichzeitig überwachter Aktivitäten. Kürzere Freigabefenster werden deshalb mit
/// einem in der Vergangenheit liegenden Beginn registriert – entscheidend ist nur das Ende.
public enum MonitoringPlan {
    public static let minimumScheduleMinutes = 15
    public static let maximumActivities = 20
    public static let prefix = "lf."

    public static func activities(policy: ShieldPolicy, ledger: UnlockLedger, now: Date, calendar: Calendar) -> [MonitoredActivity] {
        guard policy.isEnabled else { return [] }
        var result: [MonitoredActivity] = []

        // Tageswechsel: um Mitternacht neu auswerten.
        result.append(MonitoredActivity(
            name: prefix + "daily",
            kind: .daily,
            start: DateComponents(hour: 0, minute: 0),
            end: DateComponents(hour: 23, minute: 59),
            repeats: true
        ))

        if policy.mode == .dailyGoal, policy.dailyGoalLockStartMinute > 0,
           policy.dailyGoalLockStartMinute <= 23 * 60 + 59 - minimumScheduleMinutes {
            result.append(MonitoredActivity(
                name: prefix + "goalstart",
                kind: .dailyGoalStart,
                start: DateComponents(hour: policy.dailyGoalLockStartMinute / 60, minute: policy.dailyGoalLockStartMinute % 60),
                end: DateComponents(hour: 23, minute: 59),
                repeats: true
            ))
        }

        if policy.usesStudyWindows {
            for window in policy.studyWindows.sorted(by: { ($0.weekday, $0.startMinute) < ($1.weekday, $1.startMinute) })
            where window.durationMinutes >= minimumScheduleMinutes {
                let endMinute = min(window.endMinute, 23 * 60 + 59)
                result.append(MonitoredActivity(
                    name: prefix + "window.\(window.weekday).\(window.startMinute).\(endMinute)",
                    kind: .studyWindow,
                    start: DateComponents(hour: window.startMinute / 60, minute: window.startMinute % 60, weekday: window.weekday),
                    end: DateComponents(hour: endMinute / 60, minute: endMinute % 60, weekday: window.weekday),
                    repeats: true
                ))
            }
        }

        if let reward = ledger.rewardWindow, reward.end > now {
            result.append(oneShot(name: prefix + "reward", kind: .rewardWindow, end: reward.end, now: now, calendar: calendar, warningMinutes: reward.minutes > 2 ? 1 : nil))
        }
        if let pause = ledger.emergencyPause, pause.end > now {
            result.append(oneShot(name: prefix + "pause", kind: .emergencyPause, end: pause.end, now: now, calendar: calendar, warningMinutes: nil))
        }
        return Array(result.prefix(maximumActivities))
    }

    static func oneShot(name: String, kind: MonitoredActivity.Kind, end: Date, now: Date, calendar: Calendar, warningMinutes: Int?) -> MonitoredActivity {
        let earliestStart = end.addingTimeInterval(-Double(minimumScheduleMinutes * 60))
        let start = min(now, earliestStart)
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return MonitoredActivity(
            name: name,
            kind: kind,
            start: calendar.dateComponents(units, from: start),
            end: calendar.dateComponents(units, from: end),
            repeats: false,
            warningMinutes: warningMinutes
        )
    }

    public static func kind(ofActivityNamed name: String) -> MonitoredActivity.Kind? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        if rest == "daily" { return .daily }
        if rest == "goalstart" { return .dailyGoalStart }
        if rest == "reward" { return .rewardWindow }
        if rest == "pause" { return .emergencyPause }
        if rest.hasPrefix("window.") { return .studyWindow }
        return nil
    }

    /// Zeitpunkt, zu dem eine Erweiterung nach einem Rückruf auswerten soll.
    ///
    /// iOS liefert Rückrufe gelegentlich einige Sekunden zu früh. Damit z. B. das Ende eines
    /// Lernfensters nicht als "noch im Fenster" ausgewertet wird, wird mindestens an der
    /// betreffenden Grenze ausgewertet. Das Ende des Tagesintervalls (23:59) wird bewusst
    /// NICHT vorgezogen, damit eine Tagesfreigabe bis Mitternacht erhalten bleibt.
    public static func evaluationDate(activityName: String, isEnd: Bool, now: Date, ledger: UnlockLedger, calendar: Calendar) -> Date {
        guard let kind = kind(ofActivityNamed: activityName) else { return now }
        switch kind {
        case .daily:
            if isEnd { return now }
            // Start kurz vor Mitternacht geliefert → bereits als neuer Tag auswerten.
            if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
               midnight.timeIntervalSince(now) < 120 {
                return midnight.addingTimeInterval(1)
            }
            return now
        case .dailyGoalStart:
            return now
        case .studyWindow:
            let parts = activityName.split(separator: ".")
            guard parts.count == 5, let startMinute = Int(parts[3]), let endMinute = Int(parts[4]) else { return now }
            let boundaryMinute = isEnd ? endMinute : startMinute
            let boundary = ShieldDecisionEngine.date(minute: boundaryMinute, sameDayAs: now, calendar: calendar) ?? now
            // Nur vorziehen, wenn der Rückruf knapp vor der Grenze kam.
            if boundary > now, boundary.timeIntervalSince(now) < 120 { return boundary.addingTimeInterval(1) }
            return now
        case .rewardWindow:
            guard isEnd, let end = ledger.rewardWindow?.end else { return now }
            return max(now, end)
        case .emergencyPause:
            guard isEnd, let end = ledger.emergencyPause?.end else { return now }
            return max(now, end)
        }
    }
}
