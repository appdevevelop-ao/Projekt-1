import Foundation

public enum LearningMethod: String, Codable, CaseIterable, Sendable {
    case activeRecall
    case spacedRepetition
    case interleaving
    case practiceTests
    case explainInOwnWords

    public var title: String {
        switch self {
        case .activeRecall: return "Aktives Abrufen"
        case .spacedRepetition: return "Verteiltes Wiederholen"
        case .interleaving: return "Gemischte Übungen"
        case .practiceTests: return "Probeprüfungen"
        case .explainInOwnWords: return "In eigenen Worten erklären"
        }
    }
}

/// Lernzeiten und Sitzungsgestaltung.
public struct StudyPreferences: Codable, Hashable, Sendable {
    /// Verfügbare Lernminuten je Wochentag (Index 0 = Sonntag … 6 = Samstag, wie `Calendar.weekday - 1`).
    public var minutesPerWeekday: [Int]
    /// Bevorzugte Startzeit je Wochentag (Minuten seit Mitternacht).
    public var startMinutePerWeekday: [Int]
    public var sessionMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    public var blocksBeforeLongBreak: Int
    /// Spätestes Ende einer Lerneinheit (Minuten seit Mitternacht).
    public var latestEndMinute: Int
    /// Tage, an denen nicht gelernt werden kann.
    public var blockedDays: [DayKey]
    /// Anteil der Kapazität, der als Puffer frei bleibt.
    public var bufferShare: Double
    public var preferredMethods: [LearningMethod]

    public init(
        minutesPerWeekday: [Int] = [60, 60, 60, 60, 60, 60, 60],
        startMinutePerWeekday: [Int] = [10 * 60, 16 * 60, 16 * 60, 16 * 60, 16 * 60, 16 * 60, 10 * 60],
        sessionMinutes: Int = 25,
        shortBreakMinutes: Int = 5,
        longBreakMinutes: Int = 15,
        blocksBeforeLongBreak: Int = 3,
        latestEndMinute: Int = 22 * 60,
        blockedDays: [DayKey] = [],
        bufferShare: Double = 0.1,
        preferredMethods: [LearningMethod] = LearningMethod.allCases
    ) {
        self.minutesPerWeekday = Self.normalize(minutesPerWeekday, fallback: 60)
        self.startMinutePerWeekday = Self.normalize(startMinutePerWeekday, fallback: 16 * 60)
        self.sessionMinutes = min(max(sessionMinutes, 10), 90)
        self.shortBreakMinutes = min(max(shortBreakMinutes, 0), 30)
        self.longBreakMinutes = min(max(longBreakMinutes, 0), 60)
        self.blocksBeforeLongBreak = max(blocksBeforeLongBreak, 1)
        self.latestEndMinute = min(max(latestEndMinute, 60), 24 * 60)
        self.blockedDays = blockedDays
        self.bufferShare = min(max(bufferShare, 0), 0.5)
        self.preferredMethods = preferredMethods
    }

    private static func normalize(_ values: [Int], fallback: Int) -> [Int] {
        var v = Array(values.prefix(7))
        while v.count < 7 { v.append(fallback) }
        return v.map { max(0, $0) }
    }

    public func minutes(on date: Date, calendar: Calendar) -> Int {
        if blockedDays.contains(DayKey(date, calendar: calendar)) { return 0 }
        return minutesPerWeekday[calendar.component(.weekday, from: date) - 1]
    }

    public func startMinute(on date: Date, calendar: Calendar) -> Int {
        startMinutePerWeekday[calendar.component(.weekday, from: date) - 1]
    }

    public var weeklyMinutes: Int { minutesPerWeekday.reduce(0, +) }
}

public enum NotificationLevel: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case normal

    public var title: String {
        switch self {
        case .off: return "Aus"
        case .minimal: return "Nur das Wichtigste"
        case .normal: return "Normal"
        }
    }
}

public enum AIMode: String, Codable, CaseIterable, Sendable {
    /// Nur lokale Verarbeitung (Begriffe/Definitionen aus dem Material).
    case off
    /// Eigener Server (KI-Schlüssel liegt ausschließlich dort).
    case server

    public var title: String {
        switch self {
        case .off: return "Nur auf dem Gerät"
        case .server: return "KI-Dienst (Server)"
        }
    }
}

public enum AgeGroup: String, Codable, CaseIterable, Sendable {
    case unspecified
    case under16
    case age16to17
    case adult

    public var title: String {
        switch self {
        case .unspecified: return "Keine Angabe"
        case .under16: return "Unter 16"
        case .age16to17: return "16–17"
        case .adult: return "18 oder älter"
        }
    }

    /// Unter 16 Jahren ist für die Übermittlung an einen KI-Dienst die Zustimmung der Erziehungsberechtigten nötig (DSGVO Art. 8, AT: 14 Jahre).
    public var requiresGuardianConsentForAI: Bool { self == .under16 }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var onboardingCompleted: Bool
    public var notificationLevel: NotificationLevel
    public var calendarIdentifier: String?
    public var calendarAlarmMinutes: Int?
    public var aiMode: AIMode
    public var backendURL: String?
    public var aiConsentGivenAt: Date?
    public var guardianConsentConfirmed: Bool
    public var ageGroup: AgeGroup
    public var displayName: String

    public init(
        onboardingCompleted: Bool = false,
        notificationLevel: NotificationLevel = .minimal,
        calendarIdentifier: String? = nil,
        calendarAlarmMinutes: Int? = 10,
        aiMode: AIMode = .off,
        backendURL: String? = nil,
        aiConsentGivenAt: Date? = nil,
        guardianConsentConfirmed: Bool = false,
        ageGroup: AgeGroup = .unspecified,
        displayName: String = ""
    ) {
        self.onboardingCompleted = onboardingCompleted
        self.notificationLevel = notificationLevel
        self.calendarIdentifier = calendarIdentifier
        self.calendarAlarmMinutes = calendarAlarmMinutes
        self.aiMode = aiMode
        self.backendURL = backendURL
        self.aiConsentGivenAt = aiConsentGivenAt
        self.guardianConsentConfirmed = guardianConsentConfirmed
        self.ageGroup = ageGroup
        self.displayName = displayName
    }

    /// KI darf nur genutzt werden, wenn eingeschaltet, eingewilligt und (bei unter 16) bestätigt.
    public var isAIUsable: Bool {
        aiMode == .server && aiConsentGivenAt != nil && (backendURL?.isEmpty == false)
            && (!ageGroup.requiresGuardianConsentForAI || guardianConsentConfirmed)
    }
}
