import Foundation
@testable import LernKern

/// Kleine Beispielprüfung: 2 Themen, 4 Lernziele, je Lernziel 4 Fragen (leicht, mittel ×2, schwer).
struct Fixture {
    let calendar: Calendar
    var state: AppState
    let exam: Exam
    let topicA: Topic
    let topicB: Topic
    let objectives: [LearningObjective]
    var now: Date

    init(examInDays: Int = 14, prior: PriorKnowledge = .basic, scale: GradeScale = .austrian, target: String = "2", calendar: Calendar = TestCalendar.make()) {
        self.calendar = calendar
        now = calendar.at(2026, 10, 23, 9)
        let exam = Exam(title: "Biologie", examDate: calendar.date(byAdding: .day, value: examInDays, to: calendar.at(2026, 10, 23, 8))!,
                        format: .written, durationMinutes: 60, gradeScale: scale, targetGradeID: target, priorKnowledge: prior)
        self.exam = exam
        topicA = Topic(examID: exam.id, title: "Zellteilung", order: 0, importance: .core, origin: .local, reviewStatus: .confirmed)
        topicB = Topic(examID: exam.id, title: "Genetik", order: 1, importance: .standard, origin: .local, reviewStatus: .confirmed)
        let objs = [
            LearningObjective(examID: exam.id, topicID: topicA.id, title: "Mitose erklären", origin: .local, reviewStatus: .confirmed, order: 0),
            LearningObjective(examID: exam.id, topicID: topicA.id, title: "Meiose erklären", origin: .local, reviewStatus: .confirmed, order: 1),
            LearningObjective(examID: exam.id, topicID: topicB.id, title: "Mendelsche Regeln", origin: .local, reviewStatus: .confirmed, order: 2),
            LearningObjective(examID: exam.id, topicID: topicB.id, title: "DNA-Aufbau", origin: .local, reviewStatus: .confirmed, order: 3),
        ]
        objectives = objs
        var questions: [Question] = []
        for o in objs {
            questions.append(Question(examID: exam.id, objectiveID: o.id, kind: .multipleChoice, prompt: "\(o.title) leicht", options: ["A", "B", "C", "D"], correctOptionIndices: [0], difficulty: .easy, origin: .local))
            questions.append(Question(examID: exam.id, objectiveID: o.id, kind: .cloze, prompt: "\(o.title) mittel 1", acceptedAnswers: ["Antwort"], difficulty: .medium, origin: .local))
            questions.append(Question(examID: exam.id, objectiveID: o.id, kind: .shortAnswer, prompt: "\(o.title) mittel 2", acceptedAnswers: ["Antwort"], difficulty: .medium, origin: .local))
            questions.append(Question(examID: exam.id, objectiveID: o.id, kind: .shortAnswer, prompt: "\(o.title) schwer", acceptedAnswers: ["Antwort"], difficulty: .hard, isTransfer: true, origin: .local))
        }
        state = AppState(exams: [exam], topics: [topicA, topicB], objectives: objs, questions: questions)
    }

    func questions(for objective: LearningObjective) -> [Question] { state.activeQuestions(for: objective.id) }

    /// Beantwortet eine Frage des Lernziels.
    @discardableResult
    mutating func answer(_ objective: LearningObjective, difficulty: Difficulty, index: Int = 0, correct: Bool, at date: Date? = nil, context: AttemptContext = .practice, seconds: Double = 40) -> Attempt {
        let candidates = questions(for: objective).filter { $0.difficulty == difficulty }
        let q = candidates[index % candidates.count]
        let attempt = Attempt(examID: exam.id, objectiveID: objective.id, questionID: q.id, answeredAt: date ?? now,
                              durationSeconds: seconds, score: correct ? 1 : 0, context: context,
                              wasFirstExposure: !state.attempts.contains { $0.questionID == q.id })
        state.attempts.append(attempt)
        return attempt
    }

    /// Bringt ein Lernziel bis "stabil beherrscht": Tag 1 üben, Tag 2 wiederholen inkl. schwerer Aufgabe.
    mutating func master(_ objective: LearningObjective, startingAt start: Date) {
        var t = start
        for (d, i) in [(Difficulty.medium, 0), (.medium, 1), (.easy, 0), (.medium, 0), (.medium, 1), (.medium, 0)] {
            answer(objective, difficulty: d, index: i, correct: true, at: t)
            t = t.addingTimeInterval(120)
        }
        let nextDay = start.addingTimeInterval(26 * 3600)
        answer(objective, difficulty: .medium, index: 1, correct: true, at: nextDay)
        answer(objective, difficulty: .hard, correct: true, at: nextDay.addingTimeInterval(120))
        answer(objective, difficulty: .medium, index: 0, correct: true, at: nextDay.addingTimeInterval(240))
    }
}
