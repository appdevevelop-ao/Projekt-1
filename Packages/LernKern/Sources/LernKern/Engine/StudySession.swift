import Foundation

/// Persistenter Zustand einer laufenden Lern- oder Prüfungssitzung.
/// Wird nach jeder Antwort gespeichert, damit ein Neustart keine Daten verliert.
public struct StudySessionState: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        /// Lernmaterial lesen (bei "Verstehen"-Einheiten).
        case learning
        /// Fragen beantworten.
        case questions
        /// Ergebnis anzeigen.
        case summary
    }

    public enum Mode: String, Codable, Sendable {
        case practice
        case simulation
    }

    public var id: UUID
    public var examID: UUID
    public var taskID: UUID?
    public var kind: StudyTaskKind
    public var mode: Mode
    public var objectiveIDs: [UUID]
    public var phase: Phase
    public var questionIDs: [UUID]
    public var currentIndex: Int
    public var attemptIDs: [UUID]
    public var startedAt: Date
    /// Tatsächlich aktive Zeit (nur im Vordergrund gezählt).
    public var activeSeconds: Double
    public var lastResumedAt: Date?
    public var timeLimitMinutes: Int?
    public var breakUntil: Date?
    public var completedCheckID: UUID?
    /// Aktuelle Frage beantwortet, Rückmeldung wird gerade angezeigt.
    public var currentAnswered: Bool?

    public init(id: UUID = UUID(), examID: UUID, taskID: UUID?, kind: StudyTaskKind, mode: Mode, objectiveIDs: [UUID],
                phase: Phase, questionIDs: [UUID], startedAt: Date, timeLimitMinutes: Int? = nil) {
        self.id = id
        self.examID = examID
        self.taskID = taskID
        self.kind = kind
        self.mode = mode
        self.objectiveIDs = objectiveIDs
        self.phase = phase
        self.questionIDs = questionIDs
        self.currentIndex = 0
        self.attemptIDs = []
        self.startedAt = startedAt
        self.activeSeconds = 0
        self.lastResumedAt = startedAt
        self.timeLimitMinutes = timeLimitMinutes
    }

    public var currentQuestionID: UUID? { questionIDs.indices.contains(currentIndex) ? questionIDs[currentIndex] : nil }
    public var isFinishedAnswering: Bool { currentIndex >= questionIDs.count }

    public mutating func pause(at now: Date) {
        if let resumed = lastResumedAt { activeSeconds += max(0, min(now.timeIntervalSince(resumed), 3 * 3600)) }
        lastResumedAt = nil
    }

    public mutating func resume(at now: Date) {
        if lastResumedAt == nil { lastResumedAt = now }
    }

    public func activeSeconds(at now: Date) -> Double {
        activeSeconds + (lastResumedAt.map { max(0, min(now.timeIntervalSince($0), 3 * 3600)) } ?? 0)
    }

    /// Verbleibende Zeit einer Simulation (Wanduhrzeit – wie in einer echten Prüfung).
    public func remainingSeconds(at now: Date) -> Double? {
        guard let limit = timeLimitMinutes else { return nil }
        return max(0, Double(limit * 60) - now.timeIntervalSince(startedAt))
    }

    /// Empfohlene Pause nach längerer konzentrierter Arbeit.
    public func suggestsBreak(at now: Date, sessionMinutes: Int) -> Bool {
        mode == .practice && activeSeconds(at: now) >= Double(max(sessionMinutes, 20) * 60) && breakUntil == nil
    }

    /// Speichert die Antwort. Ohne `advance` bleibt die Frage für die Rückmeldung stehen.
    public mutating func recordAnswer(attemptID: UUID, advance: Bool = true) {
        attemptIDs.append(attemptID)
        if advance { self.advance() } else { currentAnswered = true }
    }

    public mutating func advance() {
        currentIndex += 1
        currentAnswered = nil
    }
}
