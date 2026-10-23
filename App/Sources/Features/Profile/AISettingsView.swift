import LernKern
import UIKit
import SwiftUI

/// KI-Dienst einrichten: eigener Server, Zugangscode, Einwilligung (inkl. Jugendschutz).
struct AISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var loaded = false

    var body: some View {
        let settings = model.state.settings
        Form {
            Section {
                Text("Ohne KI analysiert LernFokus deine Unterlagen auf dem Gerät: Kapitel, Definitionen und Lückentexte. Mit dem KI-Dienst entstehen genauere Lernziele, abwechslungsreiche Fragen (auch Anwendung und Rechnen) sowie Bewertungen offener Antworten.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Picker("Altersgruppe", selection: Binding(get: { settings.ageGroup }, set: { value in model.updateSettings { $0.ageGroup = value } })) {
                    ForEach(AgeGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.ageGroup.requiresGuardianConsentForAI {
                    Toggle("Meine Eltern bzw. Erziehungsberechtigten sind einverstanden", isOn: Binding(
                        get: { settings.guardianConsentConfirmed },
                        set: { value in model.updateSettings { $0.guardianConsentConfirmed = value } }
                    ))
                }
            } header: {
                Text("Alter")
            } footer: {
                Text("Unter 16 Jahren ist für die Übermittlung an einen KI-Dienst die Zustimmung der Erziehungsberechtigten erforderlich.")
            }
            Section {
                TextField("Server-Adresse, z. B. https://lernfokus.example.org", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Zugangscode", text: $token)
                Button("Verbindung testen") { Task { await test() } }.disabled(url.isEmpty || testing)
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("KI-Server")
            } footer: {
                Text("Der Schlüssel für die KI liegt nur auf dem Server, nie in der App. Den Zugangscode erhältst du vom Betreiber des Servers. Er wird im Schlüsselbund gespeichert.")
            }
            Section {
                Toggle("KI-Dienst verwenden", isOn: Binding(
                    get: { settings.aiMode == .server && settings.aiConsentGivenAt != nil },
                    set: { enabled in save(enabled: enabled) }
                ))
                .disabled(url.isEmpty || (settings.ageGroup.requiresGuardianConsentForAI && !settings.guardianConsentConfirmed))
                if settings.aiMode == .server && !settings.isAIUsable {
                    Label("Noch nicht nutzbar – prüfe Adresse, Einwilligung und Altersangabe.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                }
            } header: {
                Text("Einwilligung")
            } footer: {
                Text("Mit dem Einschalten willigst du ein, dass Textausschnitte aus deinen Unterlagen und deine offenen Antworten an deinen KI-Server und von dort an Anthropic (Claude) zur Verarbeitung gesendet werden. Es werden nur die jeweils nötigen Abschnitte übertragen. Du kannst die Einwilligung jederzeit widerrufen.")
            }
        }
        .navigationTitle("KI-Dienst")
        .onAppear {
            if !loaded {
                url = settings.backendURL ?? (Bundle.main.object(forInfoDictionaryKey: "LFDefaultBackendURL") as? String ?? "")
                token = model.ai.accessToken ?? ""
                loaded = true
            }
        }
    }

    private func save(enabled: Bool) {
        model.ai.accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateSettings { s in
            s.backendURL = trimmed.isEmpty ? nil : trimmed
            s.aiMode = enabled ? .server : .off
            s.aiConsentGivenAt = enabled ? Date() : nil
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://localhost") || trimmed.hasPrefix("http://127.0.0.1") else {
            testResult = "Bitte eine https-Adresse verwenden (http nur für lokale Tests)."
            return
        }
        let reachable = await model.ai.checkHealth(baseURL: trimmed)
        if reachable, token.isEmpty, let id = UIDevice.current.identifierForVendor?.uuidString {
            if let issued = try? await model.ai.register(baseURL: trimmed, installationID: id) {
                token = issued
                model.ai.accessToken = issued
                testResult = "Verbunden. Ein Zugangscode für dieses Gerät wurde ausgestellt."
                return
            }
        }
        testResult = reachable ? "Server erreichbar." : "Server nicht erreichbar. Prüfe die Adresse und deine Internetverbindung."
    }
}
