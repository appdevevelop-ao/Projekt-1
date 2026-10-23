import ManagedSettings
import UserNotifications

/// Reagiert auf die Tasten des Sperrbildschirms. Apps können von hier nicht direkt geöffnet werden;
/// deshalb erscheint eine Mitteilung, über die LernFokus mit einem Tippen geöffnet wird.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(to: action, completionHandler: completionHandler)
    }

    private func respond(to action: ShieldAction, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            let content = UNMutableNotificationContent()
            content.title = "Weiterlernen"
            content.body = "Tippe hier, um LernFokus zu öffnen und Bildschirmzeit zu verdienen."
            content.categoryIdentifier = SharedConfig.notificationCategoryOpenApp
            let request = UNNotificationRequest(identifier: "lf.shield.open", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in
                completionHandler(.close)
            }
        case .secondaryButtonPressed:
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }
}
