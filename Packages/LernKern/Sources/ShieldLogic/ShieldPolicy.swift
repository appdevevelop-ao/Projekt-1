import Foundation

/// Wie die App-Sperre arbeitet.
public enum LockMode: String, Codable, CaseIterable, Sendable {
    /// Ausgewählte Apps sind nur während der festgelegten Lernzeiten gesperrt.
    /// Verdiente Bildschirmzeit kann als Pause eingelöst werden.
    case focus
    /// Wie `focus`, aber während der Lernzeiten kann keine Belohnung eingelöst werden.
    case strict
    /// Die Sperre gilt ab Tagesbeginn, bis das Tagesziel erreicht ist.
    case dailyGoal
    /// Sperre während der Lernzeiten, bis das Tagesziel erreicht ist.
    /// Danach sind die restlichen Lernzeiten des Tages frei. (Standard)
    case combined
}

/// Ein wiederkehrendes Lernzeitfenster an einem Wochentag (1 = Sonntag … 7 = Samstag, wie `Calendar`).
public struct StudyWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(weekday)-\(startMinute)-\(endMinute)" }
    public var weekday: Int
    /// Minuten seit Mitternacht.
    public var startMinute: Int
    public var endMinute: Int

    public init(weekday: Int, startMinute: Int, endMinute: Int) {
        self.weekday = weekday
        self.startMinute = max(0, min(startMinute, 24 * 60 - 1))
        self.endMinute = max(self.startMinute + 1, min(endMinute, 24 * 60))
    }

    public var durationMinutes: Int { endMinute - startMinute }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard calendar.component(.weekday, from: date) == weekday else { return false }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return minute >= startMinute && minute < endMinute
    }
}

/// Vom Nutzer gewählte Sperr-Einstellungen. Wird per App Group mit den Erweiterungen geteilt.
public struct ShieldPolicy: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var mode: LockMode
    public var studyWindows: [StudyWindow]
    /// Ab welcher Uhrzeit (Minuten seit Mitternacht) im Tagesziel-Modus gesperrt wird.
    public var dailyGoalLockStartMinute: Int
    /// Wie oft pro Tag eine Notfall-Pause möglich ist.
    public var emergencyPausesPerDay: Int
    public var emergencyPauseMinutes: Int

    public init(
        isEnabled: Bool = false,
        mode: LockMode = .combined,
        studyWindows: [StudyWindow] = [],
        dailyGoalLockStartMinute: Int = 6 * 60,
        emergencyPausesPerDay: Int = 2,
        emergencyPauseMinutes: Int = 10
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.studyWindows = studyWindows
        self.dailyGoalLockStartMinute = dailyGoalLockStartMinute
        self.emergencyPausesPerDay = emergencyPausesPerDay
        self.emergencyPauseMinutes = emergencyPauseMinutes
    }

    public func activeStudyWindow(at date: Date, calendar: Calendar) -> StudyWindow? {
        studyWindows.first { $0.contains(date, calendar: calendar) }
    }

    public var usesStudyWindows: Bool { mode != .dailyGoal }
    /// Ob das Erreichen des Tagesziels die Sperre beendet.
    public var usesDailyGoal: Bool { mode == .dailyGoal || mode == .combined }
}
