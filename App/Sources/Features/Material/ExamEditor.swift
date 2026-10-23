import LernKern
import SwiftUI

/// Notenskala-Vorlagen für die Auswahl.
enum ScalePreset: String, CaseIterable, Identifiable {
    case austrian, german, passFail, points
    var id: String { rawValue }

    var title: String {
        switch self {
        case .austrian: return "Österreich (1–5)"
        case .german: return "Deutschland (1–6)"
        case .passFail: return "Bestanden / nicht bestanden"
        case .points: return "Punktesystem"
        }
    }

    static func preset(for scale: GradeScale) -> ScalePreset {
        switch scale.kind {
        case .austrian: return .austrian
        case .german: return .german
        case .percent: return .passFail
        case .points: return .points
        case .custom: return .austrian
        }
    }

    func makeScale(maxPoints: Double, passThreshold: Double) -> GradeScale {
        switch self {
        case .austrian: return .austrian
        case .german: return .german
        case .passFail: return .passFail(threshold: passThreshold, isOfficial: false)
        case .points:
            let max = Swift.max(1, maxPoints)
            return .points(maxPoints: max, thresholds: [
                ("1", "Sehr gut", (max * 0.875).rounded(), true), ("2", "Gut", (max * 0.75).rounded(), true),
                ("3", "Befriedigend", (max * 0.625).rounded(), true), ("4", "Genügend", (max * 0.5).rounded(), true),
                ("5", "Nicht genügend", 0, false),
            ], isOfficial: false)
        }
    }
}

/// Formular für Prüfungsangaben (Onboarding und Bearbeiten).
struct ExamForm: View {
    @Binding var exam: Exam
    @State private var preset: ScalePreset = .austrian
    @State private var maxPoints = 100.0
    @State private var passPercent = 50.0
    @State private var hasDuration = false

