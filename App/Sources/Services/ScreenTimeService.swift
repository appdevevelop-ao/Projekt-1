import FamilyControls
import Foundation
import LernKern
import Observation

/// Bildschirmzeit-Steuerung der App: Berechtigung, Auswahl, Regeln, Freigaben.
/// Die eigentliche Sperrentscheidung trifft `ShieldDecisionEngine`; angewendet wird sie über `ShieldController`.
@MainActor
@Observable
final class ScreenTimeService {
    private(set) var authorizationStatus: AuthorizationStatus
    private(set) var selection: FamilyActivitySelection
    private(set) var shared: SharedShieldState
    private(set) var decision: ShieldDecision?
    /// Tatsächlicher Zustand im System (Kontrolle gegen widersprüchliche Anzeigen).
    private(set) var systemShieldActive = false
    private(set) var monitoringProblems: [String] = []
    var lastError: String?

    init() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        selection = SharedShieldStore.loadSelection()
        shared = SharedShieldStore.loadState()
        SharedShieldStore.isAuthorized = authorizationStatus == .approved
    }

    var policy: ShieldPolicy { shared.policy }
    var ledger: UnlockLedger { shared.ledger }
    var isAuthorized: Bool { authorizationStatus == .approved }
    var calendar: Calendar { ShieldController.calendar }

    /// UI und System stimmen überein (sonst wird ein Problem angezeigt statt einer falschen Freigabe).
    var isConsistent: Bool { decision.map { $0.shouldShield == systemShieldActive } ?? true }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        refreshAuthorization()
        reconcile()
    }

    func refreshAuthorization() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        SharedShieldStore.isAuthorized = authorizationStatus == .approved
    }

    func updateSelection(_ newSelection: FamilyActivitySelection) {
        selection = newSelection
        SharedShieldStore.saveSelection(newSelection)
        reconcile()
    }

    func updatePolicy(_ change: (inout ShieldPolicy) -> Void) {
        var state = SharedShieldStore.loadState()
        change(&state.policy)
        SharedShieldStore.saveState(state)
        shared = state
        if state.policy.isEnabled {
            monitoringProblems = MonitoringScheduler.update()
        } else {
            MonitoringScheduler.stopAll()
            monitoringProblems = []
        }
        reconcile()
    }

    func redemptionCheck(now: Date = Date()) -> ShieldDecisionEngine.RedemptionCheck {
        ShieldDecisionEngine.canRedeemReward(policy: shared.policy, ledger: shared.ledger, environment: environment, now: now, calendar: calendar)
    }

    /// Schaltet die Sperre für `minutes` Minuten frei (Abbuchung vom Konto übernimmt das AppModel).
    func redeem(minutes: Int, now: Date = Date()) throws {
        var state = SharedShieldStore.loadState()
        state.ledger = try UnlockActions.redeemReward(minutes: minutes, policy: state.policy, ledger: state.ledger, environment: environment, now: now, calendar: calendar)
        SharedShieldStore.saveState(state)
        shared = state
        monitoringProblems = MonitoringScheduler.update(now: now)
        reconcile(now: now)
    }

    /// Beendet die eingelöste Zeit vorzeitig; gibt ungenutzte Minuten zurück.
    func endRewardEarly(now: Date = Date()) -> Int {
        var state = SharedShieldStore.loadState()
        let result = UnlockActions.endRewardEarly(ledger: state.ledger, now: now)
        state.ledger = result.ledger
        SharedShieldStore.saveState(state)
        shared = state
        monitoringProblems = MonitoringScheduler.update(now: now)
        reconcile(now: now)
        return result.unusedMinutes
    }

    func startEmergencyPause(now: Date = Date()) throws {
        var state = SharedShieldStore.loadState()
        state.ledger = try UnlockActions.startEmergencyPause(policy: state.policy, ledger: state.ledger, now: now, calendar: calendar)
        SharedShieldStore.saveState(state)
        shared = state
        monitoringProblems = MonitoringScheduler.update(now: now)
        reconcile(now: now)
    }

    func emergencyPausesLeft(now: Date = Date()) -> Int {
        max(0, shared.policy.emergencyPausesPerDay - shared.ledger.emergencyPausesUsed(on: DayKey(now, calendar: calendar)))
    }

    /// Fachliche Erfolge (Tagesziel, 100 %) in Freigaben übersetzen. Idempotent.
    func syncAchievements(dailyGoalReached: Bool, fullMastery: Bool, display: ShieldDisplayInfo, now: Date = Date()) {
        var state = SharedShieldStore.loadState()
        let before = state.ledger
        if dailyGoalReached { state.ledger = UnlockActions.grantDailyGoalUnlock(ledger: state.ledger, now: now, calendar: calendar) }
        if fullMastery { state.ledger = UnlockActions.grantFullMasteryUnlock(ledger: state.ledger, now: now, calendar: calendar) }
        if state.ledger != before { SharedShieldStore.saveState(state) }
        if SharedShieldStore.shieldDisplay != display { SharedShieldStore.shieldDisplay = display }
        shared = state
        reconcile(now: now)
    }

    func reconcile(now: Date = Date()) {
        refreshAuthorization()
        decision = ShieldController.reconcile(now: now, source: .app)
        shared = SharedShieldStore.loadState()
        systemShieldActive = ShieldController.isShieldActiveInSystem
    }

    /// Für „Alle Daten löschen“: Sperre aufheben, Zeitpläne beenden, Auswahl, Regeln und Freigaben entfernen.
    func resetAll() {
        MonitoringScheduler.stopAll()
        monitoringProblems = []
        selection = FamilyActivitySelection()
        SharedShieldStore.saveSelection(selection)
        SharedShieldStore.saveState(SharedShieldState())
        SharedShieldStore.shieldDisplay = ShieldDisplayInfo()
        reconcile()
    }

    /// Stellt die Zeitpläne nach einem Neustart oder Update sicher.
    func ensureMonitoring() {
        guard shared.policy.isEnabled else { return }
        monitoringProblems = MonitoringScheduler.update()
    }

    private var environment: ShieldEnvironment {
        ShieldEnvironment(isAuthorized: isAuthorized, hasSelection: !selection.isEmptySelection)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? FamilyControlsError {
            switch e {
            case .authorizationCanceled:
                return "Die Freigabe wurde abgebrochen. Ohne sie kann LernFokus keine Apps sperren."
            case .restricted:
                return "Bildschirmzeit ist auf diesem Gerät eingeschränkt (z. B. durch eine Geräteverwaltung oder Bildschirmzeit-Code der Eltern)."
            case .unavailable:
                return "Bildschirmzeit ist auf diesem Gerät nicht verfügbar. Bitte in den Einstellungen aktivieren."
            case .networkError:
                return "Für die Freigabe wird eine Internetverbindung benötigt."
            default:
                return "Bildschirmzeit-Freigabe nicht möglich (\(e.localizedDescription))."
            }
        }
        return error.localizedDescription
    }
}

