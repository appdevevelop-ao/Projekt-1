import LernKern
import SwiftUI

/// Lernplan: alle geplanten Einheiten nach Tagen, Änderungen mit Begründung, Kalender.
struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTask: StudyTask?
    @State private var movingTask: StudyTask?
    @State private var showPast = false
    @State private var icsURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if let change = model.state.planLog.last, !change.reasons.isEmpty {
                    Section("Letzte Anpassung") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Formatters.relativeDay(change.date) + ", " + Formatters.time.string(from: change.date)).font(.caption).foregroundStyle(.secondary)
                            ForEach(change.reasons, id: \.self) { Text("• \($0)").font(.subheadline) }
                        }
                    }
                }
                if !model.calendarConflicts.isEmpty {
                    Section("Kalender – bitte entscheiden") {
                        ForEach(model.calendarConflicts) { conflict in
                            ConflictRow(conflict: conflict)
                        }
                    }
                }
                ForEach(days, id: \.self) { day in
                    Section(header: Text(dayTitle(day))) {
                        dayRows(day)
                    }
                }
                if days.isEmpty {
                    ContentUnavailableView("Noch kein Lernplan", systemImage: "calendar.badge.plus",
                                           description: Text("Lege eine Prüfung an und lade Unterlagen hoch – dann entsteht dein Plan automatisch."))
                }
                examsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Lernplan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Plan neu berechnen", systemImage: "arrow.clockwise") { model.replan(trigger: .routine) }
                        Toggle("Vergangene Einheiten zeigen", isOn: $showPast)
                        Divider()
                        if model.isCalendarSyncEnabled {
                            Button("Kalender jetzt abgleichen", systemImage: "calendar.badge.checkmark") { model.syncCalendar(announce: true) }
                        } else {
                            Button("Alle in Apple Kalender übernehmen", systemImage: "calendar.badge.plus") {
                                Task { await model.enableCalendarSync(calendarIdentifier: nil) }
                            }
                        }
                        Button("Als Kalenderdatei (.ics) exportieren", systemImage: "square.and.arrow.up") { icsURL = model.exportICS() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Weitere Aktionen")
                }
            }
            .sheet(item: $selectedTask) { task in TaskDetailSheet(task: task).presentationDetents([.medium, .large]) }
            .sheet(item: $movingTask) { task in MoveTaskSheet(task: task).presentationDetents([.medium]) }
            .sheet(isPresented: Binding(get: { icsURL != nil }, set: { if !$0 { icsURL = nil } })) {
                if let icsURL { ICSShareSheet(url: icsURL) }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let relative = Formatters.relativeDay(day)
        let short = Formatters.dayShort.string(from: day)
        return relative == short ? Formatters.dayLong.string(from: day) : relative + " · " + short
    }

    private var visibleTasks: [StudyTask] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return model.state.tasks.filter { showPast || $0.start >= startOfToday }.sorted { $0.start < $1.start }
    }

    private var days: [Date] {
        Array(Set(visibleTasks.map { Calendar.current.startOfDay(for: $0.start) })).sorted()
    }

    @ViewBuilder
    private func dayRows(_ day: Date) -> some View {
        let tasks = visibleTasks.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            if index > 0 {
                let gap = Int(task.start.timeIntervalSince(tasks[index - 1].end) / 60)
                if gap >= 5 && gap <= 30 {
                    Label("Pause · \(gap) Min.", systemImage: "cup.and.saucer").font(.caption).foregroundStyle(.secondary)
                }
            }
            TaskRow(task: task)
                .contentShape(Rectangle())
                .onTapGesture { selectedTask = task }
                .swipeActions(edge: .trailing) {
                    if task.isOpen {
                        Button("Verschieben") { movingTask = task }.tint(.accentColor)
                        Button("Überspringen") { model.skipTask(task.id) }.tint(.gray)
                    }
                }
                .swipeActions(edge: .leading) {
                    if task.isOpen {
                        Button("Kalender") { Task { await model.addToCalendar(task.id) } }.tint(.blue)
                    }
                }
        }
    }

    @ViewBuilder
    private var examsSection: some View {
        let warnings = model.snapshot.exams.filter { $0.time.feasibility != .comfortable }
        if !warnings.isEmpty {
            Section("Hinweise") {
                ForEach(warnings) { exam in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exam.exam.title).font(.subheadline.weight(.semibold))
                        Text(exam.time.headline).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: StudyTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.time.string(from: task.start)).font(.subheadline.monospacedDigit())
                Text("\(task.durationMinutes) Min.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 56, alignment: .trailing)
            Image(systemName: task.kind.symbolName).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body).strikethrough(task.status == .skipped)
                HStack(spacing: 6) {
                    Text(model.state.exam(task.examID)?.title ?? "").font(.caption).foregroundStyle(.secondary)
                    if task.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Von dir festgelegt") }
                    if model.state.calendarLinks.contains(where: { $0.taskID == task.id }) {
                        Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Im Kalender")
                    }
                }
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityLabel("Erledigt")
        case .missed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel("Verpasst")
        case .inProgress: Image(systemName: "play.circle").foregroundStyle(.tint).accessibilityLabel("Läuft")
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary).accessibilityLabel("Übersprungen")
        case .planned: EmptyView()
        }
    }
}

