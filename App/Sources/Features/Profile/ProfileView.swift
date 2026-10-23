import LernKern
import SwiftUI

/// Profil: Einstellungen, Kalender, Bildschirmzeit, Berechtigungen, Datenschutz.
struct ProfileView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Wie dürfen wir dich nennen? (optional)", text: Binding(
                        get: { model.state.settings.displayName },
                        set: { value in model.updateSettings { $0.displayName = value } }
                    ))
                }
                Section("Lernen") {
                    NavigationLink { StudyTimesView() } label: { Label("Lernzeiten", systemImage: "clock") }
                    NavigationLink { RewardRulesView() } label: { Label("Belohnungsregeln", systemImage: "gift") }
                }
                Section("Bildschirmzeit") {
                    NavigationLink { ScreenTimeSettingsView() } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("App-Sperre")
                                Text(model.screenTime.decision?.status.title ?? "Nicht eingerichtet").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "hourglass") }
                    }
                }
                Section("Kalender und Erinnerungen") {
                    NavigationLink { CalendarSettingsView() } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Apple Kalender")
                                Text(model.isCalendarSyncEnabled ? (model.calendarService.calendarTitle(model.state.settings.calendarIdentifier) ?? "Aktiv") : "Aus").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "calendar") }
                    }
                    Picker(selection: Binding(
                        get: { model.state.settings.notificationLevel },
                        set: { level in
                            model.updateSettings { $0.notificationLevel = level }
                            if level != .off { Task { _ = await model.notifications.requestAuthorization() } }
                        }
                    )) {
                        ForEach(NotificationLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Label("Erinnerungen", systemImage: "bell")
                    }
                }
                Section("KI und Daten") {
                    NavigationLink { AISettingsView() } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("KI-Dienst")
                                Text(model.state.settings.isAIUsable ? "Aktiv" : "Nur lokale Analyse").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "sparkles") }
                    }
                    NavigationLink { PrivacyView() } label: { Label("Datenschutz und Daten löschen", systemImage: "hand.raised") }
                }
                Section("Hilfe") {
                    NavigationLink { HelpView() } label: { Label("So funktioniert LernFokus", systemImage: "questionmark.circle") }
                }
            }
            .navigationTitle("Profil")
        }
    }
}

/// Lernzeiten je Wochentag und Gestaltung der Einheiten.
struct StudyTimesView: View {
    @Environment(AppModel.self) private var model
    @State private var prefs = StudyPreferences()
    @State private var loaded = false
    @State private var newBlockedDay = Date()
    private let weekdays = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
    private let order = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        Form {
            Section {
                ForEach(order, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("\(weekdays[index]): \(prefs.minutesPerWeekday[index] == 0 ? "frei" : Formatters.minutes(prefs.minutesPerWeekday[index]))",
                                value: $prefs.minutesPerWeekday[index], in: 0...480, step: 15)
                        if prefs.minutesPerWeekday[index] > 0 {
                            DatePicker("Beginn", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                                .font(.subheadline)
                        }
                    }
                }
            } header: {
                Text("Verfügbare Lernzeit")
            } footer: {
                Text("Pro Woche: \(Formatters.minutes(prefs.weeklyMinutes)). Etwa \(Int(prefs.bufferShare * 100)) % bleiben als Puffer frei.")
            }
            Section("Lerneinheiten") {
                Stepper("Länge: \(prefs.sessionMinutes) Min.", value: $prefs.sessionMinutes, in: 10...60, step: 5)
                Stepper("Kurze Pause: \(prefs.shortBreakMinutes) Min.", value: $prefs.shortBreakMinutes, in: 0...20)
                Stepper("Lange Pause: \(prefs.longBreakMinutes) Min.", value: $prefs.longBreakMinutes, in: 0...45, step: 5)
                DatePicker("Spätestens bis", selection: latestEndBinding, displayedComponents: .hourAndMinute)
            }
            Section {
                ForEach(prefs.blockedDays.sorted(), id: \.self) { day in
                    Text(day.startDate(calendar: .current).map { Formatters.dayLong.string(from: $0) } ?? day.description)
                }
                .onDelete { offsets in
                    let sorted = prefs.blockedDays.sorted()
                    let remove = offsets.map { sorted[$0] }
                    prefs.blockedDays.removeAll { remove.contains($0) }
                }
                HStack {
                    DatePicker("Lernfreier Tag", selection: $newBlockedDay, in: Date()..., displayedComponents: .date)
                    Button("Hinzufügen") {
                        let key = DayKey(newBlockedDay, calendar: .current)
                        if !prefs.blockedDays.contains(key) { prefs.blockedDays.append(key) }
                    }
                }
            } header: {
                Text("Tage ohne Lernen")
            } footer: {
                Text("An diesen Tagen plant LernFokus nichts ein und es gibt kein Tagesziel.")
            }
            Section {
                Button("Übernehmen und Plan anpassen") { model.updatePreferences(prefs) }
            }
        }
        .navigationTitle("Lernzeiten")
        .onAppear {
            if !loaded { prefs = model.state.preferences; loaded = true }
        }
    }

    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: prefs.startMinutePerWeekday[index] / 60, minute: prefs.startMinutePerWeekday[index] % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                prefs.startMinutePerWeekday[index] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var latestEndBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: min(prefs.latestEndMinute, 23 * 60 + 59) / 60, minute: min(prefs.latestEndMinute, 23 * 60 + 59) % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                prefs.latestEndMinute = max(60, (c.hour ?? 22) * 60 + (c.minute ?? 0))
            }
        )
    }
}

struct RewardRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var policy = RewardPolicy.standard
    @State private var loaded = false
    @State private var showExplanation = false

    var body: some View {
        Form {
            Section {
                Stepper("Grundbelohnung: \(policy.baseMinutesPerCheck) Min.", value: $policy.baseMinutesPerCheck, in: 1...15)
                Stepper("Höchstens je Überprüfung: \(policy.maxMinutesPerCheck) Min.", value: $policy.maxMinutesPerCheck, in: policy.baseMinutesPerCheck...30)
                Stepper("Mindestens \(policy.minQuestionsPerCheck) Antworten", value: $policy.minQuestionsPerCheck, in: 3...10)
            } header: {
                Text("Wissensüberprüfung")
            }
            Section("Simulation") {
                Stepper("Grundbelohnung: \(policy.simulationBaseMinutes) Min.", value: $policy.simulationBaseMinutes, in: 0...30)
                Stepper("Höchstens: \(policy.simulationMaxMinutes) Min.", value: $policy.simulationMaxMinutes, in: policy.simulationBaseMinutes...60)
            }
            Section {
                Stepper("Pro Tag höchstens \(policy.dailyEarnCap) Min.", value: $policy.dailyEarnCap, in: 30...360, step: 10)
                Stepper("Kontostand höchstens \(policy.maxBalance) Min.", value: $policy.maxBalance, in: 30...600, step: 10)
            } header: {
                Text("Grenzen")
            } footer: {
                Text("Schutz gegen Missbrauch ist fest eingebaut: Durchklicken, wiederholte Fragen und Trivialfragen zählen nicht.")
            }
            Section {
                Button("Sichern") { model.updateRewardPolicy(policy) }
                Button("Standard wiederherstellen") { policy = .standard }
                Button("Wie wird das berechnet?") { showExplanation = true }
            }
        }
        .navigationTitle("Belohnungsregeln")
        .onAppear { if !loaded { policy = model.state.rewardPolicy; loaded = true } }
        .sheet(isPresented: $showExplanation) { CalculationExplanationSheet(topic: .rewards) }
    }
}