extension LockStatus {
    /// Verständliche Statuszeile für die Oberfläche.
    var title: String {
        switch self {
        case .disabled: return "App-Sperre ausgeschaltet"
        case .notConfigured: return "Noch keine Apps ausgewählt"
        case .permissionMissing: return "Bildschirmzeit-Berechtigung fehlt"
        case .fullDayUnlock: return "Tagesfreigabe aktiv – 100 % erreicht"
        case .emergencyPause: return "Notfall-Pause aktiv"
        case .rewardWindow: return "Belohnung läuft"
        case .dailyGoalReached: return "Tagesziel erreicht – Apps frei"
        case .outsideLockTimes: return "Gerade keine Sperre"
        case .locked(let cause, _):
            if cause.contains(.studyWindow) && cause.contains(.dailyGoal) { return "Sperre aktiv – Lernzeit, bis dein Tagesziel erreicht ist" }
            if cause.contains(.studyWindow) { return "Sperre aktiv – Lernzeit läuft" }
            return "Sperre aktiv – bis zum Tagesziel"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled, .notConfigured: return "lock.open"
        case .permissionMissing: return "exclamationmark.triangle"
        case .fullDayUnlock, .dailyGoalReached: return "checkmark.seal"
        case .emergencyPause: return "cross.case"
        case .rewardWindow: return "gift"
        case .outsideLockTimes: return "lock.open"
        case .locked: return "lock"
        }
    }

    func detail(formatter: DateFormatter) -> String? {
        switch self {
        case .fullDayUnlock: return "Deine gesperrten Apps bleiben bis Mitternacht frei."
        case .emergencyPause(let until): return "Bis \(formatter.string(from: until))"
        case .rewardWindow(let until): return "Apps frei bis \(formatter.string(from: until))"
        case .outsideLockTimes(let next): return next.map { "Nächste Sperre: \(formatter.string(from: $0))" }
        case .locked(_, let until): return until.map { "Bis \(formatter.string(from: $0))" }
        case .permissionMissing: return "Ohne Berechtigung ist keine Sperre aktiv."
        default: return nil
        }
    }
}
