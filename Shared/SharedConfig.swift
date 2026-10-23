import Foundation

/// Gemeinsame Konfiguration für App und Erweiterungen (App Group).
enum SharedConfig {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "group.com.example.lernfokus"
    }
}
