import Foundation

/// Eintrag im Bildschirmzeit-Konto. Positive Minuten = verdient, negative = eingelöst.
public struct RewardLedgerEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case earned
        case redeemed
        case returned
        case capped
    }

    public var id: UUID
    public var date: Date
    public var minutes: Int
    public var kind: Kind
    /// Sorgt dafür, dass dieselbe Leistung nie doppelt belohnt wird (z. B. nach einem Neustart).
    public var sourceID: String?
    public var title: String
    public var breakdown: [String]

    public init(id: UUID = UUID(), date: Date, minutes: Int, kind: Kind, sourceID: String? = nil, title: String, breakdown: [String] = []) {
        self.id = id
        self.date = date
        self.minutes = minutes
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.breakdown = breakdown
    }
}

/// Verbindung einer Lerneinheit mit einem von der App erstellten Kalendertermin.
public struct CalendarLink: Codable, Hashable, Sendable {
    public var taskID: UUID
    public var eventIdentifier: String
    public var calendarIdentifier: String
    public var syncedStart: Date
    public var syncedEnd: Date
    public var syncedTitle: String
    public var syncedNotesFingerprint: String
    public var lastSyncedAt: Date

    public init(taskID: UUID, eventIdentifier: String, calendarIdentifier: String, syncedStart: Date, syncedEnd: Date, syncedTitle: String, syncedNotesFingerprint: String, lastSyncedAt: Date) {
        self.taskID = taskID
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.syncedStart = syncedStart
        self.syncedEnd = syncedEnd
        self.syncedTitle = syncedTitle
        self.syncedNotesFingerprint = syncedNotesFingerprint
        self.lastSyncedAt = lastSyncedAt
    }
}

/// Das Tagesziel wird zu Tagesbeginn festgelegt und während des Tages nicht verschoben.
public struct DailyGoalRecord: Codable, Hashable, Sendable {
    public var day: DayKey
    /// Anzahl bestandener Wissensüberprüfungen, die heute nötig sind.
    public var requiredChecks: Int
    public var plannedMinutes: Int
    public var explanation: String
    public var reachedAt: Date?

    public init(day: DayKey, requiredChecks: Int, plannedMinutes: Int, explanation: String, reachedAt: Date? = nil) {
        self.day = day
        self.requiredChecks = requiredChecks
        self.plannedMinutes = plannedMinutes
        self.explanation = explanation
        self.reachedAt = reachedAt
    }
}

/// Protokoll einer Lernplan-Änderung mit Begründung.
public struct PlanChangeEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var reasons: [String]
    public var added: Int
    public var removed: Int
    public var moved: Int

    public init(id: UUID = UUID(), date: Date, reasons: [String], added: Int, removed: Int, moved: Int) {
        self.id = id
        self.date = date
        self.reasons = reasons
        self.added = added
        self.removed = removed
        self.moved = moved
    }
}

/// Eine abgeschlossene Wissensüberprüfung (Grundlage für Belohnungen und Tagesziel).
public struct CompletedCheck: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var examID: UUID
    public var taskID: UUID?
    public var completedAt: Date
    public var attemptIDs: [UUID]
    public var accuracy: Double
    public var passed: Bool
    public var rewardMinutes: Int
    /// Beitrag zum Tagesziel: 1 = bestanden, 0,5 = ernsthaft bearbeitet, aber noch nicht bestanden.
    public var dailyGoalCredit: Double

    public init(id: UUID = UUID(), examID: UUID, taskID: UUID?, completedAt: Date, attemptIDs: [UUID], accuracy: Double, passed: Bool, rewardMinutes: Int, dailyGoalCredit: Double) {
        self.id = id
        self.examID = examID
        self.taskID = taskID
        self.completedAt = completedAt
        self.attemptIDs = attemptIDs
        self.accuracy = accuracy
        self.passed = passed
        self.rewardMinutes = rewardMinutes
        self.dailyGoalCredit = dailyGoalCredit
    }
}
