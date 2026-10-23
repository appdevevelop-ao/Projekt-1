import LernKern
import SwiftUI

/// Datenschutz: was wo verarbeitet wird, und vollständiges Löschen.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section("Auf deinem Gerät") {
                Text("Prüfungen, Unterlagen (inkl. Texterkennung), Lernplan, Antworten, Fortschritt und Bildschirmzeit-Konto werden lokal gespeichert und durch die iOS-Datenverschlüsselung geschützt. Es gibt kein Konto und kein Tracking.")
            }
            Section("Bildschirmzeit") {
                Text("Die App-Auswahl wird von iOS verschlüsselt verwaltet. LernFokus erfährt nicht, welche Apps du nutzt oder wie lange.")
            }
            Section("Kalender") {
                Text("LernFokus liest nur die eigenen Lerntermine wieder ein und verändert keine anderen Termine.")
            }
            Section("KI-Dienst (nur wenn eingeschaltet)") {
                Text("Es werden nur die Textabschnitte gesendet, die für eine Analyse, Frage oder Bewertung nötig sind. Der Server speichert keine Inhalte und protokolliert nur technische Metadaten.")
                LabeledContent("Status", value: model.state.settings.isAIUsable ? "Eingeschaltet" : "Aus")
            }
            Section {
                Button("Alle Daten löschen", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Löscht Prüfungen, Unterlagen, Fortschritt, Kalendertermine von LernFokus, Zugangscodes, App-Auswahl und Sperreinstellungen und hebt eine aktive Sperre auf. Dies kann nicht rückgängig gemacht werden. Die Bildschirmzeit-Berechtigung selbst entziehst du in den iOS-Einstellungen unter Bildschirmzeit.")
            }
        }
        .navigationTitle("Datenschutz")
        .confirmationDialog("Wirklich alle Daten löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) { model.deleteAllData() }
        }
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("Was bedeutet 100 %?") {
                Text("Jedes Lernziel deiner aktiven Prüfungen ist stabil beherrscht: richtig ohne Hilfe, mit verschiedenen Fragen, nach zeitlichem Abstand wiederholt, auch bei einer schwierigeren Aufgabe – und das Wissen ist aktuell präsent. Sobald eine bestandene Überprüfung das an einem Tag bestätigt, sind deine gesperrten Apps bis Mitternacht frei. Am nächsten Tag gelten wieder die normalen Regeln.")
            }
            Section("Wie verdiene ich Bildschirmzeit?") {
                Text("Mit abgeschlossenen Wissensüberprüfungen am Ende jeder Lerneinheit (5–10 Min.), Prüfungssimulationen (10–25 Min.) und Boni für echten Fortschritt. Öffnen der App oder Durchklicken zählt nicht. Die Minuten löst du unter „Heute“ ein.")
            }
            Section("Was ist das Tagesziel?") {
                Text("Die Lerneinheiten, die heute in deinem Plan stehen – festgelegt zu Tagesbeginn. Je nach Modus endet damit die Sperre für heute. An lernfreien Tagen gibt es kein Tagesziel.")
            }
            Section("Wie entsteht der Lernplan?") {
                Text("Aus deinen Lernzielen, deinem Wissensstand, der verfügbaren Zeit und dem Prüfungstermin. Schwierige und wichtige Themen bekommen mehr Zeit, Wiederholungen folgen in wachsenden Abständen, vor der Prüfung kommen Simulationen. Verpasst du etwas, wird realistisch neu geplant – mit Begründung.")
            }
            Section("Grenzen der App-Sperre") {
                Text("LernFokus sperrt nur Apps, Kategorien und Websites, die du über Apples Bildschirmzeit-Auswahl freigibst. Telefon, Notruf und Systemfunktionen sind nie betroffen. iOS kann Hintergrundaktualisierungen in seltenen Fällen verzögern; beim Öffnen der App wird der Zustand immer abgeglichen.")
            }
        }
        .navigationTitle("So funktioniert LernFokus")
    }
}
