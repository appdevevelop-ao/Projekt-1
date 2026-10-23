import EventKit
import Foundation
import LernKern
import Observation

/// Apple-Kalender-Anbindung (EventKit). Verändert ausschließlich von LernFokus angelegte Termine.
@MainActor
@Observable
final class CalendarService {
    let eventStore = EKEventStore()
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    struct SyncOutcome {
        var links: [CalendarLink]
        /// Vom Nutzer im Kalender verschobene Einheiten (neue Zeiten für den Plan).
        var adoptedMoves: [(taskID: UUID, start: Date, end: Date)]
        var conflicts: [CalendarConflict]
        var summary: String
        var errors: [String]
    }

    var hasFullAccess: Bool {
        if case .fullAccess = status { return true }
        return false
    }

    var statusText: String {
        switch status {
        case .fullAccess: return "Zugriff erteilt"
        case .writeOnly: return "Nur Schreibzugriff – zum Abgleich wird voller Zugriff benötigt"
        case .denied: return "Zugriff verweigert – in den Einstellungen änderbar"
        case .restricted: return "Zugriff eingeschränkt"
        case .notDetermined: return "Noch nicht gefragt"
        default: return "Unbekannt"
        }
    }

    func refreshStatus() {
        status = EKEventStore.authorizationStatus(for: .event)
    }

