import FamilyControls
import LernKern
import SwiftUI

/// Einrichtung in fünf kurzen Schritten: Ziel → Prüfung → Unterlagen → Bildschirmzeit → Lernplan.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .goal
    @State private var exam = Exam(title: "", examDate: Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date())
    @State private var examCreated = false
    @State private var dailyMinutes = 60
    @State private var timeOfDay: TimeOfDay = .afternoon
    @State private var weekends = true

    enum Step: Int, CaseIterable { case goal, exam, material, screenTime, plan }

    enum TimeOfDay: String, CaseIterable, Identifiable {
        case morning, afternoon, evening
        var id: String { rawValue }
        var title: String {
            switch self {
            case .morning: return "Morgens"
            case .afternoon: return "Nachmittags"
            case .evening: return "Abends"
            }
        }
        var startMinute: Int {
            switch self {
            case .morning: return 8 * 60
            case .afternoon: return 15 * 60
            case .evening: return 19 * 60
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .padding(.horizontal)
                    .accessibilityLabel("Schritt \(step.rawValue + 1) von \(Step.allCases.count)")
                Group {
                    switch step {
                    case .goal: goalStep
                    case .exam: examStep
                    case .material: OnboardingMaterialStep(examID: exam.id, onNext: { step = .screenTime })
                    case .screenTime: OnboardingScreenTimeStep(onNext: { step = .plan })
                    case .plan: OnboardingPlanStep(examID: exam.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .goal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Zurück") { step = Step(rawValue: step.rawValue - 1) ?? .goal }
                    }
                }
            }
        }
    }

    private var title: String {
        switch step {
        case .goal: return "Willkommen"
        case .exam: return "Deine Prüfung"
        case .material: return "Lernmaterial"
        case .screenTime: return "Bildschirmzeit"
        case .plan: return "Dein Lernplan"
        }
    }

    // MARK: Schritt 1

    private var goalStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Lernen, das sich auszahlt.").font(.largeTitle.weight(.bold))
                Text("LernFokus erstellt aus deinen Unterlagen einen Lernplan, prüft, was du wirklich kannst, und schaltet ablenkende Apps frei, wenn du gelernt hast.")
                    .foregroundStyle(.secondary)
                Text("Was möchtest du erreichen?").font(.headline).padding(.top, 8)
                ForEach(StudyGoalType.allCases, id: \.self) { goal in
                    Button {
                        exam.goal = goal
                        if goal == .pass { exam.targetGradeID = exam.gradeScale.lowestPassingID }
                        step = .exam
                    } label: {
                        HStack {
                            Image(systemName: symbol(goal)).frame(width: 28).foregroundStyle(.tint)
                            Text(goal.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding()
                        .frame(minHeight: 56)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func symbol(_ goal: StudyGoalType) -> String {
        switch goal {
        case .pass: return "checkmark.circle"
        case .specificGrade: return "target"
        case .masterMaterial: return "books.vertical"
        case .multipleExams: return "square.stack.3d.up"
        }
    }

    // MARK: Schritt 2

    private var examStep: some View {
        Form {
            ExamForm(exam: $exam)
            Section {
                Picker("Lernzeit pro Tag", selection: $dailyMinutes) {
                    ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text(Formatters.minutes($0)).tag($0) }
                }
                Picker("Am liebsten", selection: $timeOfDay) {
                    ForEach(TimeOfDay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Auch am Wochenende", isOn: $weekends)
            } header: {
                Text("Deine Lernzeit")
            } footer: {
                Text("Das kannst du später unter Profil → Lernzeiten genauer einstellen, z. B. pro Wochentag oder mit lernfreien Tagen.")
            }
            Section {
                Button("Weiter") { saveExam() }
                    .disabled(exam.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func saveExam() {
        var prefs = model.state.preferences
        for index in 0..<7 {
            let isWeekend = index == 0 || index == 6
            prefs.minutesPerWeekday[index] = (isWeekend && !weekends) ? 0 : dailyMinutes
            prefs.startMinutePerWeekday[index] = isWeekend && timeOfDay == .afternoon ? 10 * 60 : timeOfDay.startMinute
        }
        let newPrefs = prefs
        if examCreated {
            model.updateExam(exam)
        } else {
            model.addExam(exam)
            examCreated = true
        }
        model.mutate { $0.preferences = newPrefs }
        step = .material
    }
}

struct OnboardingMaterialStep: View {
    @Environment(AppModel.self) private var model
    let examID: UUID
    let onNext: () -> Void
    @State private var importing = false
    @State private var scanning = false

    var body: some View {
        List {
            Section {
                Text("Lade Skripte, Folien, Bücherkapitel oder Fotos deiner Mitschriften hoch. LernFokus erkennt Kapitel, Lernziele und wichtige Begriffe.")
                    .foregroundStyle(.secondary)
                Button("Dateien auswählen", systemImage: "doc.badge.plus") { importing = true }
                if DocumentScannerView.isSupported {
                    Button("Seiten scannen", systemImage: "doc.viewfinder") { scanning = true }
                }
            } footer: {
                Text("Unterstützt: PDF (auch gescannt), Word, PowerPoint, Text und Fotos. Große Dokumente werden in Abschnitten verarbeitet.")
            }
            let documents = model.state.documents(for: examID)
            if !documents.isEmpty {
                Section("Hochgeladen") {
                    ForEach(documents) { DocumentRow(document: $0) }
                }
            }
            Section {
                Button(documents.isEmpty ? "Später hinzufügen" : "Weiter") { onNext() }
                    .disabled(!model.importProgress.isEmpty)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: SupportedTypes.all, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { for url in urls { await model.importFile(at: url, examID: examID) } }
            }
        }
        .sheet(isPresented: $scanning) {
            DocumentScannerView { images in
                scanning = false
                guard !images.isEmpty else { return }
                Task { await model.importImages(images, name: "Scan", examID: examID) }
            }
            .ignoresSafeArea()
        }
    }
}

struct OnboardingScreenTimeStep: View {
    @Environment(AppModel.self) private var model
    let onNext: () -> Void
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection()
    @State private var mode: LockMode = .combined

    var body: some View {
        let screenTime = model.screenTime
        Form {
            Section {
                Text("Während deiner Lernzeit pausiert LernFokus Apps, die dich ablenken. Mit Lernen verdienst du Bildschirmzeit, und bei 100 % sind die Apps für den Rest des Tages frei.")
                Text("Dafür fragt iOS nach der Bildschirmzeit-Berechtigung. LernFokus sieht nicht, welche Apps du nutzt.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("1. Berechtigung") {
                if screenTime.isAuthorized {
                    Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                } else {
                    Button("Bildschirmzeit erlauben") { Task { await screenTime.requestAuthorization() } }
                }
                if let error = screenTime.lastError { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
            }
            Section {
                LabeledContent("Ausgewählt", value: screenTime.selection.selectionSummary)
                Button("Apps, Kategorien und Websites auswählen") {
                    selection = screenTime.selection
                    showPicker = true
                }
                .disabled(!screenTime.isAuthorized)
            } header: {
                Text("2. Was lenkt dich ab?")
            } footer: {
                Text("Mehrfachauswahl ist möglich, z. B. ganze Kategorien wie Soziale Netzwerke, Spiele und Unterhaltung. Telefon und Notruf werden nie gesperrt.")
            }
            Section("3. Modus") {
                Picker("Modus", selection: $mode) {
                    ForEach(LockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(mode.explanation).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Sperre einrichten und weiter") {
                    let windows = StudyWindowsEditor.windows(from: model.state.preferences)
                    screenTime.updatePolicy { policy in
                        policy.mode = mode
                        policy.studyWindows = windows
                        policy.isEnabled = true
                    }
                    onNext()
                }
                .disabled(!screenTime.isAuthorized || screenTime.selection.isEmptySelection)
                Button("Später einrichten") { onNext() }
            } footer: {
                Text("Die Lernzeiten für die Sperre werden aus deinen Lernzeiten übernommen und sind unter Profil → App-Sperre änderbar.")
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: showPicker) { _, shown in if !shown { screenTime.updateSelection(selection) } }
    }
}

struct OnboardingPlanStep: View {
    @Environment(AppModel.self) private var model
    let examID: UUID
    @State private var planned = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let snapshot = model.snapshot.exam(examID) {
                    Card {
                        CardTitle(title: snapshot.exam.title, symbol: "graduationcap")
                        Text("\(snapshot.progress.objectiveCount) Lernziele in \(snapshot.progress.topics.count) Themen").foregroundStyle(.secondary)
                        Text(snapshot.time.headline).font(.subheadline)
                        if snapshot.time.feasibility != .comfortable {
                            Label(snapshot.time.feasibility.title, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                        }
                    }
                }
                let upcoming = model.state.tasks.filter { $0.examID == examID && $0.isOpen }.sorted { $0.start < $1.start }.prefix(6)
                if upcoming.isEmpty {
                    Card {
                        Text("Sobald Lernziele vorhanden sind (z. B. nach dem Hochladen von Unterlagen), entsteht hier dein Plan.").foregroundStyle(.secondary)
                    }
                } else {
                    Card {
                        CardTitle(title: "Die nächsten Einheiten", symbol: "calendar")
                        ForEach(Array(upcoming)) { task in
                            HStack(alignment: .top) {
                                Text("\(Formatters.relativeDay(task.start)) \(Formatters.time.string(from: task.start))").font(.caption.monospacedDigit()).frame(width: 96, alignment: .leading)
                                Text(task.title).font(.subheadline)
                            }
                        }
                    }
                    Button("In Apple Kalender übernehmen", systemImage: "calendar.badge.plus") {
                        Task { await model.enableCalendarSync(calendarIdentifier: nil) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Los geht's") {
                    model.updateSettings { $0.onboardingCompleted = true }
                    model.replan(trigger: .initial, announce: false)
                    Task { _ = await model.notifications.requestAuthorization() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if !planned {
                planned = true
                model.replan(trigger: .initial, announce: false)
            }
        }
    }
}
