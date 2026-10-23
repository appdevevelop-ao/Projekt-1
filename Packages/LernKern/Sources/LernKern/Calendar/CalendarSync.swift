import Foundation

/// Inhalt eines von der App verwalteten Kalendertermins.
public struct CalendarEventContent: Hashable, Sendable {
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var url: String
    public var alarmMinutesBefore: Int?

    /// Fingerabdruck von Titel und Beschreibung (zur Änderungserkennung).
    public var fingerprint: String { String(StableHash.fnv1a(title + "\u{1F}" + notes), radix: 16) }

    public static let urlPrefix = "lernfokus://task/"

    public static func make(task: StudyTask, exam: Exam?, objectives: [LearningObjective], topics: [Topic], alarmMinutes: Int?) -> CalendarEventContent {
        let examTitle = exam?.title ?? "Lernen"
        var lines: [String] = []
        if !objectives.isEmpty { lines.append("Lernziele: " + objectives.map(\.title).joined(separator: ", ") + ".") }
        if !task.detail.isEmpty { lines.append("Aufgabe: " + task.detail) }
        let checkNote = task.kind == .simulation ? "Lösungen und Auswertung am Ende in LernFokus." : "Anschließend kurze Wissensüberprüfung in LernFokus."
        lines.append("Dauer: \(task.durationMinutes) Minuten. \(checkNote)")
        if !topics.isEmpty { lines.append("Themen: " + topics.map(\.title).joined(separator: ", ")) }
        lines.append("—")
        lines.append("Von LernFokus verwaltet. Verschiebst du diesen Termin, übernimmt die App die neue Zeit in deinen Lernplan.")
        return CalendarEventContent(title: "\(examTitle) – \(task.title)", notes: lines.joined(separator: "\n"), start: task.start, end: task.end,
                                    url: urlPrefix + task.id.uuidString, alarmMinutesBefore: alarmMinutes)
    }

    public static func taskID(fromURL url: String?) -> UUID? {
        guard let url, url.hasPrefix(urlPrefix) else { return nil }
        return UUID(uuidString: String(url.dropFirst(urlPrefix.count)))
    }
}

/// Zustand eines verknüpften Termins, wie er gerade im Kalender steht.
public struct CalendarEventSnapshot: Hashable, Sendable {
    public var identifier: String
    public var start: Date
    public var end: Date
    public var title: String
    public var url: String?

    public init(identifier: String, start: Date, end: Date, title: String, url: String?) {
        self.identifier = identifier
        self.start = start
        self.end = end
        self.title = title
        self.url = url
    }
}

public struct CalendarConflict: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// Termin im Kalender gelöscht, Einheit ist aber noch geplant.
        case deletedInCalendar
        /// Sowohl im Kalender als auch im Plan verändert.
        case changedOnBothSides
    }

    public var id: UUID { taskID }
    public var kind: Kind
    public var taskID: UUID
    public var eventIdentifier: String
    public var taskTitle: String
    public var planStart: Date
    public var calendarStart: Date?
}

public enum CalendarSyncAction: Hashable, Sendable {
    case create(taskID: UUID, content: CalendarEventContent)
    case update(taskID: UUID, eventIdentifier: String, content: CalendarEventContent)
    case delete(eventIdentifier: String)
    /// Nutzer hat den Termin im Kalender verschoben → Zeit in den Plan übernehmen (Einheit wird angeheftet).
    case adoptCalendarTime(taskID: UUID, eventIdentifier: String, start: Date, end: Date)
    /// Verknüpfung lösen, Termin aber behalten (vom Nutzer veränderter, nicht mehr geplanter Termin).
    case unlink(taskID: UUID)
}

public struct CalendarSyncPlan: Hashable, Sendable {
    public var actions: [CalendarSyncAction]
    public var conflicts: [CalendarConflict]

    public var creates: Int { actions.filter { if case .create = $0 { return true }; return false }.count }
    public var updates: Int { actions.filter { if case .update = $0 { return true }; return false }.count }
    public var deletes: Int { actions.filter { if case .delete = $0 { return true }; return false }.count }
    public var adopted: Int { actions.filter { if case .adoptCalendarTime = $0 { return true }; return false }.count }

    public var summary: String {
        var parts: [String] = []
        if creates > 0 { parts.append("\(creates) neu") }
        if updates > 0 { parts.append("\(updates) aktualisiert") }
        if deletes > 0 { parts.append("\(deletes) entfernt") }
        if adopted > 0 { parts.append("\(adopted) von dir verschoben und übernommen") }
        if !conflicts.isEmpty { parts.append("\(conflicts.count) zu klären") }
        return parts.isEmpty ? "Kalender ist aktuell." : parts.joined(separator: ", ")
    }
}

