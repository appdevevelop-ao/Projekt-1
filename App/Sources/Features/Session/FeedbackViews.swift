import LernKern
import SwiftUI

/// Rückmeldung nach einer Antwort: richtig/falsch, Erklärung, Lösung, Quelle, typische Fehler.
struct FeedbackView: View {
    @Environment(AppModel.self) private var model
    let question: Question
    let evaluation: AnswerEvaluation
    let userAnswer: String?
    @State private var extraExplanation: (text: String, fromAI: Bool)?
    @State private var loadingExplanation = false
    @State private var showSource = false
    @State private var confirmReport = false

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                Text(headline).font(.title3.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            if !evaluation.feedback.isEmpty { Text(evaluation.feedback) }
            if evaluation.verdict != .correct {
                let solution = solutionText
                if !solution.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Richtige Lösung").font(.caption).foregroundStyle(.secondary)
                        Text(solution).font(.body.weight(.medium))
                    }
                }
            }
            if !question.explanation.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erklärung").font(.caption).foregroundStyle(.secondary)
                    Text(question.explanation)
                }
            }
            if !question.commonMistakes.isEmpty, evaluation.verdict != .correct {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Typische Fehler").font(.caption).foregroundStyle(.secondary)
                    ForEach(question.commonMistakes, id: \.self) { Text("• \($0)") }
                }
            }
            if let extra = extraExplanation {
                VStack(alignment: .leading, spacing: 2) {
                    Text(extra.fromAI ? "Einfacher erklärt (KI, auf Basis deiner Unterlagen)" : "Einfacher erklärt").font(.caption).foregroundStyle(.secondary)
                    Text(extra.text)
                }
            }
            if let source = question.source {
                Button { showSource = true } label: {
                    Label(sourceLabel(source), systemImage: "doc.text")
                        .font(.footnote)
                }
            }
            HStack {
                if extraExplanation == nil && evaluation.verdict != .correct && (question.simplerExplanation != nil || model.state.settings.isAIUsable) {
                    Button {
                        Task {
                            loadingExplanation = true
                            extraExplanation = await model.explanation(for: question, mode: evaluation.verdict == .incorrect ? "mistake" : "simpler", userAnswer: userAnswer)
                            if extraExplanation == nil { extraExplanation = ("Gerade keine zusätzliche Erklärung verfügbar. Sieh dir die Quelle in deinen Unterlagen an.", false) }
                            loadingExplanation = false
                        }
                    } label: {
                        if loadingExplanation { ProgressView() } else { Text("Einfacher erklären") }
                    }
                    .font(.footnote)
                }
                Spacer()
                Button("Frage melden") { confirmReport = true }.font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSource) {
            if let source = question.source { SourceSheet(reference: source) }
        }
        .confirmationDialog("Ist diese Frage fehlerhaft oder unklar?", isPresented: $confirmReport, titleVisibility: .visible) {
            Button("Frage melden und entfernen", role: .destructive) { model.reportCurrentQuestion(question.id) }
        } message: {
            Text("Gemeldete Fragen werden nicht mehr gestellt. Deine Antworten darauf zählen nicht.")
        }
    }

    private var headline: String {
        switch evaluation.verdict {
        case .correct: return "Richtig"
        case .partial: return "Teilweise richtig"
        case .incorrect: return "Noch nicht ganz"
        case .needsReview: return "Bewertung offen"
        }
    }

    private var symbol: String {
        switch evaluation.verdict {
        case .correct: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        default: return "arrow.uturn.backward.circle"
        }
    }

    private var tint: Color {
        switch evaluation.verdict {
        case .correct: return Theme.success
        case .partial: return .orange
        default: return .secondary
        }
    }

    private var solutionText: String {
        if !evaluation.correctAnswer.isEmpty { return evaluation.correctAnswer }
        switch question.kind {
        case .multipleChoice, .trueFalse: return question.correctOptionIndices.compactMap { question.options.indices.contains($0) ? question.options[$0] : nil }.joined(separator: ", ")
        case .matching: return question.pairs.map { "\($0.left) → \($0.right)" }.joined(separator: "\n")
        default: return question.acceptedAnswers.first ?? question.referenceAnswer ?? ""
        }
    }

    private func sourceLabel(_ source: SourceReference) -> String {
        let name = model.state.documents.first { $0.id == source.documentID }?.fileName ?? "Unterlagen"
        return "Quelle: \(name)" + (source.page.map { ", S. \($0)" } ?? "")
    }
}

