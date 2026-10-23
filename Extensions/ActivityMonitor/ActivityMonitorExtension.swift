import DeviceActivity
import Foundation
import ManagedSettings
import ShieldLogic
import UserNotifications

/// Wird vom System zu Beginn/Ende der registrierten Zeitpläne geweckt (auch wenn die App geschlossen ist)
/// und wendet die Sperrentscheidung an. Hält keine eigene Logik – alles stammt aus ShieldLogic.
final class ActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        evaluate(activity, isEnd: false)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        evaluate(activity, isEnd: true)
        if MonitoringPlan.kind(ofActivityNamed: activity.rawValue) == .rewardWindow {
            notify(title: "Belohnung beendet", body: "Deine eingelöste Bildschirmzeit ist abgelaufen. Weiter geht's mit der nächsten Lerneinheit.")
        }
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        if MonitoringPlan.kind(ofActivityNamed: activity.rawValue) == .rewardWindow {
            notify(title: "Noch 1 Minute", body: "Deine eingelöste Bildschirmzeit endet gleich.")
        }
    }

    private func evaluate(_ activity: DeviceActivityName, isEnd: Bool) {
        let now = Date()
        let ledger = SharedShieldStore.loadState().ledger
        let at = MonitoringPlan.evaluationDate(activityName: activity.rawValue, isEnd: isEnd, now: now, ledger: ledger, calendar: ShieldController.calendar)
        ShieldController.reconcile(now: now, evaluationDate: at, source: .monitorExtension)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "lf.reward.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
