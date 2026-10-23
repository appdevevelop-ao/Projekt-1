import Foundation

public struct DailyGoalStatus: Hashable, Sendable {
    public var record: DailyGoalRecord
    public var credits: Double
    public var isReached: Bool
    public var progress: Double
    public var text: String
}

/// Das Tagesziel: bestandene Wissensüberprüfungen gemäß heutigem Lernplan.
///
/// - Es wird beim ersten Aufruf des Tages festgelegt und danach nicht mehr verschoben.
/// - Lernfreie Tage haben kein Tagesziel.
/// - Ernsthaft bearbeitete, aber noch nicht bestandene Überprüfungen zählen halb –
///   wer sich schwertut, bleibt nicht den ganzen Tag gesperrt.
/// - Ist das Ziel zuverlässig erreicht (Phase "Wissen erhalten"), genügt eine kurze Wiederholung.
public enum DailyGoalPlanner {
    public static let maximumChecks = 6

    public static func makeGoal(day: DayKey, tasksToday: [StudyTask], isStudyDay: Bool, hasActiveExam: Bool, phase: RewardPhase, dueReviews: Int) -> DailyGoalRecord {
        guard hasActiveExam else {
            return DailyGoalRecord(day: day, requiredChecks: 0, plannedMinutes: 0, explanation: "Keine aktive Prüfung – heute gibt es kein Tagesziel.")
        }
        guard isStudyDay else {
            return DailyGoalRecord(day: day, requiredChecks: 0, plannedMinutes: 0, explanation: "Heute ist ein lernfreier Tag.")
        }
        let relevant = tasksToday.filter { $0.status != .skipped }
        let planned = relevant.reduce(0) { $0 + $1.durationMinutes }
        if phase == .maintenance {
            return DailyGoalRecord(day: day, requiredChecks: 1, plannedMinutes: min(planned, 20),
                                   explanation: "Du bist auf Zielkurs. Heute genügt eine kurze Wiederholung, um das Wissen frisch zu halten.")
        }
        let checks = min(maximumChecks, max(1, relevant.count))
        let reviewText = dueReviews > 0 ? " inklusive fälliger Wiederholungen" : ""
        return DailyGoalRecord(day: day, requiredChecks: checks, plannedMinutes: planned,
                               explanation: "Schließe \(checks == 1 ? "eine Lerneinheit" : "\(checks) Lerneinheiten") mit Wissensüberprüfung ab\(reviewText).")
    }

    public static func status(record: DailyGoalRecord, checks: [CompletedCheck], simulations: [ExamSimulationResult], calendar: Calendar) -> DailyGoalStatus {
        let todayChecks = checks.filter { DayKey($0.completedAt, calendar: calendar) == record.day }
        let todaySims = simulations.filter { DayKey($0.finishedAt, calendar: calendar) == record.day && $0.answeredShare >= 0.8 }
        let credits = todayChecks.sum { $0.dailyGoalCredit } + Double(todaySims.count) * 2
        let required = Double(record.requiredChecks)
        let reached = required == 0 || credits >= required
        let progress = required == 0 ? 1 : min(1, credits / required)
        let text: String
        if required == 0 { text = record.explanation }
        else if reached { text = "Tagesziel erreicht. Gut gemacht!" }
        else {
            let remaining = Int((required - credits).rounded(.up))
            text = "Noch \(remaining) \(remaining == 1 ? "Lerneinheit" : "Lerneinheiten") mit Überprüfung bis zum Tagesziel."
        }
        return DailyGoalStatus(record: record, credits: credits, isReached: reached, progress: progress, text: text)
    }
}