/// Zeigt den Originalabschnitt, auf dem eine Frage beruht.
struct SourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reference: SourceReference

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let quote = reference.quote {
                        Text("„\(quote)“").font(.body.italic()).padding(12)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let chunk = model.chunk(for: reference) {
                        Text([chunk.sectionPath.joined(separator: " › "), chunk.pageLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(chunk.text).textSelection(.enabled)
                    } else {
                        Text("Der Abschnitt ist nicht mehr vorhanden (Dokument gelöscht).").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle(model.state.documents.first { $0.id == reference.documentID }?.fileName ?? "Quelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Selbsteinschätzung bei offenen Antworten, wenn keine KI-Bewertung verfügbar ist.
struct SelfAssessmentView: View {
    let question: Question
    let answer: String
    let onRate: (Double) -> Void

    var body: some View {
        Card {
            CardTitle(title: "Vergleiche mit der Musterlösung", symbol: "person.fill.checkmark")
            if let reference = question.referenceAnswer, !reference.isEmpty {
                Text(reference).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            if !question.rubric.isEmpty {
                let coverage = AnswerEvaluator.rubricCoverage(answer: answer, rubric: question.rubric)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kernpunkte").font(.caption).foregroundStyle(.secondary)
                    ForEach(question.rubric, id: \.self) { point in
                        Label(point, systemImage: coverage.covered.contains(point) ? "checkmark.circle" : "circle")
                            .font(.subheadline)
                    }
                    Text("Die Markierung ist nur eine Hilfe – du entscheidest selbst.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Wie gut war deine Antwort?").font(.subheadline.weight(.medium))
            HStack {
                Button("Nicht gewusst") { onRate(0) }.buttonStyle(SecondaryButtonStyle())
                Button("Teilweise") { onRate(0.5) }.buttonStyle(SecondaryButtonStyle())
                Button("Vollständig") { onRate(1) }.buttonStyle(SecondaryButtonStyle())
            }
            Text("Selbsteinschätzungen zählen nur halb für deinen Wissensstand.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BreakView: View {
    let until: Date

    var body: some View {
        Card {
            CardTitle(title: "Pause", symbol: "cup.and.saucer")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(until.timeIntervalSince(context.date)))
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text("Steh kurz auf, trink etwas, schau aus dem Fenster. Danach geht es weiter.").foregroundStyle(.secondary)
        }
    }
}

/// Auswertung einer Einheit oder Simulation – mit nachvollziehbarer Belohnungsberechnung.
struct SessionSummaryView: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    let session: StudySessionState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let sim = summary.simulation, let exam = model.state.exam(sim.examID) {
                    simulationCard(sim, exam: exam)
                } else {
                    Card {
                        Text("\(summary.correct) von \(summary.total) richtig").font(.largeTitle.weight(.bold))
                        if let check = summary.check {
                            Text(check.passed ? "Wissensüberprüfung bestanden." : "Diesmal noch nicht bestanden – jede Antwort hilft dem Wissensstand.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                rewardCard
                if !summary.levelChanges.isEmpty {
                    Card {
                        CardTitle(title: "Fortschritt", symbol: "arrow.up.right")
                        ForEach(summary.levelChanges) { change in
                            HStack {
                                Text(change.title).font(.subheadline)
                                Spacer()
                                LevelBadge(level: change.to)
                            }
                        }
                    }
                }
                if let goal = summary.dailyGoal {
                    Card {
                        CardTitle(title: "Tagesziel", symbol: "target")
                        LinearBar(fraction: goal.progress)
                        Text(goal.text).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if summary.unlockedForDay {
                    Card {
                        CardTitle(title: "100 % erreicht", symbol: "checkmark.seal.fill")
                        Text("Alle Lernziele sind stabil beherrscht. Deine Apps sind bis Mitternacht frei.").foregroundStyle(.secondary)
                    }
                }
                Button("Fertig") { model.closeSession() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var rewardCard: some View {
        if let grant = summary.grant {
            Card {
                HStack {
                    CardTitle(title: "Bildschirmzeit", symbol: "hourglass")
                    Text(grant.minutes > 0 ? "+\(grant.minutes) Min." : "±0").font(.title2.weight(.bold)).foregroundStyle(grant.minutes > 0 ? Theme.success : .secondary)
                }
                DisclosureGroup("So wurde gerechnet") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(grant.lines, id: \.self) { Text("• \($0)").font(.footnote) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }
        }
    }

    private func simulationCard(_ sim: ExamSimulationResult, exam: Exam) -> some View {
        let band = exam.gradeScale.band(id: sim.gradeBandID)
        return Card {
            CardTitle(title: "Ergebnis der Simulation", symbol: "timer")
            Text("\(Int((sim.scoreFraction * 100).rounded())) % der Punkte").font(.largeTitle.weight(.bold))
            if let band {
                Text("Das entspricht ungefähr einer \(band.label) (\(band.name))\(exam.gradeScale.isOfficial ? "" : " – nach geschätzten Notengrenzen").")
                    .foregroundStyle(.secondary)
            }
            let topicTitles = Dictionary(uniqueKeysWithValues: model.state.topics.map { ($0.id, $0.title) })
            ForEach(sim.topicScores, id: \.topicID) { score in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(topicTitles[score.topicID] ?? "Thema").font(.subheadline)
                        Spacer()
                        Text("\(Int((score.fraction * 100).rounded())) %").font(.subheadline.monospacedDigit())
                    }
                    LinearBar(fraction: score.fraction, tint: score.fraction < 0.5 ? .orange : .accentColor)
                }
            }
            Text("Fehler kannst du in der nächsten Einheit „Fehler analysieren“ durchgehen.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