/// Kontrollierte Synchronisierung des Lernplans mit dem Kalender.
///
/// - Nur von der App erstellte (verknüpfte) Termine werden je verändert oder gelöscht.
/// - Erneuter Export erzeugt keine Duplikate (Verknüpfung je Einheit).
/// - Im Kalender verschobene Termine werden respektiert und in den Plan übernommen.
/// - Widersprüche (beidseitig geändert, im Kalender gelöscht) werden dem Nutzer vorgelegt.
public enum CalendarSyncPlanner {
    /// - Parameters:
    ///   - tasks: Einheiten, die im Kalender stehen sollen.
    ///   - allTasks: alle Einheiten (um entfallene von erledigten zu unterscheiden).
    ///   - links: gespeicherte Verknüpfungen.
    ///   - snapshots: aktueller Kalenderzustand je verknüpfter Termin-ID (fehlt = gelöscht).
    public static func plan(
        tasks: [StudyTask],
        allTasks: [StudyTask],
        links: [CalendarLink],
        snapshots: [String: CalendarEventSnapshot],
        contentFor: (StudyTask) -> CalendarEventContent,
        now: Date
    ) -> CalendarSyncPlan {
        var actions: [CalendarSyncAction] = []
        var conflicts: [CalendarConflict] = []
        let linkByTask = Dictionary(links.map { ($0.taskID, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(tasks.map(\.id))

        for task in tasks.sorted(by: { $0.start < $1.start }) {
            let content = contentFor(task)
            guard let link = linkByTask[task.id] else {
                actions.append(.create(taskID: task.id, content: content))
                continue
            }
            guard let event = snapshots[link.eventIdentifier] else {
                conflicts.append(CalendarConflict(kind: .deletedInCalendar, taskID: task.id, eventIdentifier: link.eventIdentifier,
                                                  taskTitle: task.title, planStart: task.start, calendarStart: nil))
                continue
            }
            let userChangedTime = !same(event.start, link.syncedStart) || !same(event.end, link.syncedEnd)
            let planChangedTime = !same(task.start, link.syncedStart) || !same(task.end, link.syncedEnd)
            let planChangedContent = content.fingerprint != link.syncedNotesFingerprint || content.title != link.syncedTitle
            if userChangedTime && planChangedTime {
                if same(event.start, task.start) && same(event.end, task.end) {
                    // Beide Seiten zeigen bereits dieselbe Zeit
                    if planChangedContent { actions.append(.update(taskID: task.id, eventIdentifier: link.eventIdentifier, content: content)) }
                    continue
                }
                conflicts.append(CalendarConflict(kind: .changedOnBothSides, taskID: task.id, eventIdentifier: link.eventIdentifier,
                                                  taskTitle: task.title, planStart: task.start, calendarStart: event.start))
            } else if userChangedTime {
                actions.append(.adoptCalendarTime(taskID: task.id, eventIdentifier: link.eventIdentifier, start: event.start, end: event.end))
            } else if planChangedTime || planChangedContent {
                actions.append(.update(taskID: task.id, eventIdentifier: link.eventIdentifier, content: content))
            }
        }

        // Verknüpfte Termine, deren Einheit nicht mehr synchronisiert werden soll
        let taskByID = Dictionary(allTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for link in links where !wanted.contains(link.taskID) {
            let task = taskByID[link.taskID]
            // Vergangene/erledigte Einheiten bleiben als Verlauf im Kalender stehen.
            if let task, task.status == .completed || task.end <= now { continue }
            guard let event = snapshots[link.eventIdentifier] else {
                actions.append(.unlink(taskID: link.taskID))
                continue
            }
            let userChanged = !same(event.start, link.syncedStart) || !same(event.end, link.syncedEnd) || event.title != link.syncedTitle
            actions.append(userChanged ? .unlink(taskID: link.taskID) : .delete(eventIdentifier: link.eventIdentifier))
            if !userChanged { actions.append(.unlink(taskID: link.taskID)) }
        }
        return CalendarSyncPlan(actions: actions, conflicts: conflicts)
    }

    /// Stellt Verknüpfungen wieder her (z. B. nach Neuinstallation), anhand der Termin-URL.
    public static func recoverLinks(events: [CalendarEventSnapshot], tasks: [StudyTask], calendarIdentifier: String, existing: [CalendarLink], contentFor: (StudyTask) -> CalendarEventContent, now: Date) -> [CalendarLink] {
        let linked = Set(existing.map(\.taskID))
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [CalendarLink] = []
        for event in events {
            guard let id = CalendarEventContent.taskID(fromURL: event.url), !linked.contains(id), let task = taskByID[id] else { continue }
            let content = contentFor(task)
            result.append(CalendarLink(taskID: id, eventIdentifier: event.identifier, calendarIdentifier: calendarIdentifier,
                                       syncedStart: event.start, syncedEnd: event.end, syncedTitle: event.title,
                                       syncedNotesFingerprint: content.fingerprint, lastSyncedAt: now))
        }
        return result
    }

    static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 60 }
}
