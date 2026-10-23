import LernKern
import SwiftUI

/// "Heute": Was ist heute zu tun, wie weit bin ich, was habe ich verdient?
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedTab: RootView.Tab
    @State private var showRedeem = false
    @State private var showTaskDetail: StudyTask?
    @State private var showEmergencyConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    header
                    if model.snapshot.exams.isEmpty {
                        emptyState
                    } else {
                        if model.snapshot.fullMastery.isComplete { masteryCard }
                        dailyGoalCard
                        nextUpCard
                        ScreenTimeCard(showRedeem: $showRedeem, showEmergencyConfirm: $showEmergencyConfirm)
                        metrics
                        scheduleCard
                    }
                }
                .padding()
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Heute")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { model.refresh() }
            .sheet(isPresented: $showRedeem) { RedeemSheet().presentationDetents([.medium]) }
            .sheet(item: $showTaskDetail) { task in TaskDetailSheet(task: task).presentationDetents([.medium, .large]) }
            .confirmationDialog("Notfall-Pause starten?", isPresented: $showEmergencyConfirm, titleVisibility: .visible) {
                Button("\(model.screenTime.policy.emergencyPauseMinutes) Minuten pausieren") { model.startEmergencyPause() }
            } message: {
                Text("Für dringende Fälle (z. B. Organisation, Kommunikation). Noch \(model.screenTime.emergencyPausesLeft()) Pause(n) heute. Telefon und Notruf sind nie gesperrt.")
            }
        }
    }

    // MARK: - Abschnitte

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.largeTitle.weight(.bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = model.state.settings.displayName.isEmpty ? "" : ", \(model.state.settings.displayName)"
        switch hour {
        case 5..<11: return "Guten Morgen\(name)!"
        case 11..<17: return "Hallo\(name)!"
        default: return "Guten Abend\(name)!"
        }
    }

    private var subtitle: String {
        let open = model.snapshot.todayTasks.filter(\.isOpen)
        let topics = Set(open.flatMap(\.topicIDs)).count
        if open.isEmpty {
            return model.snapshot.todayTasks.isEmpty ? "Für heute ist nichts geplant." : "Alle Einheiten für heute sind erledigt."
        }
        if topics > 0 { return "Heute konzentrieren wir uns auf \(topics) \(topics == 1 ? "Thema" : "Themen")." }
        return "Heute stehen \(open.count) Lerneinheit\(open.count == 1 ? "" : "en") an."
    }

    private var emptyState: some View {
        Card {
            CardTitle(title: "Los geht's", symbol: "graduationcap")
            Text("Lege eine Prüfung an und lade deine Unterlagen hoch. LernFokus erstellt daraus deinen Lernplan.")
                .foregroundStyle(.secondary)
            Button("Prüfung anlegen") { selectedTab = .material }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var masteryCard: some View {
        Card {
            CardTitle(title: "100 % erreicht", symbol: "checkmark.seal.fill")
            Text("Alle Lernziele sind stabil beherrscht und aktuell präsent. Deine gesperrten Apps sind für den Rest des Tages frei. Genieß es!")
                .foregroundStyle(.secondary)
            if let next = model.snapshot.exams.min(by: { $0.daysUntilExam < $1.daysUntilExam }) {
                Text("Wenn du magst, kannst du freiwillig den nächsten Prüfungstag vorbereiten (\(next.exam.title)).").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var dailyGoalCard: some View {
        if let goal = model.snapshot.dailyGoal {
            Card {
                HStack(spacing: 16) {
                    ProgressRing(fraction: goal.progress, label: goal.record.requiredChecks == 0 ? "–" : "\(Int((goal.progress * 100).rounded())) %")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tagesziel").font(.headline)
                        Text(goal.text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if goal.record.plannedMinutes > 0 {
                            Text("Geplant: \(Formatters.minutes(goal.record.plannedMinutes)) · Erledigt: \(Formatters.minutes(model.snapshot.todayCompletedMinutes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nextUpCard: some View {
        if let recommendation = model.snapshot.recommendation {
            Card {
                CardTitle(title: "Als Nächstes", symbol: "arrow.right.circle")
                Text(recommendation.title).font(.title3.weight(.semibold))
                if let task = model.snapshot.nextTask, task.id == recommendation.taskID {
                    Text("\(Formatters.time.string(from: task.start)) · \(task.durationMinutes) Min. · \(model.state.exam(task.examID)?.title ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Label(recommendation.reason, systemImage: "lightbulb")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    Task { await start(recommendation) }
                } label: {
                    if model.isGeneratingQuestions { ProgressView().tint(.white) } else { Text("Lernen starten") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isGeneratingQuestions)
                if let task = model.snapshot.nextTask, task.id == recommendation.taskID {
                    Button("Details und Begründung") { showTaskDetail = task }.font(.footnote)
                }
            }
        } else if !model.snapshot.fullMastery.isComplete {
            Card {
                CardTitle(title: "Gerade nichts offen", symbol: "checkmark.circle")
                Text("Für heute ist alles erledigt oder es gibt noch keine Lernziele. Lade weitere Unterlagen hoch oder übe frei im Lernstoff.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func start(_ recommendation: Recommendation) async {
        if let taskID = recommendation.taskID, let task = model.state.tasks.first(where: { $0.id == taskID }) {
            await model.startSession(for: task)
        } else if let examID = recommendation.examID {
            await model.startPractice(examID: examID, objectiveIDs: recommendation.objectiveIDs, kind: recommendation.kind)
        }
    }

    private var metrics: some View {
        let exam = model.snapshot.exams.min { $0.daysUntilExam < $1.daysUntilExam }
        return VStack(alignment: .leading, spacing: 8) {
            if let exam {
                Text(exam.exam.title + (exam.daysUntilExam > 0 ? " · in \(exam.daysUntilExam) Tag\(exam.daysUntilExam == 1 ? "" : "en")" : " · heute"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    MetricTile(title: "Fortschritt", value: "\(exam.progress.percent) %", detail: "\(exam.progress.completeCount) von \(exam.progress.objectiveCount) Lernzielen")
                    MetricTile(title: "Notenprognose", value: exam.forecast.confidence == .insufficient ? "–" : exam.forecast.predictedBand.label,
                               detail: exam.forecast.confidence.title)
                    MetricTile(title: "Noch nötig", value: exam.time.toTarget.map { shortRange($0) } ?? "–", detail: exam.time.feasibility.title)
                }
                Button("Details ansehen") { selectedTab = .progress }.font(.footnote)
            }
        }
    }

    private func shortRange(_ range: MinuteRange) -> String {
        if range.high == 0 { return "0" }
        if range.high < 90 { return "\(range.high) Min." }
        return "\(Int((Double(range.low) / 60).rounded()))–\(Int((Double(range.high) / 60).rounded())) h"
    }

    @ViewBuilder
    private var scheduleCard: some View {
        if case .behind(let tasks, let minutes) = model.snapshot.schedule {
            Card {
                CardTitle(title: "Etwas im Rückstand", symbol: "clock.arrow.circlepath")
                Text("\(tasks) Einheit\(tasks == 1 ? "" : "en") (\(Formatters.minutes(minutes))) sind offen geblieben. Das ist kein Problem – der Plan verteilt sie realistisch neu.")
                    .foregroundStyle(.secondary)
                Button("Plan anpassen") { model.replan(trigger: .routine) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        ForEach(model.snapshot.exams.filter { $0.time.feasibility == .unrealistic }) { exam in
            Card {
                CardTitle(title: "Ehrliche Einschätzung", symbol: "exclamationmark.bubble")
                Text("\(exam.exam.title): \(exam.time.headline)").foregroundStyle(.secondary)
                Button("Möglichkeiten ansehen") { selectedTab = .progress }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// Bildschirmzeit-Status, Konto und Einlösen.
struct ScreenTimeCard: View {
    @Environment(AppModel.self) private var model
    @Binding var showRedeem: Bool
    @Binding var showEmergencyConfirm: Bool

    var body: some View {
        let screenTime = model.screenTime
        Card {
            HStack(alignment: .firstTextBaseline) {
                CardTitle(title: "Bildschirmzeit", symbol: "hourglass")
                Text("\(model.state.rewardBalance) Min.")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .accessibilityLabel("Verdient: \(model.state.rewardBalance) Minuten")
            }
            if let status = screenTime.decision?.status {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title).font(.subheadline.weight(.medium))
                        if let detail = status.detail(formatter: Formatters.time) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: status.symbolName)
                }
                if !screenTime.isConsistent {
                    Label("Die Sperre im System weicht ab. Öffne Profil → Bildschirmzeit, um den Zustand zu prüfen.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                actions(for: status)
            }
            Text("Heute verdient: \(model.snapshot.earnedToday) Min.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(for status: LockStatus) -> some View {
        switch status {
        case .locked:
            HStack {
                Button("Minuten einlösen") { showRedeem = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.state.rewardBalance == 0)
            }
            if model.screenTime.emergencyPausesLeft() > 0 {
                Button("Notfall-Pause") { showEmergencyConfirm = true }.font(.footnote).foregroundStyle(.secondary)
            }
        case .rewardWindow:
            HStack {
                Button("Mehr einlösen") { showRedeem = true }.buttonStyle(SecondaryButtonStyle()).disabled(model.state.rewardBalance == 0)
                Button("Vorzeitig beenden") { model.endRewardEarly() }.buttonStyle(SecondaryButtonStyle())
            }
        case .permissionMissing, .notConfigured, .disabled:
            NavigationLink("App-Sperre einrichten") { ScreenTimeSettingsView() }
                .font(.subheadline.weight(.medium))
        default:
            EmptyView()
        }
    }
}

struct RedeemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 10

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: 1...max(1, model.state.rewardBalance), step: 1) {
                        Text("\(minutes) Minuten").monospacedDigit()
                    }
                    HStack {
                        ForEach([5, 10, 15, 30].filter { $0 <= model.state.rewardBalance }, id: \.self) { value in
                            Button("\(value)") { minutes = value }.buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    Text("Verfügbar: \(model.state.rewardBalance) Min. Die Apps sind danach automatisch wieder gesperrt. Nicht genutzte Minuten kannst du zurückbuchen.")
                }
                Section {
                    Button("Jetzt freischalten") {
                        model.redeem(minutes: minutes)
                        dismiss()
                    }
                    .disabled(model.state.rewardBalance == 0)
                }
            }
            .navigationTitle("Minuten einlösen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .onAppear { minutes = min(10, max(1, model.state.rewardBalance)) }
        }
    }
}
