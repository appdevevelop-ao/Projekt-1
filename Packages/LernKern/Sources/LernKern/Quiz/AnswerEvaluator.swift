import Foundation

public struct AnswerEvaluation: Hashable, Sendable {
    public enum Verdict: String, Hashable, Sendable {
        case correct
        case partial
        case incorrect
        /// Offene Antwort – braucht KI-Bewertung oder Selbsteinschätzung.
        case needsReview
    }

    public var score: Double
    public var verdict: Verdict
    public var feedback: String
    public var correctAnswer: String
    public var tags: [String]
    public var chosenDistractor: String?
    public var grading: GradingMethod

    public init(score: Double, verdict: Verdict, feedback: String, correctAnswer: String, tags: [String], chosenDistractor: String?, grading: GradingMethod) {
        self.score = score
        self.verdict = verdict
        self.feedback = feedback
        self.correctAnswer = correctAnswer
        self.tags = tags
        self.chosenDistractor = chosenDistractor
        self.grading = grading
    }
}

/// Automatische Bewertung aller nicht-offenen Aufgabenformate.
public enum AnswerEvaluator {
    public static func evaluate(_ question: Question, response: AttemptResponse) -> AnswerEvaluation {
        switch question.kind {
        case .multipleChoice, .trueFalse:
            return evaluateChoice(question, response)
        case .cloze, .shortAnswer:
            return evaluateText(question, response)
        case .numeric:
            return evaluateNumeric(question, response)
        case .matching:
            return evaluateMatching(question, response)
        case .freeText:
            if let rating = response.selfRating {
                let score = MathUtil.clamp(rating, 0, 1)
                return AnswerEvaluation(score: score, verdict: verdict(for: score), feedback: "Selbsteinschätzung übernommen.",
                                        correctAnswer: question.referenceAnswer ?? "", tags: ["selfAssessed"], chosenDistractor: nil, grading: .selfAssessed)
            }
            return AnswerEvaluation(score: 0, verdict: .needsReview, feedback: "Diese Antwort wird inhaltlich bewertet.",
                                    correctAnswer: question.referenceAnswer ?? "", tags: [], chosenDistractor: nil, grading: .selfAssessed)
        }
    }

    static func verdict(for score: Double) -> AnswerEvaluation.Verdict {
        score >= 0.8 ? .correct : (score >= 0.4 ? .partial : .incorrect)
    }

    static func evaluateChoice(_ q: Question, _ r: AttemptResponse) -> AnswerEvaluation {
        let selected = Set(r.selectedIndices ?? [])
        let correct = Set(q.correctOptionIndices)
        let correctText = q.correctOptionIndices.compactMap { q.options.indices.contains($0) ? q.options[$0] : nil }.joined(separator: ", ")
        let score: Double
        if correct.count <= 1 {
            score = selected == correct ? 1 : 0
        } else {
            let hits = Double(selected.intersection(correct).count)
            let wrong = Double(selected.subtracting(correct).count)
            score = max(0, (hits - wrong) / Double(correct.count))
        }
        let distractor = selected.subtracting(correct).sorted().first.flatMap { q.options.indices.contains($0) ? q.options[$0] : nil }
        let feedback = score >= 1 ? "Richtig." : (score > 0 ? "Teilweise richtig." : "Leider falsch.")
        return AnswerEvaluation(score: score, verdict: verdict(for: score), feedback: feedback, correctAnswer: correctText,
                                tags: [], chosenDistractor: distractor, grading: .automatic)
    }

    static func evaluateText(_ q: Question, _ r: AttemptResponse) -> AnswerEvaluation {
        let answer = TextNormalizer.normalize(r.text ?? "", dropArticles: true)
        let accepted = (q.acceptedAnswers.isEmpty ? [q.referenceAnswer ?? ""] : q.acceptedAnswers).filter { !$0.isEmpty }
        let display = accepted.first ?? ""
        guard !answer.isEmpty else {
            return AnswerEvaluation(score: 0, verdict: .incorrect, feedback: "Keine Antwort eingegeben.", correctAnswer: display, tags: ["empty"], chosenDistractor: nil, grading: .automatic)
        }
        // Tippfehler-Toleranz nach Wortlänge: bis 4 Zeichen keine, bis 9 Zeichen 1, darüber 2 Fehler.
        var bestOutcome: (score: Double, tag: String?) = (0, nil)
        for candidate in accepted {
            let c = TextNormalizer.normalize(candidate, dropArticles: true)
            if c == answer { bestOutcome = (1, nil); break }
            let allowed = c.count <= 4 ? 0 : (c.count <= 9 ? 1 : 2)
            let d = TextNormalizer.distance(c, answer)
            if d <= allowed { bestOutcome = (1, "typo") }
            else if bestOutcome.score < 0.5, c.count > 6, d <= allowed + 1 { bestOutcome = (0.5, "nearMiss") }
        }
        if bestOutcome.score >= 1 {
            if bestOutcome.tag == "typo" {
                return AnswerEvaluation(score: 1, verdict: .correct, feedback: "Richtig (kleiner Schreibfehler – korrekt: „\(display)“).", correctAnswer: display, tags: ["typo"], chosenDistractor: nil, grading: .automatic)
            }
            return AnswerEvaluation(score: 1, verdict: .correct, feedback: "Richtig.", correctAnswer: display, tags: [], chosenDistractor: nil, grading: .automatic)
        }
        if bestOutcome.score >= 0.5 {
            return AnswerEvaluation(score: 0.5, verdict: .partial, feedback: "Fast – gemeint war „\(display)“.", correctAnswer: display, tags: ["nearMiss"], chosenDistractor: nil, grading: .automatic)
        }
        return AnswerEvaluation(score: 0, verdict: .incorrect, feedback: "Leider falsch.", correctAnswer: display, tags: [], chosenDistractor: nil, grading: .automatic)
    }

