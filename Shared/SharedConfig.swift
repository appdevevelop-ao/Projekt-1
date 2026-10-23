import Foundation

/// Gemeinsame Konfiguration für App und Erweiterungen (App Group).
enum SharedConfig {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "group.com.example.lernfokus"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// Name des ManagedSettings-Speichers, über den ausschließlich diese App sperrt.
    static let managedSettingsStoreName = "lernfokus"

    static let notificationCategoryOpenApp = "lf.openApp"
}
