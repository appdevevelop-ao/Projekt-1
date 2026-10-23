import FamilyControls
import LernKern
import SwiftUI

/// Einrichtung der App-Sperre: Berechtigung, Auswahl, Modus, Lernzeiten, Notfall-Pausen, Diagnose.
struct ScreenTimeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()
    @State private var editingWindows = false
    @State private var confirmDisable = false

    var body: some View {
        let screenTime = model.screenTime
        Form {
            Section {
                Text("LernFokus nutzt die Bildschirmzeit-Funktionen von Apple. Du wählst selbst aus, welche Apps, Kategorien und Websites während deiner Lernzeit pausiert werden. LernFokus sieht dabei nicht, welche Apps du nutzt.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("1. Berechtigung") {
                LabeledContent("Status", value: authorizationText(screenTime.authorizationStatus))
                if screenTime.authorizationStatus != .approved {
                    Button("Bildschirmzeit-Zugriff erlauben") { Task { await screenTime.requestAuthorization() } }
                }
                if let error = screenTime.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            Section {
                LabeledContent("Ausgewählt", value: screenTime.selection.selectionSummary)
                Button(screenTime.selection.isEmptySelection ? "Apps und Kategorien auswählen" : "Auswahl ändern") {
                    selection = screenTime.selection
                    showPicker = true
                }
                .disabled(!screenTime.isAuthorized)
            } header: {
                Text("2. Ablenkende Apps")
            } footer: {
                Text("Tipp: Wähle ganze Kategorien wie Soziale Netzwerke, Spiele und Unterhaltung – so sind auch neue Apps abgedeckt. Telefon, Notruf und wichtige Systemfunktionen können nicht gesperrt werden. Wähle keine Apps, die du für Schule, Arbeit, Navigation oder Kommunikation brauchst.")
            }
            Section {
                Picker("Modus", selection: Binding(get: { screenTime.policy.mode }, set: { mode in screenTime.updatePolicy { $0.mode = mode } })) {
                    ForEach(LockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(screenTime.policy.mode.explanation).font(.footnote).foregroundStyle(.secondary)
                if screenTime.policy.usesStudyWindows {
                    Button("Lernzeiten für die Sperre bearbeiten (\(screenTime.policy.studyWindows.count))") { editingWindows = true }
                    if screenTime.policy.studyWindows.isEmpty {
                        Label("Ohne Lernzeiten greift dieser Modus nicht.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                    }
                }
                if screenTime.policy.mode == .dailyGoal {
                    DatePicker("Sperre ab", selection: lockStartBinding, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("3. Wann wird gesperrt?")
            }
            Section {
                Stepper("Notfall-Pausen pro Tag: \(screenTime.policy.emergencyPausesPerDay)", value: Binding(
                    get: { screenTime.policy.emergencyPausesPerDay },
                    set: { value in screenTime.updatePolicy { $0.emergencyPausesPerDay = value } }
                ), in: 0...5)
                Stepper("Dauer: \(screenTime.policy.emergencyPauseMinutes) Min.", value: Binding(
                    get: { screenTime.policy.emergencyPauseMinutes },
                    set: { value in screenTime.updatePolicy { $0.emergencyPauseMinutes = value } }
                ), in: 5...30, step: 5)
            } header: {
                Text("Notfälle")
            } footer: {
                Text("Für dringende Fälle, ohne dass alle Apps dauerhaft freigegeben werden. Notfall-Pausen werden nicht vom Konto abgebucht.")
            }
            Section {
                Toggle("App-Sperre aktiv", isOn: Binding(
                    get: { screenTime.policy.isEnabled },
                    set: { enabled in
                        // Während einer aktiven Sperre bewusst nachfragen (Selbstverpflichtung, kein Verbot).
                        if !enabled && screenTime.decision?.shouldShield == true {
                            confirmDisable = true
                        } else {
                            screenTime.updatePolicy { $0.isEnabled = enabled }
                        }
                    }
                ))
                .disabled(!screenTime.isAuthorized || screenTime.selection.isEmptySelection)
            } footer: {
                Text("Bei 100 % Lernfortschritt sind die gesperrten Apps bis Mitternacht frei. Am nächsten Tag gelten wieder deine Regeln.")
            }
            Section("Aktueller Zustand") {
                if let decision = screenTime.decision {
                    LabeledContent("Status", value: decision.status.title)
                    if let detail = decision.status.detail(formatter: Formatters.time) { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                LabeledContent("Sperre im System", value: screenTime.systemShieldActive ? "gesetzt" : "nicht gesetzt")
                if let applied = screenTime.shared.lastApplied {
                    LabeledContent("Zuletzt angewendet", value: "\(Formatters.time.string(from: applied.appliedAt)) (\(sourceText(applied.source)))")
                }
                if !screenTime.isConsistent {
                    Label("Anzeige und System stimmen nicht überein. Tippe auf „Neu abgleichen“.", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                }
                ForEach(screenTime.monitoringProblems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                }
                Button("Neu abgleichen") {
                    screenTime.ensureMonitoring()
                    model.refresh()
                }
            }
            Section {
                Text("Die Sperre ist eine Selbstverpflichtung: Du kannst die Berechtigung jederzeit in den iOS-Einstellungen entziehen. Systemweite Bildschirmzeit-Regeln (z. B. von Eltern) liegen außerhalb von LernFokus und werden hier nicht verändert.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App-Sperre")
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: showPicker) { _, isShown in
            if !isShown { screenTime.updateSelection(selection) }
        }
        .sheet(isPresented: $editingWindows) { StudyWindowsEditor() }
        .confirmationDialog("Sperre jetzt ausschalten?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Ausschalten", role: .destructive) { screenTime.updatePolicy { $0.isEnabled = false } }
            Button("Sperre behalten", role: .cancel) {}
        } message: {
            Text("Gerade läuft deine Lernzeit. Für kurze dringende Fälle gibt es die Notfall-Pause unter „Heute“.")
        }
        .onAppear { screenTime.reconcile() }
    }

    private var lockStartBinding: Binding<Date> {
        Binding(
            get: {
                let m = model.screenTime.policy.dailyGoalLockStartMinute
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.screenTime.updatePolicy { $0.dailyGoalLockStartMinute = (c.hour ?? 6) * 60 + (c.minute ?? 0) }
            }
        )
    }

    private func authorizationText(_ status: AuthorizationStatus) -> String {
        switch status {
        case .approved: return "Erlaubt"
        case .denied: return "Abgelehnt – in den Einstellungen änderbar"
        case .notDetermined: return "Noch nicht gefragt"
        @unknown default: return "Unbekannt"
        }
    }

    private func sourceText(_ source: AppliedShieldRecord.Source) -> String {
        switch source {
        case .app: return "App"
        case .monitorExtension: return "Hintergrunddienst"
        case .backgroundRefresh: return "Hintergrundaktualisierung"
        }
    }
}

extension LockMode {
    var title: String {
        switch self {
        case .focus: return "Fokusmodus"
        case .strict: return "Strenger Lernmodus"
        case .dailyGoal: return "Tagesziel-Modus"
        case .combined: return "Kombiniert (empfohlen)"
        }
    }

    var explanation: String {
        switch self {
        case .focus: return "Gesperrt während deiner festgelegten Lernzeiten. Verdiente Minuten kannst du jederzeit als Pause einlösen."
        case .strict: return "Gesperrt während deiner Lernzeiten – ohne vorzeitiges Einlösen von Belohnungen. Nur 100 % oder eine Notfall-Pause heben die Sperre auf."
        case .dailyGoal: return "Gesperrt ab der eingestellten Uhrzeit, bis dein Tagesziel erreicht ist. Danach frei für den Rest des Tages."
        case .combined: return "Gesperrt während deiner Lernzeiten, bis das Tagesziel erreicht ist. Danach sind die restlichen Lernzeiten des Tages frei."
        }
    }
}

/// Wiederkehrende Lernzeitfenster für die Sperre (je Wochentag).
struct StudyWindowsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [StudyWindow] = []
    @State private var weekday = 2
    @State private var start = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    private let names = ["", "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(windows.sorted { ($0.weekday == 1 ? 8 : $0.weekday, $0.startMinute) < ($1.weekday == 1 ? 8 : $1.weekday, $1.startMinute) }) { window in
                        Text("\(names[window.weekday]): \(timeText(window.startMinute))–\(timeText(window.endMinute))")
                    }
                    .onDelete { offsets in
                        let sorted = windows.sorted { ($0.weekday == 1 ? 8 : $0.weekday, $0.startMinute) < ($1.weekday == 1 ? 8 : $1.weekday, $1.startMinute) }
                        let remove = Set(offsets.map { sorted[$0].id })
                        windows.removeAll { remove.contains($0.id) }
                    }
                } footer: {
                    Text("Mindestens 15 Minuten je Fenster (Vorgabe von iOS). Höchstens 14 Fenster.")
                }
                Section("Neues Fenster") {
                    Picker("Wochentag", selection: $weekday) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { Text(names[$0]).tag($0) }
                    }
                    DatePicker("Von", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: $end, displayedComponents: .hourAndMinute)
                    Button("Hinzufügen") { add(weekdays: [weekday]) }.disabled(!isValid)
                    Button("Für Montag bis Freitag hinzufügen") { add(weekdays: [2, 3, 4, 5, 6]) }.disabled(!isValid)
                    Button("Aus meinen Lernzeiten übernehmen") { windows = Self.windows(from: model.state.preferences) }
                }
            }
            .navigationTitle("Lernzeiten für die Sperre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let result = Array(windows.prefix(14))
                        model.screenTime.updatePolicy { $0.studyWindows = result }
                        dismiss()
                    }
                }
            }
            .onAppear { windows = model.screenTime.policy.studyWindows }
        }
    }

    private var startMinute: Int { minute(of: start) }
    private var endMinute: Int { minute(of: end) }
    private var isValid: Bool { endMinute - startMinute >= 15 }

    private func minute(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func add(weekdays: [Int]) {
        for day in weekdays {
            let w = StudyWindow(weekday: day, startMinute: startMinute, endMinute: endMinute)
            if !windows.contains(w) { windows.append(w) }
        }
    }

    private func timeText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60 % 24, minute % 60) }

    /// Lernfenster aus den Lernzeiten ableiten (Beginn + geplante Minuten + Pausen-Puffer).
    static func windows(from prefs: StudyPreferences) -> [StudyWindow] {
        (1...7).compactMap { weekday in
            let minutes = prefs.minutesPerWeekday[weekday - 1]
            guard minutes >= 15 else { return nil }
            let start = prefs.startMinutePerWeekday[weekday - 1]
            let end = min(start + Int(Double(minutes) * 1.3), 24 * 60)
            return end - start >= 15 ? StudyWindow(weekday: weekday, startMinute: start, endMinute: end) : nil
        }
    }
}
