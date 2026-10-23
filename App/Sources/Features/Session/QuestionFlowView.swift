import LernKern
import SwiftUI

/// Eine Frage nach der anderen – mit sofortiger Rückmeldung (Übung) oder ohne (Simulation).
struct QuestionFlowView: View {
    @Environment(AppModel.self) private var model
    let session: StudySessionState
    let onFinish: () -> Void

    @State private var selected: Set<Int> = []
    @State private var text = ""
    @State private var matching: [Int?] = []
    @State private var evaluation: AnswerEvaluation?
    @State private var pendingSelfRating = false
    @State private var usedHint = false
    @State private var showHint = false
    @State private var questionStart = Date()
    @State private var isEvaluating = false
    @State private var dismissedBreak = false

    private var question: Question? { model.question(session.currentQuestionID) }
    private var isSimulation: Bool { session.mode == .simulation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header
                if let breakUntil = session.breakUntil, breakUntil > Date() {
                    BreakView(until: breakUntil)
                } else if let question {
                    breakSuggestion
                    QuestionCard(question: question, selected: $selected, text: $text, matching: $matching, locked: evaluation != nil || pendingSelfRating)
                    if showHint, let source = question.source { hint(source) }
                    if pendingSelfRating {
                        SelfAssessmentView(question: question, answer: text) { rating in
                            Task { await submit(selfRating: rating) }
                        }
                    } else if let evaluation {
                        FeedbackView(question: question, evaluation: evaluation, userAnswer: answerText(question))
                        Button(isLast ? "Auswertung anzeigen" : "Nächste Frage") { advance() }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        answerButtons(question)
                    }
                }
            }
            .padding()
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: session.currentQuestionID) { _, _ in resetInputs() }
        .onAppear {
            // Nach einem Neustart während der Rückmeldung: Antwort ist gespeichert, weiter zur nächsten Frage.
            if session.currentAnswered == true { model.advanceQuestion() }
            resetInputs()
        }
        .sensoryFeedback(trigger: evaluation?.verdict) { _, new in
            switch new {
            case .some(.correct): return .success
            case .some(.incorrect): return .error
            default: return nil
            }
        }
    }

    // MARK: - Teile

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frage \(min(session.currentIndex + 1, session.questionIDs.count)) von \(session.questionIDs.count)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let remaining = session.remainingSeconds(at: context.date) {
                        Label(timeString(remaining), systemImage: "timer")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(remaining < 120 ? Theme.warning : .secondary)
                            .onChange(of: remaining <= 0) { _, ended in if ended { onFinish() } }
                    } else {
                        Label(timeString(session.activeSeconds(at: context.date)), systemImage: "clock")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            LinearBar(fraction: Double(session.currentIndex) / Double(max(session.questionIDs.count, 1)))
            if isSimulation {
                Text("Wie in der echten Prüfung: Lösungen und Auswertung gibt es am Ende.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var breakSuggestion: some View {
        if !dismissedBreak && session.suggestsBreak(at: Date(), sessionMinutes: model.state.preferences.sessionMinutes) {
            Card {
                CardTitle(title: "Zeit für eine kurze Pause?", symbol: "cup.and.saucer")
                Text("Du lernst schon eine Weile konzentriert. Eine Pause von 5 Minuten hilft beim Behalten.").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("5 Min. Pause") { model.startBreak(minutes: 5) }.buttonStyle(SecondaryButtonStyle())
                    Button("Weiterlernen") { dismissedBreak = true }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func hint(_ source: SourceReference) -> some View {
        let document = model.state.documents.first { $0.id == source.documentID }
        let chunk = model.chunk(for: source)
        return Card {
            Label("Hinweis", systemImage: "lightbulb").font(.headline)
            Text("Die Antwort steht in „\(document?.fileName ?? "deinen Unterlagen")“\(source.page.map { ", Seite \($0)" } ?? "")\(chunk.map { " im Abschnitt „\($0.sectionPath.last ?? "")“" } ?? "").")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Mit Hinweis zählt die Antwort nur halb für deinen Wissensstand.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func answerButtons(_ question: Question) -> some View {
        Button {
            Task { await submit(selfRating: nil) }
        } label: {
            if isEvaluating { ProgressView().tint(.white) } else { Text(isSimulation ? (isLast ? "Abgeben" : "Weiter") : "Antwort prüfen") }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!hasAnswer(question) || isEvaluating)
        HStack {
            if !isSimulation && !usedHint && question.source != nil {
                Button("Hinweis anzeigen") { usedHint = true; showHint = true }.font(.footnote)
            }
            Spacer()
            Button(isSimulation ? "Überspringen" : "Weiß ich nicht") {
                Task { await submitUnknown(question) }
            }
            .font(.footnote)
        }
    }

    // MARK: - Ablauf

    private var isLast: Bool { session.currentIndex + 1 >= session.questionIDs.count }

    private func hasAnswer(_ q: Question) -> Bool {
        switch q.kind {
        case .multipleChoice, .trueFalse: return !selected.isEmpty
        case .matching: return !matching.isEmpty && matching.allSatisfy { $0 != nil }
        default: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func response(selfRating: Double?) -> AttemptResponse {
        AttemptResponse(selectedIndices: selected.isEmpty ? nil : selected.sorted(), text: text.isEmpty ? nil : text,
                        matching: matching.isEmpty ? nil : matching.map { $0 ?? -1 }, selfRating: selfRating)
    }

    private func answerText(_ q: Question) -> String? {
        switch q.kind {
        case .multipleChoice, .trueFalse: return selected.sorted().compactMap { q.options.indices.contains($0) ? q.options[$0] : nil }.joined(separator: ", ")
        case .matching: return nil
        default: return text
        }
    }

    private func submit(selfRating: Double?) async {
        guard let question else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        let r = response(selfRating: selfRating)
        let result = await model.evaluate(question, response: r)
        if result.verdict == .needsReview {
            if isSimulation {
                // In der Simulation keine Selbsteinschätzung zwischendurch: offen bewertet als "nicht prüfbar" mit halber Gewichtung.
                let neutral = AnswerEvaluation(score: 0.5, verdict: .partial, feedback: "", correctAnswer: question.referenceAnswer ?? "", tags: ["unrated"], chosenDistractor: nil, grading: .selfAssessed)
                record(question, r, neutral, advance: true)
            } else {
                pendingSelfRating = true
            }
            return
        }
        pendingSelfRating = false
        record(question, r, result, advance: isSimulation)
        if !isSimulation { evaluation = result }
    }

    private func submitUnknown(_ question: Question) async {
        let r = AttemptResponse(text: "")
        let result = AnswerEvaluation(score: 0, verdict: .incorrect, feedback: "Kein Problem – sieh dir die Lösung an. Beim nächsten Mal sitzt es besser.",
                                      correctAnswer: correctAnswerText(question), tags: ["unknown"], chosenDistractor: nil, grading: .automatic)
        record(question, r, result, advance: isSimulation)
        if !isSimulation { evaluation = result }
    }

    private func record(_ question: Question, _ r: AttemptResponse, _ e: AnswerEvaluation, advance: Bool) {
        model.record(question, response: r, evaluation: e, usedHint: usedHint, seconds: Date().timeIntervalSince(questionStart), advance: advance)
    }

    /// Nach der Rückmeldung zur nächsten Frage; nach der letzten folgt die Auswertung.
    private func advance() {
        model.advanceQuestion()
        resetInputs()
    }

    private func resetInputs() {
        selected = []
        text = ""
        evaluation = nil
        pendingSelfRating = false
        usedHint = false
        showHint = false
        questionStart = Date()
        matching = Array(repeating: nil, count: question?.pairs.count ?? 0)
    }

    private func correctAnswerText(_ q: Question) -> String {
        switch q.kind {
        case .multipleChoice, .trueFalse: return q.correctOptionIndices.compactMap { q.options.indices.contains($0) ? q.options[$0] : nil }.joined(separator: ", ")
        case .numeric: return q.numeric.map { "\($0.value) \($0.unit ?? "")" } ?? ""
        case .matching: return q.pairs.map { "\($0.left) → \($0.right)" }.joined(separator: "; ")
        default: return q.acceptedAnswers.first ?? q.referenceAnswer ?? ""
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Darstellung und Eingabe je Aufgabenformat.
struct QuestionCard: View {
    let question: Question
    @Binding var selected: Set<Int>
    @Binding var text: String
    @Binding var matching: [Int?]
    let locked: Bool

    var body: some View {
        Card {
            HStack {
                Pill(text: question.kind.title, tint: .secondary)
                Pill(text: question.difficulty.title, tint: .secondary)
                if question.isTransfer { Pill(text: "Transfer", symbol: "arrow.triangle.branch", tint: .purple) }
                Spacer()
            }
            Text(question.prompt).font(.title3).fixedSize(horizontal: false, vertical: true)
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        switch question.kind {
        case .multipleChoice, .trueFalse:
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        guard !locked else { return }
                        if question.correctOptionIndices.count > 1 {
                            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                        } else {
                            selected = [index]
                        }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(index) ? "largecircle.fill.circle" : "circle")
                            Text(option).multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(12)
                        .frame(minHeight: 44)
                        .background(selected.contains(index) ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                }
            }
        case .cloze, .shortAnswer:
            TextField("Deine Antwort", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(locked)
        case .numeric:
            VStack(alignment: .leading, spacing: 4) {
                TextField("Ergebnis mit Einheit, z. B. 3,5 m", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .disabled(locked)
                if let unit = question.numeric?.unit, !unit.isEmpty {
                    Text("Denk an die Einheit.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .freeText:
            TextField("Erkläre in eigenen Worten …", text: $text, axis: .vertical)
                .lineLimit(4...10)
                .textFieldStyle(.roundedBorder)
                .disabled(locked)
        case .matching:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(question.pairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.left).font(.headline)
                        Menu {
                            ForEach(shuffledRightIndices, id: \.self) { rightIndex in
                                Button(question.pairs[rightIndex].right) {
                                    if matching.indices.contains(index) { matching[index] = rightIndex }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedRight(index) ?? "Zuordnung wählen").multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .padding(10)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(locked)
                    }
                }
            }
        }
    }

    private var shuffledRightIndices: [Int] {
        var rng = SeededGenerator(question.id.uuidString)
        return Array(question.pairs.indices).shuffled(using: &rng)
    }

    private func selectedRight(_ index: Int) -> String? {
        guard matching.indices.contains(index), let right = matching[index], question.pairs.indices.contains(right) else { return nil }
        return question.pairs[right].right
    }
}
