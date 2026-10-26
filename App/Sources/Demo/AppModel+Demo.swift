#if DEBUG
import Foundation
import LernKern

extension AppModel {
    /// Erzeugt ein App-Modell mit realistischem Beispielverlauf – über dieselbe Verarbeitung wie echte Unterlagen.
    static func makeDemo(now: Date = Date()) -> AppModel {
        try? FileManager.default.removeItem(at: DemoMode.directory)
        let model = AppModel(storeDirectory: DemoMode.directory)
        // Keine Routine-Neuplanung mit Hinweis beim Start der Vorführung
        UserDefaults.standard.set(DayKey(now, calendar: model.calendar).description, forKey: "lf.lastRoutineDay")
        if DemoMode.screen != "onboarding" { model.seedDemo(now: now) }
        return model
    }

    /// Testversion: Beispielprüfung mit Lernverlauf direkt aus dem Onboarding anlegen (ersetzt den bisherigen Stand).
    func loadDemoData(now: Date = Date()) {
        UserDefaults.standard.set(DayKey(now, calendar: calendar).description, forKey: "lf.lastRoutineDay")
        seedDemo(now: now)
        banner = Banner(kind: .info, title: "Beispieldaten geladen",
                        message: "Eine Biologie-Prüfung mit Skript und Lernverlauf. Unter Profil → Datenschutz kannst du alles wieder löschen.")
    }

    private func seedDemo(now: Date) {
        let cal = calendar

        let examDay = cal.date(byAdding: .day, value: 12, to: now) ?? now
        let exam = Exam(title: "Biologie – Zellbiologie", examDate: cal.date(bySettingHour: 9, minute: 0, second: 0, of: examDay) ?? examDay,
                        format: .written, durationMinutes: 50, targetGradeID: "2",
                        createdAt: cal.date(byAdding: .day, value: -4, to: now) ?? now)
        var document = SourceDocument(examID: exam.id, fileName: "Skript Zellbiologie.txt", kind: .text)
        guard let extracted = try? DocumentPipeline.extract(data: Data(DemoMode.material.utf8), kind: .text),
              let analysis = try? DocumentPipeline.analyze(extracted, documentID: document.id, kind: .text, existingChunks: []) else { return }
        document.pageCount = analysis.pageCount
        document.characterCount = analysis.characterCount
        document.warnings = analysis.warnings
        document.state = ProcessingState(stage: .completed)
        try? store.saveChunks(analysis.chunks, documentID: document.id)
        chunkCache[document.id] = analysis.chunks
        DemoMode.examID = exam.id

        mutate { state in
            state.exams = [exam]
            state.documents = [document]
            _ = MaterialIntegrator.integrate(&state, document: document, analysis: analysis, aiResult: nil)
            simulateHistory(&state, exam: exam, now: now)
            _ = coach.replan(&state, triggers: [.initial], now: now)
            coach.ensureDailyGoal(&state, now: now)
            state.settings.onboardingCompleted = true
            state.settings.displayName = "Lena"
        }

        if DemoMode.screen == "session" {
            let ids = Array(state.objectives(for: exam.id).suffix(3).map(\.id))
            Task { await startPractice(examID: exam.id, objectiveIDs: ids, kind: .practice) }
        }
    }

    /// Lernverlauf der letzten Tage: Übungen und Überprüfungen mit überwiegend richtigen Antworten.
    private func simulateHistory(_ state: inout AppState, exam: Exam, now: Date) {
        let cal = calendar
        let objectives = state.objectives(for: exam.id)
        guard objectives.count >= 4 else { return }
        let n = objectives.count
        let today = cal.startOfDay(for: now)
        let plan: [(day: Int, range: Range<Int>)] = [
            (-3, 0..<min(4, n)),
            (-2, 0..<min(4, n)),
            (-2, min(4, n)..<min(7, n)),
            (-1, min(4, n)..<min(8, n)),
            (0, 0..<min(3, n)),
        ]
        var answerCount = 0
        for (index, entry) in plan.enumerated() {
            let dayStart = cal.date(byAdding: .day, value: entry.day, to: today) ?? today
            var time: Date
            if entry.day == 0 {
                time = max(dayStart.addingTimeInterval(60), now.addingTimeInterval(-2 * 3600))
            } else {
                time = dayStart.addingTimeInterval(Double(15 * 3600 + index * 1800))
            }
            var attemptIDs: [UUID] = []
            for objective in objectives[entry.range] {
                for question in state.activeQuestions(for: objective.id).prefix(3) {
                    answerCount += 1
                    let correct = answerCount % 6 != 0
                    let response = correct ? Self.demoResponse(for: question) : AttemptResponse(selectedIndices: [99], text: "weiß nicht", matching: [])
                    let evaluation = AnswerEvaluator.evaluate(question, response: response)
                    let attempt = coach.makeAttempt(question: question, response: response, evaluation: evaluation, sessionID: nil, durationSeconds: 40,
                                                    context: .check, usedHint: false, state: state, now: time)
                    state.attempts.append(attempt)
                    attemptIDs.append(attempt.id)
                    time = time.addingTimeInterval(70)
                }
            }
            if !attemptIDs.isEmpty {
                _ = coach.completeCheck(&state, checkID: UUID(), examID: exam.id, taskID: nil, attemptIDs: attemptIDs,
                                        activeMinutes: Double(attemptIDs.count) * 1.2, now: time)
            }
            if entry.day == -1 {
                try? coach.redeem(&state, minutes: 15, now: time.addingTimeInterval(3600))
            }
        }
    }

    private static func demoResponse(for question: Question) -> AttemptResponse {
        switch question.kind {
        case .multipleChoice, .trueFalse:
            return AttemptResponse(selectedIndices: question.correctOptionIndices)
        case .cloze, .shortAnswer:
            return AttemptResponse(text: question.acceptedAnswers.first ?? question.referenceAnswer ?? "")
        case .numeric:
            return AttemptResponse(text: question.numeric.map { "\($0.value) \($0.unit ?? "")" } ?? "")
        case .matching:
            return AttemptResponse(matching: Array(question.pairs.indices))
        case .freeText:
            return AttemptResponse(text: question.referenceAnswer ?? "", selfRating: 0.8)
        }
    }
}
#endif
