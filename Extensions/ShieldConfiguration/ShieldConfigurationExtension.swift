import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Gestaltet den Sperrbildschirm: ruhig, erklärend, ohne Schuldgefühle.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    private func makeConfiguration(name: String?) -> ShieldConfiguration {
        let info = SharedShieldStore.shieldDisplay
        let accent = UIColor(red: 0.18, green: 0.48, blue: 0.54, alpha: 1)
        var subtitle = info.subtitle
        if info.balanceMinutes > 0 {
            subtitle += "\nVerdient: \(info.balanceMinutes) Min. – in LernFokus einlösbar."
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: nil,
            icon: UIImage(systemName: "checkmark.circle"),
            title: ShieldConfiguration.Label(text: name.map { "\($0) ist gerade pausiert" } ?? "Gerade pausiert", color: .label),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Zu LernFokus", color: .white),
            primaryButtonBackgroundColor: accent,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Schließen", color: accent)
        )
    }
}
