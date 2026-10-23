import Foundation
import LernKern

extension AppModel {
    private var excludedFromCalendar: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: "lf.calendarExcluded") ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "lf.calendarExcluded") }
    }

    /// nil = alle zukünftigen Einheiten; sonst nur ausgewählte Einheiten.
    var calendarSelection: Set<UUID>? {
        get { UserDefaults.standard.stringArray(forKey: "lf.calendarSelection").map { Set($0.compactMap(UUID.init)) } }
        set { UserDefaults.standard.set(newValue.map { $0.map(\.uuidString) }, forKey: "lf.calendarSelection") }
    }

    var isCalendarSyncEnabled: Bool { state.settings.calendarIdentifier != nil }

    func tasksForCalendar(now: Date = Date()) -> [StudyTask] {
        let horizon = now.addingTimeInterval(60 * 86_400)
        let excluded = excludedFromCalendar
        return state.tasks.filter { task in
            task.isOpen && task.end > now && task.start < horizon && !excluded.contains(task.id)
                && (calendarSelection.map { $0.contains(task.id) } ?? true)
        }
    }

    /// Kalender-Synchronisierung einschalten (fragt nur den nötigen Zugriff an).
    func enableCalendarSync(calendarIdentifier: String?, onlySelected: Set<UUID>? = nil) async {
        if !calendarService.hasFullAccess {
            let granted = await calendarService.requestAccess()
            guard granted else {
                banner = Banner(kind: .info, title: "Kein Kalenderzugriff", message: "Du kannst den Lernplan stattdessen als Kalenderdatei (.ics) exportieren oder den Zugriff später in den Einstellungen erlauben.")
                return
            }
        }
        guard let id = calendarIdentifier ?? calendarService.defaultCalendarIdentifier() else {
            banner = Banner(kind: .warning, title: "Kein Kalender gefunden", message: "Bitte lege in der Kalender-App einen Kalender an.")
            return
        }
        calendarSelection = onlySelected
        updateSettings { $0.calendarIdentifier = id }
        syncCalendar(announce: true)
    }

    /// Einzelne Einheit in den Kalender übernehmen.
    func addToCalendar(_ taskID: UUID) async {
        var selection = calendarSelection ?? Set(tasksForCalendar().map(\.id))
        selection.insert(taskID)
        if isCalendarSyncEnabled {
            if calendarSelection != nil { calendarSelection = selection }
            syncCalendar(announce: true)
        } else {
            await enableCalendarSync(calendarIdentifier: nil, onlySelected: [taskID])
        }
    }

    func syncCalendar(announce: Bool) {
        guard let id = state.settings.calendarIdentifier else { return }
        calendarService.refreshStatus()
        guard calendarService.hasFullAccess else {
            if announce { banner = Banner(kind: .warning, title: "Kein Kalenderzugriff", message: calendarService.statusText) }
            return
        }
        let outcome = calendarService.sync(state: state, tasks: tasksForCalendar(), calendarIdentifier: id, alarmMinutes: state.settings.calendarAlarmMinutes)
        mutate { state in
            state.calendarLinks = outcome.links
            // Im Kalender verschobene Termine respektieren: neue Zeit in den Plan übernehmen und anheften.
            for move in outcome.adoptedMoves {
                if let i = state.tasks.firstIndex(where: { $0.id == move.taskID }) {
                    state.tasks[i].start = move.start
                    state.tasks[i].durationMinutes = max(5, Int(move.end.timeIntervalSince(move.start) / 60))
                    state.tasks[i].isPinned = true
                }
            }
        }
        calendarConflicts = outcome.conflicts
        if !outcome.adoptedMoves.isEmpty {
            // Restplan um die verschobenen Einheiten herum neu ordnen
            var result: PlanResult?
            mutate { state in result = coach.replan(&state, triggers: [.taskMovedByUser], now: Date()) }
            _ = result
        }
        if announce || !outcome.adoptedMoves.isEmpty || !outcome.conflicts.isEmpty || !outcome.errors.isEmpty {
            let kind: Banner.Kind = outcome.errors.isEmpty ? (outcome.conflicts.isEmpty ? .success : .info) : .warning
            var message = outcome.summary
            if !outcome.conflicts.isEmpty { message += " Bitte prüfe die Hinweise unter Lernplan." }
            if let error = outcome.errors.first { message += " \(error)" }
            banner = Banner(kind: kind, title: "Kalender", message: message)
        }
    }

    func autoSyncCalendar() {
        guard isCalendarSyncEnabled, calendarService.hasFullAccess else { return }
        syncCalendar(announce: false)
    }

    func resolveConflict(_ conflict: CalendarConflict, keepCalendar: Bool) {
        calendarConflicts.removeAll { $0.id == conflict.id }
        guard let calendarID = state.settings.calendarIdentifier else { return }
        switch (conflict.kind, keepCalendar) {
        case (.deletedInCalendar, true):
            // Nicht wieder anlegen – der Nutzer hat den Termin bewusst gelöscht.
            excludedFromCalendar.insert(conflict.taskID)
            mutate { $0.calendarLinks.removeAll { $0.taskID == conflict.taskID } }
        case (.changedOnBothSides, true):
            if let start = conflict.calendarStart, let task = state.tasks.first(where: { $0.id == conflict.taskID }) {
                mutate { state in
                    coach.moveTask(&state, taskID: task.id, to: start)
                    if let i = state.calendarLinks.firstIndex(where: { $0.taskID == task.id }) {
                        state.calendarLinks[i].syncedStart = start
                        state.calendarLinks[i].syncedEnd = start.addingTimeInterval(Double(task.durationMinutes * 60))
                    }
                }
                replan(trigger: .taskMovedByUser, announce: false)
            }
        case (_, false):
            guard let task = state.tasks.first(where: { $0.id == conflict.taskID }) else { return }
            let link = state.calendarLinks.first { $0.taskID == task.id }
            if let newLink = calendarService.restorePlanTime(task: task, link: link, state: state, calendarIdentifier: calendarID, alarmMinutes: state.settings.calendarAlarmMinutes) {
                mutate { state in
                    state.calendarLinks.removeAll { $0.taskID == task.id }
                    state.calendarLinks.append(newLink)
                }
            }
        }
    }

    func disableCalendarSync(removeEvents: Bool) {
        var removed = 0
        if removeEvents { removed = calendarService.removeAllManagedEvents(links: state.calendarLinks) }
        calendarSelection = nil
        mutate { state in
            state.settings.calendarIdentifier = nil
            state.calendarLinks = []
        }
        banner = Banner(kind: .info, title: "Kalender-Abgleich aus", message: removeEvents ? "\(removed) zukünftige Lerntermine wurden entfernt." : "Bestehende Termine bleiben im Kalender.")
    }

    /// Lernplan als .ics-Datei (ohne Kalenderberechtigung nutzbar).
    func exportICS() -> URL? {
        let tasks = state.tasks.filter { $0.isOpen && $0.end > Date() }.sorted { $0.start < $1.start }
        guard !tasks.isEmpty else { return nil }
        let contents = tasks.map { (taskID: $0.id, content: CalendarService.content(for: $0, state: state, alarmMinutes: state.settings.calendarAlarmMinutes)) }
        let text = ICSExporter.export(contents, now: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LernFokus-Lernplan.ics")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