    static func evaluateNumeric(_ q: Question, _ r: AttemptResponse) -> AnswerEvaluation {
        guard let expected = q.numeric else {
            return evaluateText(q, r)
        }
        let correctText = format(expected.value) + (expected.unit.map { " \($0)" } ?? "")
        guard let parsed = NumberParser.parse(r.text ?? "") else {
            return AnswerEvaluation(score: 0, verdict: .incorrect, feedback: "Bitte gib eine Zahl ein (z. B. 3,5 m).", correctAnswer: correctText, tags: ["unparsable"], chosenDistractor: nil, grading: .automatic)
        }
        var value = parsed.value
        var tags: [String] = []
        var unitPenalty = 0.0
        var unitNote = ""
        if let expectedUnit = expected.unit, !expectedUnit.isEmpty {
            if let givenUnit = parsed.unit {
                if let e = UnitTable.info(for: expectedUnit), let g = UnitTable.info(for: givenUnit) {
                    if e.dimension == g.dimension {
                        value = parsed.value * g.factor / e.factor
                    } else {
                        unitPenalty = 0.5
                        tags.append("unitWrong")
                        unitNote = " Die Einheit passt nicht (erwartet: \(expectedUnit))."
                    }
                } else if TextNormalizer.normalize(givenUnit) != TextNormalizer.normalize(expectedUnit) {
                    unitPenalty = 0.5
                    tags.append("unitWrong")
                    unitNote = " Die Einheit passt nicht (erwartet: \(expectedUnit))."
                }
            } else {
                unitPenalty = 0.5
                tags.append("unitMissing")
                unitNote = " Die Einheit fehlt (\(expectedUnit))."
            }
        }
        let tolerance = expected.absoluteTolerance ?? max(abs(expected.value) * expected.relativeTolerance, 1e-9)
        let valueOK = abs(value - expected.value) <= tolerance
        if !valueOK {
            // Häufiger Fehler: richtige Ziffern, falsche Größenordnung
            let ratio = expected.value != 0 ? value / expected.value : 0
            let magnitudeError = ratio != 0 && [10.0, 100, 1000, 0.1, 0.01, 0.001].contains { abs(ratio - $0) / $0 < 0.01 }
            if magnitudeError { tags.append("magnitude") }
            return AnswerEvaluation(score: 0, verdict: .incorrect,
                                    feedback: magnitudeError ? "Die Ziffern stimmen, aber die Größenordnung nicht – prüfe Einheiten und Kommastellen." : "Das Ergebnis stimmt nicht.",
                                    correctAnswer: correctText, tags: tags, chosenDistractor: nil, grading: .automatic)
        }
        let score = 1 - unitPenalty
        return AnswerEvaluation(score: score, verdict: verdict(for: score), feedback: (score >= 1 ? "Richtig." : "Der Zahlenwert stimmt.") + unitNote,
                                correctAnswer: correctText, tags: tags, chosenDistractor: nil, grading: .automatic)
    }

    static func evaluateMatching(_ q: Question, _ r: AttemptResponse) -> AnswerEvaluation {
        let mapping = r.matching ?? []
        let total = q.pairs.count
        let correctText = q.pairs.map { "\($0.left) → \($0.right)" }.joined(separator: "; ")
        guard total > 0 else {
            return AnswerEvaluation(score: 0, verdict: .incorrect, feedback: "", correctAnswer: correctText, tags: [], chosenDistractor: nil, grading: .automatic)
        }
        var hits = 0
        for i in 0..<total where i < mapping.count && mapping[i] == i { hits += 1 }
        let score = Double(hits) / Double(total)
        let feedback = hits == total ? "Alles richtig zugeordnet." : "\(hits) von \(total) richtig zugeordnet."
        return AnswerEvaluation(score: score, verdict: verdict(for: score), feedback: feedback, correctAnswer: correctText, tags: [], chosenDistractor: nil, grading: .automatic)
    }

    /// Welche Kernpunkte einer Rubrik eine freie Antwort erkennbar enthält (Hilfe zur Selbsteinschätzung, keine Note).
    public static func rubricCoverage(answer: String, rubric: [String]) -> (covered: [String], missing: [String]) {
        let answerTokens = Set(TextNormalizer.contentTokens(answer))
        var covered: [String] = []
        var missing: [String] = []
        for point in rubric {
            let pointTokens = Set(TextNormalizer.contentTokens(point))
            guard !pointTokens.isEmpty else { continue }
            let matched = pointTokens.filter { token in
                answerTokens.contains(token) || answerTokens.contains { $0.count >= 5 && token.count >= 5 && (TextNormalizer.similarity($0, token) >= 0.8 || $0.hasPrefix(String(token.prefix(5)))) }
            }
            if Double(matched.count) / Double(pointTokens.count) >= 0.5 { covered.append(point) } else { missing.append(point) }
        }
        return (covered, missing)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e12 { return String(Int(value)) }
        var s = String(format: "%.4g", value)
        s = s.replacingOccurrences(of: ".", with: ",")
        return s
    }
}