/// Details einer Einheit – inkl. "Warum diese Einheit?" (transparenter Lerncoach).
struct TaskDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: StudyTask
    @State private var moving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Zeit", value: "\(Formatters.relativeDay(task.start)), \(Formatters.time.string(from: task.start))–\(Formatters.time.string(from: task.end))")
                    LabeledContent("Art", value: task.kind.title)
                    if let exam = model.state.exam(task.examID) { LabeledContent("Prüfung", value: exam.title) }
                }
                Section("Warum diese Einheit?") {
                    Text(task.reason.isEmpty ? "Teil deines Lernplans." : task.reason)
                }
                if !task.detail.isEmpty {
                    Section("Aufgabe") { Text(task.detail) }
                }
                let objectives = model.state.objectives.filter { task.objectiveIDs.contains($0.id) }
                if !objectives.isEmpty {
                    Section("Lernziele") {
                        ForEach(objectives) { o in
                            HStack {
                                Text(o.title)
                                Spacer()
                                LevelBadge(level: model.snapshot.knowledge[o.id]?.level ?? .notStarted)
                            }
                        }
                    }
                }
                if task.isOpen {
                    Section {
                        Button("Jetzt starten") {
                            dismiss()
                            Task { await model.startSession(for: task) }
                        }
                        Button("Verschieben") { moving = true }
                        Button("Zum Kalender hinzufügen") { Task { await model.addToCalendar(task.id) } }
                        Button("Überspringen", role: .destructive) {
                            model.skipTask(task.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $moving) { MoveTaskSheet(task: task).presentationDetents([.medium]) }
        }
    }
}

struct MoveTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: StudyTask
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Neue Zeit", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Text("Die Einheit wird an diese Zeit angeheftet. Der restliche Plan passt sich an, ohne sie zu verändern.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Verschieben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        model.moveTask(task.id, to: date)
                        dismiss()
                    }
                }
            }
            .onAppear { date = max(task.start, Date()) }
        }
    }
}

struct ConflictRow: View {
    @Environment(AppModel.self) private var model
    let conflict: CalendarConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conflict.taskTitle).font(.subheadline.weight(.semibold))
            switch conflict.kind {
            case .deletedInCalendar:
                Text("Du hast diesen Termin im Kalender gelöscht.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Nicht wieder eintragen") { model.resolveConflict(conflict, keepCalendar: true) }
                    Spacer()
                    Button("Wieder eintragen") { model.resolveConflict(conflict, keepCalendar: false) }
                }
                .font(.footnote)
            case .changedOnBothSides:
                Text("Im Kalender: \(conflict.calendarStart.map { Formatters.relativeDay($0) + " " + Formatters.time.string(from: $0) } ?? "–") · Im Plan: \(Formatters.relativeDay(conflict.planStart)) \(Formatters.time.string(from: conflict.planStart))")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Kalenderzeit übernehmen") { model.resolveConflict(conflict, keepCalendar: true) }
                    Spacer()
                    Button("Planzeit behalten") { model.resolveConflict(conflict, keepCalendar: false) }
                }
                .font(.footnote)
            }
        }
        .buttonStyle(.borderless)
    }
}

struct ICSShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "calendar.badge.plus").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Kalenderdatei erstellt").font(.title2.weight(.semibold))
                Text("Öffne die Datei mit der Kalender-App oder teile sie. Termine haben feste Kennungen, sodass ein erneuter Import sie aktualisiert.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("Teilen oder öffnen", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
