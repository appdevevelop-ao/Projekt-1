import Foundation
import LernKern
import Observation
import SwiftUI

struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, warning }
    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
}

/// Zentrales App-Modell: hält den Zustand, speichert ihn zuverlässig und verbindet Lerncoach,
/// Bildschirmzeit-Steuerung, Kalender, Mitteilungen, KI-Dienst und Dokumentimport.
@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState
    private(set) var snapshot: CoachSnapshot
    var session: StudySessionState?
    var banner: Banner?
    var loadError: String?
    var importProgress: [UUID: ProcessingState] = [:]
    var calendarConflicts: [CalendarConflict] = []
    var isGeneratingQuestions = false
    /// Wissensstufen zu Beginn der laufenden Sitzung (für die Zusammenfassung).
    var levelsAtStart: [UUID: MasteryLevel] = [:]

    let store: FileStore
    let screenTime: ScreenTimeService
    let calendarService: CalendarService
    let notifications = NotificationService()
    let ai = AIService()
    let importer = DocumentImportService()
    var chunkCache: [UUID: [SourceChunk]] = [:]

    var calendar: Calendar { Calendar.current }
    var coach: LearningCoach { LearningCoach(calendar: calendar) }

    init(storeDirectory: URL? = nil) {
        let directory = storeDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LernFokus", isDirectory: true)
        store = FileStore(directory: directory)
        screenTime = ScreenTimeService()
        calendarService = CalendarService()
        var loaded = AppState()
        var error: String?
        do {
            loaded = try store.loadState() ?? AppState()
        } catch {
            error = "Deine gespeicherten Daten konnten nicht gelesen werden. Sie wurden nicht gelöscht. Bitte wende dich an den Support oder setze die App unter Profil zurück."
        }
        state = loaded
        loadError = error
        snapshot = LearningCoach(calendar: .current).snapshot(state: loaded, now: Date())
        session = store.loadSession()
    }

    // MARK: - Zustand ändern

    /// Ändert den Zustand, speichert sofort (atomar) und aktualisiert alle abgeleiteten Werte.
    func mutate(_ change: (inout AppState) -> Void) {
        change(&state)
        persist()
        refresh()
    }

    func persist() {
        do {
            try store.saveState(state)
        } catch {
            banner = Banner(kind: .warning, title: "Speichern fehlgeschlagen", message: "Bitte prüfe den freien Speicherplatz. (\(error.localizedDescription))")
        }
    }

    func persistSession() {
        try? store.saveSession(session)
    }

    /// Berechnet Fortschritt, Prognosen und Tagesziel neu und überträgt Erfolge in die Sperrsteuerung.
    func refresh(now: Date = Date()) {
        if state.settings.onboardingCompleted, state.dailyGoal(for: DayKey(now, calendar: calendar)) == nil {
            coach.ensureDailyGoal(&state, now: now)
            persist()
        }
        snapshot = coach.snapshot(state: state, now: now)
        screenTime.syncAchievements(
            dailyGoalReached: snapshot.dailyGoal?.isReached == true,
            fullMastery: snapshot.fullMastery.isComplete,
            display: shieldDisplay(),
            now: now
        )
    }

    private func shieldDisplay() -> ShieldDisplayInfo {
        var info = ShieldDisplayInfo()
        info.balanceMinutes = state.rewardBalance
        if let goal = snapshot.dailyGoal, !goal.isReached, goal.record.requiredChecks > 0 {
            info.subtitle = goal.text + " Danach sind deine Apps für heute frei."
        }
        return info
    }

    // MARK: - Lebenszyklus

    private var lastRoutineDayKey: String? {
        get { UserDefaults.standard.string(forKey: "lf.lastRoutineDay") }
        set { UserDefaults.standard.set(newValue, forKey: "lf.lastRoutineDay") }
    }

    func onLaunch() {
        screenTime.ensureMonitoring()
        onForeground()
    }

    func onForeground(now: Date = Date()) {
        session?.resume(at: now)
        screenTime.refreshAuthorization()
        calendarService.refreshStatus()
        let today = DayKey(now, calendar: calendar).description
        if state.settings.onboardingCompleted && lastRoutineDayKey != today {
            lastRoutineDayKey = today
            replan(trigger: .routine, announce: true, now: now)
        } else {
            refresh(now: now)
        }
        Task { await notifications.reschedule(state: state, level: state.settings.notificationLevel) }
    }

    func onBackground(now: Date = Date()) {
        session?.pause(at: now)
        persistSession()
        persist()
        scheduleBackgroundRefresh()
    }

    /// Hintergrundaktualisierung: Sperrzustand abgleichen (falls ein Rückruf des Systems ausblieb).
    func backgroundRefresh() {
        screenTime.ensureMonitoring()
        refresh()
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        BackgroundRefresh.schedule(after: screenTime.decision?.nextReevaluation)
    }

    // MARK: - Planung

    func replan(trigger: ReplanTrigger, announce: Bool = true, now: Date = Date()) {
        var result: PlanResult?
        mutate { state in
            result = coach.replan(&state, triggers: [trigger], now: now)
        }
        guard let result else { return }
        if announce, !result.change.reasons.isEmpty, trigger != .initial {
            let text = result.change.reasons.prefix(3).joined(separator: "\n")
            banner = Banner(kind: result.warnings.contains { $0.kind == .insufficientTime } ? .warning : .info, title: "Lernplan aktualisiert", message: text)
        }
        autoSyncCalendar()
        Task { await notifications.reschedule(state: state, level: state.settings.notificationLevel) }
    }

    func moveTask(_ taskID: UUID, to start: Date) {
        mutate { coach.moveTask(&$0, taskID: taskID, to: start) }
        replan(trigger: .taskMovedByUser)
    }

    func skipTask(_ taskID: UUID) {
        mutate { coach.skipTask(&$0, taskID: taskID) }
        replan(trigger: .routine, announce: false)
    }

    // MARK: - Prüfungen und Einstellungen

    func addExam(_ exam: Exam) {
        mutate { $0.exams.append(exam) }
    }

    func updateExam(_ exam: Exam) {
        guard let old = state.exam(exam.id) else { return }
        mutate { state in
            if let i = state.exams.firstIndex(where: { $0.id == exam.id }) { state.exams[i] = exam }
        }
        if !calendar.isDate(old.examDate, inSameDayAs: exam.examDate) {
            replan(trigger: .examDateChanged(examTitle: exam.title))
        } else if old.targetGradeID != exam.targetGradeID || old.gradeScale != exam.gradeScale {
            replan(trigger: .targetChanged(examTitle: exam.title))
        }
    }

    func deleteExam(_ examID: UUID) {
        let documents = state.documents(for: examID)
        for d in documents {
            store.deleteChunks(documentID: d.id)
            store.deleteDocumentFile(d.storedFileName)
            chunkCache[d.id] = nil
        }
        mutate { MaterialIntegrator.removeExam(&$0, examID: examID) }
        replan(trigger: .routine, announce: false)
    }

    func updatePreferences(_ preferences: StudyPreferences) {
        mutate { $0.preferences = preferences }
        replan(trigger: .preferencesChanged)
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        mutate { change(&$0.settings) }
        Task { await notifications.reschedule(state: state, level: state.settings.notificationLevel) }
    }

    func updateRewardPolicy(_ policy: RewardPolicy) {
        mutate { $0.rewardPolicy = policy }
    }

    func setOutcome(examID: UUID, gradeID: String) {
        let forecast = snapshot.exam(examID)?.forecast
        mutate { state in
            if let i = state.exams.firstIndex(where: { $0.id == examID }) {
                state.exams[i].outcome = ExamOutcome(actualGradeID: gradeID, enteredAt: Date(), forecastGradeID: forecast?.predictedBand.id, forecastScore: forecast?.expectedScore)
            }
        }
    }

    // MARK: - Bildschirmzeit-Konto

    func redeem(minutes: Int) {
        do {
            switch screenTime.redemptionCheck() {
            case .allowed: break
            case .notNeeded:
                banner = Banner(kind: .info, title: "Gerade nicht nötig", message: "Deine Apps sind im Moment nicht gesperrt. Deine Minuten bleiben auf dem Konto.")
                return
            case .lockNotActive:
                banner = Banner(kind: .info, title: "Sperre nicht aktiv", message: "Richte zuerst die App-Sperre unter Profil → Bildschirmzeit ein.")
                return
            case .blockedByStrictMode:
                banner = Banner(kind: .info, title: "Strenger Lernmodus", message: "Während deiner Lernzeit kannst du im strengen Modus keine Belohnung einlösen. Nach der Lernzeit geht es wieder.")
                return
            }
            var copy = state
            try coach.redeem(&copy, minutes: minutes, now: Date())
            try screenTime.redeem(minutes: minutes)
            state = copy
            persist()
            refresh()
            banner = Banner(kind: .success, title: "\(minutes) Minuten freigeschaltet", message: "Viel Spaß! Du kannst die Zeit jederzeit vorzeitig beenden – ungenutzte Minuten gehen nicht verloren.")
        } catch {
            banner = Banner(kind: .warning, title: "Einlösen nicht möglich", message: (error as? LocalizedError)?.errorDescription ?? "Bitte erneut versuchen.")
        }
    }

    func endRewardEarly() {
        let unused = screenTime.endRewardEarly()
        mutate { coach.returnUnused(&$0, minutes: unused, now: Date()) }
        if unused > 0 { banner = Banner(kind: .info, title: "\(unused) Minuten zurückgebucht", message: "Sie stehen dir später wieder zur Verfügung.") }
    }

    func startEmergencyPause() {
        do {
            try screenTime.startEmergencyPause()
            refresh()
            banner = Banner(kind: .info, title: "Notfall-Pause gestartet", message: "Für \(screenTime.policy.emergencyPauseMinutes) Minuten sind deine Apps frei. Die Pause wird nicht vom Konto abgebucht.")
        } catch {
            banner = Banner(kind: .warning, title: "Keine Notfall-Pause mehr", message: "Für heute sind alle Notfall-Pausen aufgebraucht. Telefon und Notruf sind davon nie betroffen.")
        }
    }

    // MARK: - Daten löschen

    func deleteAllData() {
        _ = calendarService.removeAllManagedEvents(links: state.calendarLinks)
        try? store.deleteEverything()
        Keychain.set(nil, for: AIService.tokenKey)
        screenTime.updatePolicy { $0 = ShieldPolicy() }
        screenTime.updateSelection(.init())
        session = nil
        chunkCache = [:]
        state = AppState()
        lastRoutineDayKey = nil
        persist()
        refresh()
    }
}