    var body: some View {
        Section("Prüfung") {
            TextField("Fach oder Prüfung, z. B. Biologie", text: $exam.title)
            DatePicker("Termin", selection: $exam.examDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            Picker("Prüfungsform", selection: $exam.format) {
                ForEach(ExamFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Dauer bekannt", isOn: $hasDuration)
            if hasDuration {
                Stepper("Dauer: \(exam.durationMinutes ?? 60) Min.", value: Binding(get: { exam.durationMinutes ?? 60 }, set: { exam.durationMinutes = $0 }), in: 10...300, step: 5)
            }
        }
        Section {
            Picker("Notenskala", selection: $preset) {
                ForEach(ScalePreset.allCases) { Text($0.title).tag($0) }
            }
            if preset == .points {
                Stepper("Maximal \(Int(maxPoints)) Punkte", value: $maxPoints, in: 5...500, step: 5)
            }
            if preset == .passFail {
                Stepper("Bestanden ab \(Int(passPercent)) %", value: $passPercent, in: 10...95, step: 5)
            }
            Picker("Zielnote", selection: $exam.targetGradeID) {
                ForEach(exam.gradeScale.bands.filter(\.isPassing)) { band in
                    Text(band.label == band.name ? band.name : "\(band.label) – \(band.name)").tag(band.id)
                }
            }
            NavigationLink("Notengrenzen anpassen") { GradeScaleEditor(scale: $exam.gradeScale) }
        } header: {
            Text("Bewertung")
        } footer: {
            Text(exam.gradeScale.isOfficial ? "Die Grenzen sind als offiziell markiert." : "Die Notengrenzen sind eine Schätzung. Trage die offiziellen Grenzen ein, falls du sie kennst – dann wird die Prognose genauer.")
        }
        .onChange(of: preset) { _, newValue in applyPreset(newValue) }
        .onChange(of: maxPoints) { _, _ in if preset == .points { applyPreset(.points) } }
        .onChange(of: passPercent) { _, _ in if preset == .passFail { applyPreset(.passFail) } }
        Section {
            Picker("Vorkenntnisse", selection: $exam.priorKnowledge) {
                ForEach(PriorKnowledge.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Zusätzliche Anforderungen (optional)", text: $exam.additionalRequirements, axis: .vertical).lineLimit(2...5)
        } footer: {
            Text("Zum Beispiel: „Kapitel 7 ist nicht prüfungsrelevant“ oder „Schwerpunkt auf Rechenaufgaben“.")
        }
        .onAppear {
            preset = ScalePreset.preset(for: exam.gradeScale)
            hasDuration = exam.durationMinutes != nil
            maxPoints = exam.gradeScale.maxPoints ?? 100
            passPercent = (exam.gradeScale.bands.first { $0.isPassing }?.minFraction ?? 0.5) * 100
        }
        .onChange(of: hasDuration) { _, has in exam.durationMinutes = has ? (exam.durationMinutes ?? 60) : nil }
    }

    private func applyPreset(_ p: ScalePreset) {
        let scale = p.makeScale(maxPoints: maxPoints, passThreshold: passPercent / 100)
        guard scale != exam.gradeScale else { return }
        exam.gradeScale = scale
        if scale.band(id: exam.targetGradeID) == nil || !(scale.band(id: exam.targetGradeID)?.isPassing ?? false) {
            exam.targetGradeID = scale.defaultTargetID
        }
    }
}

/// Notengrenzen bearbeiten (in Prozent oder Punkten).
struct GradeScaleEditor: View {
    @Binding var scale: GradeScale

    var body: some View {
        Form {
            Section {
                Toggle("Offizielle Grenzen", isOn: $scale.isOfficial)
            } footer: {
                Text("Nur einschalten, wenn die Grenzen von der Schule, Hochschule oder Prüfungsstelle stammen.")
            }
            Section(scale.maxPoints != nil ? "Mindestpunkte" : "Mindestanteil") {
                ForEach(scale.bands.indices, id: \.self) { index in
                    if index < scale.bands.count - 1 {
                        HStack {
                            Text("\(scale.bands[index].label) – \(scale.bands[index].name)")
                            Spacer()
                            if let maxPoints = scale.maxPoints {
                                Stepper("\(Int((scale.bands[index].minFraction * maxPoints).rounded()))", value: Binding(
                                    get: { (scale.bands[index].minFraction * maxPoints).rounded() },
                                    set: { scale.bands[index].minFraction = Swift.min(1, Swift.max(0, $0 / maxPoints)) }
                                ), in: 0...maxPoints, step: 1)
                                .fixedSize()
                            } else {
                                Stepper("\(Int((scale.bands[index].minFraction * 100).rounded())) %", value: Binding(
                                    get: { (scale.bands[index].minFraction * 100).rounded() },
                                    set: { scale.bands[index].minFraction = Swift.min(1, Swift.max(0, $0 / 100)) }
                                ), in: 0...100, step: 1)
                                .fixedSize()
                            }
                        }
                    } else {
                        LabeledContent("\(scale.bands[index].label) – \(scale.bands[index].name)", value: "darunter")
                    }
                }
            }
            if !scale.validationErrors.isEmpty {
                Section {
                    ForEach(scale.validationErrors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                }
            }
        }
        .navigationTitle("Notengrenzen")
    }
}

struct ExamEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Exam?
    @State private var exam: Exam
    @State private var confirmDelete = false
    @State private var enteringOutcome = false

    init(exam: Exam?) {
        existing = exam
        _exam = State(initialValue: exam ?? Exam(title: "", examDate: Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                ExamForm(exam: $exam)
                if let existing {
                    Section {
                        Toggle("Archiviert", isOn: $exam.isArchived)
                        if existing.examDate < Date() {
                            Button("Tatsächliches Ergebnis eintragen") { enteringOutcome = true }
                        }
                        Button("Prüfung löschen", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Mit dem tatsächlichen Ergebnis kannst du später sehen, wie genau die Prognose war.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "Neue Prüfung" : "Prüfung bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if existing == nil {
                            model.addExam(exam)
                            model.replan(trigger: .initial, announce: false)
                        } else {
                            model.updateExam(exam)
                        }
                        dismiss()
                    }
                    .disabled(exam.title.trimmingCharacters(in: .whitespaces).isEmpty || !exam.gradeScale.validationErrors.isEmpty)
                }
            }
            .confirmationDialog("Prüfung mit allen Unterlagen und Ergebnissen löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    model.deleteExam(exam.id)
                    dismiss()
                }
            }
            .confirmationDialog("Welche Note hast du bekommen?", isPresented: $enteringOutcome, titleVisibility: .visible) {
                ForEach(exam.gradeScale.bands) { band in
                    Button(band.label == band.name ? band.name : "\(band.label) – \(band.name)") { model.setOutcome(examID: exam.id, gradeID: band.id) }
                }
            }
        }
    }
}
