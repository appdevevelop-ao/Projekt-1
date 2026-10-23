import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import ShieldLogic

/// Setzt Sperrentscheidungen tatsächlich im System um.
///
/// Wird von App und DeviceActivityMonitor-Erweiterung gleichermaßen verwendet. Die Entscheidung
/// stammt immer aus `ShieldDecisionEngine` (eine Quelle der Wahrheit); hier wird sie nur angewendet
/// und das Ergebnis zur Kontrolle protokolliert.
enum ShieldController {
    static var store: ManagedSettingsStore { ManagedSettingsStore(named: ManagedSettingsStore.Name(SharedConfig.managedSettingsStoreName)) }

    static var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = TimeZone.current
        return c
    }

    /// Wertet den gespeicherten Zustand aus und wendet die Sperre an.
    @discardableResult
    static func reconcile(now: Date = Date(), evaluationDate: Date? = nil, source: AppliedShieldRecord.Source) -> ShieldDecision {
        var state = SharedShieldStore.loadState()
        state.ledger = state.ledger.pruned(now: now, calendar: calendar)
        let selection = SharedShieldStore.loadSelection()
        let environment = ShieldEnvironment(isAuthorized: SharedShieldStore.isAuthorized, hasSelection: !selection.isEmptySelection)
        let decision = ShieldDecisionEngine.decide(policy: state.policy, ledger: state.ledger, environment: environment,
                                                   now: evaluationDate ?? now, calendar: calendar)
        apply(shouldShield: decision.shouldShield, selection: selection)
        state.lastApplied = AppliedShieldRecord(shielded: decision.shouldShield, appliedAt: now, source: source)
        SharedShieldStore.saveState(state)
        return decision
    }

    static func apply(shouldShield: Bool, selection: FamilyActivitySelection) {
        let store = store
        guard shouldShield, !selection.isEmptySelection else {
            store.clearAllSettings()
            return
        }
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    /// Ob im System gerade tatsächlich eine Sperre dieser App gesetzt ist (Abgleich mit der UI).
    static var isShieldActiveInSystem: Bool {
        let shield = store.shield
        return shield.applications != nil || shield.applicationCategories != nil || shield.webDomains != nil || shield.webDomainCategories != nil
    }
}

/// Registriert die nötigen DeviceActivity-Zeitpläne (nur aus der App aufgerufen).
enum MonitoringScheduler {
    @discardableResult
    static func update(now: Date = Date()) -> [String] {
        let state = SharedShieldStore.loadState()
        let planned = MonitoringPlan.activities(policy: state.policy, ledger: state.ledger, now: now, calendar: ShieldController.calendar)
        let center = DeviceActivityCenter()
        var problems: [String] = []
        let wanted = Set(planned.map(\.name))
        let obsolete = center.activities.filter { $0.rawValue.hasPrefix(MonitoringPlan.prefix) && !wanted.contains($0.rawValue) }
        if !obsolete.isEmpty { center.stopMonitoring(obsolete) }
        for activity in planned {
            let schedule = DeviceActivitySchedule(
                intervalStart: activity.start,
                intervalEnd: activity.end,
                repeats: activity.repeats,
                warningTime: activity.warningMinutes.map { DateComponents(minute: $0) }
            )
            do {
                let name = DeviceActivityName(rawValue: activity.name)
                // Neu starten, damit geänderte Zeiten übernommen werden.
                if center.activities.contains(name) && activity.kind != .daily { center.stopMonitoring([name]) }
                if !center.activities.contains(name) { try center.startMonitoring(name, during: schedule) }
            } catch {
                problems.append("\(activity.name): \(error.localizedDescription)")
            }
        }
        return problems
    }

    static func stopAll() {
        let center = DeviceActivityCenter()
        let ours = center.activities.filter { $0.rawValue.hasPrefix(MonitoringPlan.prefix) }
        if !ours.isEmpty { center.stopMonitoring(ours) }
    }
}