    /// Voller Zugriff ist nötig, um eigene Termine wiederzufinden, Duplikate zu vermeiden und Verschiebungen zu erkennen.
    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            refreshStatus()
            return granted
        } catch {
            refreshStatus()
            return false
        }
    }

    func writableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter(\.allowsContentModifications).sorted { $0.title < $1.title }
    }

    func defaultCalendarIdentifier() -> String? {
        eventStore.defaultCalendarForNewEvents?.calendarIdentifier
    }

    func calendarTitle(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        return eventStore.calendar(withIdentifier: identifier)?.title
    }

    /// Gleicht die gewählten Einheiten mit dem Kalender ab.
    func sync(state: AppState, tasks: [StudyTask], calendarIdentifier: String, alarmMinutes: Int?, now: Date = Date()) -> SyncOutcome {
        guard hasFullAccess, let targetCalendar = eventStore.calendar(withIdentifier: calendarIdentifier) else {
            return SyncOutcome(links: state.calendarLinks, adoptedMoves: [], conflicts: [], summary: "Kein Kalenderzugriff.", errors: ["Kein Zugriff auf den gewählten Kalender."])
        }
        let content = { (task: StudyTask) in Self.content(for: task, state: state, alarmMinutes: alarmMinutes) }

        // Verknüpfungen wiederherstellen (z. B. nach Neuinstallation) – verhindert Duplikate.
        var links = state.calendarLinks
        if let range = Self.dateRange(tasks) {
            let predicate = eventStore.predicateForEvents(withStart: range.0, end: range.1, calendars: [targetCalendar])
            let existing = eventStore.events(matching: predicate).compactMap { e -> CalendarEventSnapshot? in
                guard let id = e.eventIdentifier else { return nil }
                return CalendarEventSnapshot(identifier: id, start: e.startDate, end: e.endDate, title: e.title ?? "", url: e.url?.absoluteString)
            }
            links += CalendarSyncPlanner.recoverLinks(events: existing, tasks: tasks, calendarIdentifier: calendarIdentifier, existing: links, contentFor: content, now: now)
        }

        var snapshots: [String: CalendarEventSnapshot] = [:]
        for link in links {
            if let e = eventStore.event(withIdentifier: link.eventIdentifier) {
                snapshots[link.eventIdentifier] = CalendarEventSnapshot(identifier: link.eventIdentifier, start: e.startDate, end: e.endDate, title: e.title ?? "", url: e.url?.absoluteString)
            }
        }
        let plan = CalendarSyncPlanner.plan(tasks: tasks, allTasks: state.tasks, links: links, snapshots: snapshots, contentFor: content, now: now)

        var errors: [String] = []
        var adopted: [(UUID, Date, Date)] = []
        var linkByTask = Dictionary(links.map { ($0.taskID, $0) }, uniquingKeysWith: { a, _ in a })
        var pendingCreates: [(UUID, EKEvent, CalendarEventContent)] = []

        for action in plan.actions {
            do {
                switch action {
                case .create(let taskID, let c):
                    let event = EKEvent(eventStore: eventStore)
                    Self.fill(event, with: c, calendar: targetCalendar)
                    try eventStore.save(event, span: .thisEvent, commit: false)
                    pendingCreates.append((taskID, event, c))
                case .update(let taskID, let identifier, let c):
                    guard let event = eventStore.event(withIdentifier: identifier) else { continue }
                    Self.fill(event, with: c, calendar: event.calendar ?? targetCalendar)
                    try eventStore.save(event, span: .thisEvent, commit: false)
                    linkByTask[taskID] = Self.link(taskID: taskID, identifier: identifier, calendarIdentifier: event.calendar?.calendarIdentifier ?? calendarIdentifier, content: c, now: now)
                case .delete(let identifier):
                    if let event = eventStore.event(withIdentifier: identifier) {
                        try eventStore.remove(event, span: .thisEvent, commit: false)
                    }
                case .adoptCalendarTime(let taskID, let identifier, let start, let end):
                    adopted.append((taskID, start, end))
                    if var link = linkByTask[taskID] {
                        link.syncedStart = start
                        link.syncedEnd = end
                        link.eventIdentifier = identifier
                        link.lastSyncedAt = now
                        linkByTask[taskID] = link
                    }
                case .unlink(let taskID):
                    linkByTask[taskID] = nil
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        do {
            try eventStore.commit()
        } catch {
            errors.append("Speichern im Kalender fehlgeschlagen: \(error.localizedDescription)")
            eventStore.reset()
            return SyncOutcome(links: state.calendarLinks, adoptedMoves: [], conflicts: plan.conflicts, summary: "Kalender konnte nicht aktualisiert werden.", errors: errors)
        }
        for (taskID, event, c) in pendingCreates {
            if let identifier = event.eventIdentifier {
                linkByTask[taskID] = Self.link(taskID: taskID, identifier: identifier, calendarIdentifier: calendarIdentifier, content: c, now: now)
            }
        }
        return SyncOutcome(links: Array(linkByTask.values), adoptedMoves: adopted.map { (taskID: $0.0, start: $0.1, end: $0.2) },
                           conflicts: plan.conflicts, summary: plan.summary, errors: errors)
    }

    /// Konflikt lösen: Plan-Zeit in den Kalender schreiben bzw. gelöschten Termin neu anlegen.
    func restorePlanTime(task: StudyTask, link: CalendarLink?, state: AppState, calendarIdentifier: String, alarmMinutes: Int?, now: Date = Date()) -> CalendarLink? {
        let c = Self.content(for: task, state: state, alarmMinutes: alarmMinutes)
        let event: EKEvent
        if let link, let existing = eventStore.event(withIdentifier: link.eventIdentifier) {
            event = existing
        } else {
            event = EKEvent(eventStore: eventStore)
        }
        guard let calendar = event.calendar ?? eventStore.calendar(withIdentifier: calendarIdentifier) else { return nil }
        Self.fill(event, with: c, calendar: calendar)
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            return nil
        }
        guard let identifier = event.eventIdentifier else { return nil }
        return Self.link(taskID: task.id, identifier: identifier, calendarIdentifier: calendar.calendarIdentifier, content: c, now: now)
    }

    /// Entfernt alle von der App angelegten, zukünftigen Termine (z. B. beim Abschalten der Synchronisierung).
    func removeAllManagedEvents(links: [CalendarLink], now: Date = Date()) -> Int {
        var removed = 0
        for link in links where link.syncedStart > now {
            if let event = eventStore.event(withIdentifier: link.eventIdentifier),
               CalendarEventContent.taskID(fromURL: event.url?.absoluteString) == link.taskID {
                if (try? eventStore.remove(event, span: .thisEvent, commit: false)) != nil { removed += 1 }
            }
        }
        try? eventStore.commit()
        return removed
    }

    static func content(for task: StudyTask, state: AppState, alarmMinutes: Int?) -> CalendarEventContent {
        let objectives = state.objectives.filter { task.objectiveIDs.contains($0.id) }
        let topics = state.topics.filter { task.topicIDs.contains($0.id) }
        return CalendarEventContent.make(task: task, exam: state.exam(task.examID), objectives: objectives, topics: topics, alarmMinutes: alarmMinutes)
    }

    static func fill(_ event: EKEvent, with c: CalendarEventContent, calendar: EKCalendar) {
        event.calendar = calendar
        event.title = c.title
        event.notes = c.notes
        event.startDate = c.start
        event.endDate = c.end
        event.url = URL(string: c.url)
        event.alarms = c.alarmMinutesBefore.map { [EKAlarm(relativeOffset: TimeInterval(-60 * $0))] }
    }

    static func link(taskID: UUID, identifier: String, calendarIdentifier: String, content c: CalendarEventContent, now: Date) -> CalendarLink {
        CalendarLink(taskID: taskID, eventIdentifier: identifier, calendarIdentifier: calendarIdentifier, syncedStart: c.start, syncedEnd: c.end,
                     syncedTitle: c.title, syncedNotesFingerprint: c.fingerprint, lastSyncedAt: now)
    }

    static func dateRange(_ tasks: [StudyTask]) -> (Date, Date)? {
        guard let start = tasks.map(\.start).min(), let end = tasks.map(\.end).max() else { return nil }
        return (start.addingTimeInterval(-86_400), end.addingTimeInterval(86_400))
    }
}
