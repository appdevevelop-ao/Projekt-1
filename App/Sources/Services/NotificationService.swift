import Foundation
import LernKern
import UserNotifications

/// Dezente Erinnerungen: bevorstehende Lerneinheiten, Prüfungstermine. Häufigkeit einstellbar.
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "lf.plan."

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationGranted() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func reschedule(state: AppState, level: NotificationLevel, now: Date = Date(), calendar: Calendar = .current) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        guard level != .off, state.settings.onboardingCompleted, await authorizationGranted() else { return }

        var requests: [UNNotificationRequest] = []
        let horizon = now.addingTimeInterval(3 * 86_400)
        let upcoming = state.tasks.filter { $0.isOpen && $0.start > now.addingTimeInterval(11 * 60) && $0.start < horizon }.sorted { $0.start < $1.start }
        let perDay = level == .minimal ? 1 : 3
        let grouped = Dictionary(grouping: upcoming) { calendar.startOfDay(for: $0.start) }
        for (_, tasks) in grouped {
            for task in tasks.prefix(perDay) {
                let content = UNMutableNotificationContent()
                content.title = "Gleich geht's los"
                content.body = "\(state.exam(task.examID)?.title ?? "Lernen"): \(task.title) (\(task.durationMinutes) Min.)"
                content.sound = .default
                let fire = task.start.addingTimeInterval(-10 * 60)
                requests.append(request(id: "task.\(task.id)", content: content, at: fire, calendar: calendar))
            }
        }
        for exam in state.activeExams(now: now, calendar: calendar) {
            for days in (level == .minimal ? [1] : [7, 1]) {
                guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: exam.examDate)),
                      let fire = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day), fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = days == 1 ? "Morgen ist es so weit" : "Noch eine Woche"
                content.body = days == 1 ? "\(exam.title): Eine kurze Wiederholung genügt heute. Viel Erfolg!" : "\(exam.title) ist in 7 Tagen. Dein Plan wechselt bald in den Prüfungsmodus."
                requests.append(request(id: "exam.\(exam.id).\(days)", content: content, at: fire, calendar: calendar))
            }
        }
        for r in requests.prefix(40) { try? await center.add(r) }
    }

    private func request(id: String, content: UNMutableNotificationContent, at date: Date, calendar: Calendar) -> UNNotificationRequest {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: prefix + id, content: content, trigger: trigger)
    }

    func notifyNow(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: "lf.info.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
