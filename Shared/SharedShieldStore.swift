import Foundation
import FamilyControls
import ShieldLogic

/// Liest und schreibt den mit den Erweiterungen geteilten Sperrzustand (App Group).
enum SharedShieldStore {
    private static let stateKey = "lf.shieldState.v1"
    private static let selectionKey = "lf.selection.v1"
    private static let authorizedKey = "lf.authorized"
    private static let displayKey = "lf.shieldDisplay.v1"

    static func loadState() -> SharedShieldState {
        guard let data = SharedConfig.defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(SharedShieldState.self, from: data) else {
            return SharedShieldState()
        }
        return state
    }

    static func saveState(_ state: SharedShieldState) {
        if let data = try? JSONEncoder().encode(state) {
            SharedConfig.defaults.set(data, forKey: stateKey)
        }
    }

    static func loadSelection() -> FamilyActivitySelection {
        guard let data = SharedConfig.defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    static func saveSelection(_ selection: FamilyActivitySelection) {
        if let data = try? JSONEncoder().encode(selection) {
            SharedConfig.defaults.set(data, forKey: selectionKey)
        }
    }

    /// Von der App gesetzt, da die Erweiterungen den Berechtigungsstatus nicht selbst abfragen.
    static var isAuthorized: Bool {
        get { SharedConfig.defaults.bool(forKey: authorizedKey) }
        set { SharedConfig.defaults.set(newValue, forKey: authorizedKey) }
    }

    /// Kurztexte für den Sperrbildschirm (z. B. verbleibendes Tagesziel).
    static var shieldDisplay: ShieldDisplayInfo {
        get {
            guard let data = SharedConfig.defaults.data(forKey: displayKey),
                  let info = try? JSONDecoder().decode(ShieldDisplayInfo.self, from: data) else { return ShieldDisplayInfo() }
            return info
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { SharedConfig.defaults.set(data, forKey: displayKey) }
        }
    }
}

struct ShieldDisplayInfo: Codable, Equatable {
    var subtitle: String = "Diese App ist während deiner Lernzeit gesperrt. Mit Lernen verdienst du Bildschirmzeit."
    var balanceMinutes: Int = 0
}

extension FamilyActivitySelection {
    var isEmptySelection: Bool {
        applicationTokens.isEmpty && categoryTokens.isEmpty && webDomainTokens.isEmpty
    }

    var selectionSummary: String {
        var parts: [String] = []
        if !applicationTokens.isEmpty { parts.append("\(applicationTokens.count) App\(applicationTokens.count == 1 ? "" : "s")") }
        if !categoryTokens.isEmpty { parts.append("\(categoryTokens.count) Kategorie\(categoryTokens.count == 1 ? "" : "n")") }
        if !webDomainTokens.isEmpty { parts.append("\(webDomainTokens.count) Website\(webDomainTokens.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nichts ausgewählt" : parts.joined(separator: ", ")
    }
}
