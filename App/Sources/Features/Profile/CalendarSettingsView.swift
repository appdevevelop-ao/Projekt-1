import EventKit
import LernKern
import SwiftUI

/// Apple-Kalender: Zielkalender, Erinnerungen, Abgleich, Export – auch ohne Berechtigung nutzbar (.ics).
struct CalendarSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var icsURL: URL?
    @State private var confirmDisable = false

    var body: some View {
        let service = model.calendarService
        Form {
            Section {
                LabeledContent("Kalenderzugriff", value: service.statusText)
                if !service.hasFullAccess {
                    Button("Zugriff erlauben") { Task { _ = await service.requestAccess() } }
                }
            } footer: {
                Text("LernFokus benötigt vollen Zugriff, um nur die eigenen Lerntermine wiederzufinden, Duplikate zu vermeiden und zu erkennen, wenn du einen Termin verschiebst. Andere Termine werden nie verändert.")
            }
            if service.hasFullAccess {
                Section("Zielkalender") {
                    Picker("Kalender", selection: Binding(
                        get: { model.state.settings.calendarIdentifier ?? "" },
                        set: { id in Task { await model.enableCalendarSync(calendarIdentifier: id.isEmpty ? nil : id) } }
                    )) {
                        Text("Kein Abgleich").tag("")
                        ForEach(service.writableCalendars(), id: \.calendarIdentifier) { calendar in
                            Text(calendar.title).tag(calendar.calendarIdentifier)
                        }
                    }
                    Picker("Erinnerung", selection: Binding(
                        get: { model.state.settings.calendarAlarmMinutes ?? 0 },
                        set: { value in
                            model.updateSettings { $0.calendarAlarmMinutes = value == 0 ? nil : value }
                            model.autoSyncCalendar()
                        }
                    )) {
                        Text("Keine").tag(0)
                        Text("5 Min. vorher").tag(5)
                        Text("10 Min. vorher").tag(10)
                        Text("30 Min. vorher").tag(30)
                    }
                }
                if model.isCalendarSyncEnabled {
                    Section {
                        LabeledContent("Verknüpfte Termine", value: "\(model.state.calendarLinks.count)")
                        LabeledContent("Umfang", value: model.calendarSelection == nil ? "Ganzer Plan (60 Tage)" : "\(model.calendarSelection?.count ?? 0) ausgewählte Einheiten")
                        if model.calendarSelection != nil {
                            Button("Ganzen Plan übernehmen") {
                                model.calendarSelection = nil
                                model.syncCalendar(announce: true)
                            }
                        }
                        Button("Jetzt abgleichen") { model.syncCalendar(announce: true) }
                        Button("Abgleich beenden …", role: .destructive) { confirmDisable = true }
                    } footer: {
                        Text("Änderungen am Lernplan werden automatisch übertragen. Verschiebst du einen Termin im Kalender, übernimmt LernFokus die neue Zeit; bei Widersprüchen wirst du gefragt.")
                    }
                }
            }
            Section {
                Button("Lernplan als .ics exportieren", systemImage: "square.and.arrow.up") { icsURL = model.exportICS() }
            } footer: {
                Text("Funktioniert ohne Kalenderberechtigung. Die Datei kannst du in jede Kalender-App importieren.")
            }
        }
        .navigationTitle("Apple Kalender")
        .onAppear { service.refreshStatus() }
        .confirmationDialog("Kalender-Abgleich beenden?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Zukünftige Lerntermine entfernen", role: .destructive) { model.disableCalendarSync(removeEvents: true) }
            Button("Termine im Kalender behalten") { model.disableCalendarSync(removeEvents: false) }
        }
        .sheet(isPresented: Binding(get: { icsURL != nil }, set: { if !$0 { icsURL = nil } })) {
            if let icsURL { ICSShareSheet(url: icsURL) }
        }
    }
}
