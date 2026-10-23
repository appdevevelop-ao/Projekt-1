import Foundation

/// Grund, warum ein KI-Vorschlag verworfen wurde (für Protokoll und Qualitätsanzeige).
public struct AIRejection: Hashable, Sendable {
    public var item: String
    public var reason: String
}

/// Validiert strukturierte KI-Ausgaben, bevor sie in die App gelangen.
///
/// Schutz gegen Halluzinationen und unvollständige Antworten:
/// - Jede Frage/jedes Lernziel muss auf einen gesendeten Abschnitt verweisen.
/// - Das Belegzitat muss im Abschnitt tatsächlich vorkommen.
/// - Aufgabenformate werden strukturell geprüft (z. B. genau eine richtige Option).
/// - Doppelte Fragen werden verworfen.
/// - KI-Inhalte werden als "Vorschlag" gekennzeichnet.
public enum AIResponseValidator {
    public struct CurriculumResult: Sendable {
        public var topics: [Topic]
        public var objectives: [LearningObjective]
        public var terms: [KeyTerm]
        public var rejections: [AIRejection]
        public var warnings: [String]
    }

    public static func curriculum(_ response: AIContracts.AnalyzeResponse, examID: UUID, chunks: [SourceChunk], existingTopics: [Topic], orderOffset: Int) -> CurriculumResult {
        let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id.uuidString, $0) })
        var rejections: [AIRejection] = []
        var topics: [Topic] = []
        var objectives: [LearningObjective] = []
        var terms: [KeyTerm] = []
        var topicTitleToID: [String: UUID] = Dictionary(uniqueKeysWithValues: existingTopics.map { (TextNormalizer.normalize($0.title), $0.id) })

        for (i, t) in response.topics.enumerated() {
            let title = clean(t.title, max: 120)
            guard !title.isEmpty else { rejections.append(AIRejection(item: "Thema", reason: "Leerer Titel")); continue }
            var validObjectives: [LearningObjective] = []
            let key = TextNormalizer.normalize(title)
            let topicID = topicTitleToID[key] ?? UUID()
            for (j, o) in t.objectives.enumerated() {
                let referenced = o.chunkIds.compactMap { chunkByID[$0] }
                guard !referenced.isEmpty else {
                    rejections.append(AIRejection(item: o.title, reason: "Kein gültiger Quellabschnitt angegeben"))
                    continue
                }
                guard referenced.contains(where: { QuoteVerifier.isSupported(quote: o.evidenceQuote, by: $0.text) }) else {
                    rejections.append(AIRejection(item: o.title, reason: "Beleg steht nicht im Material"))
                    continue
                }
                let objectiveTitle = clean(o.title, max: 140)
                guard !objectiveTitle.isEmpty else { continue }
                if validObjectives.contains(where: { TextNormalizer.similarity(TextNormalizer.normalize($0.title), TextNormalizer.normalize(objectiveTitle)) >= 0.9 }) { continue }
                validObjectives.append(LearningObjective(
                    examID: examID, topicID: topicID, title: objectiveTitle, detail: clean(o.description, max: 400),
                    bloom: BloomLevel(rawValue: o.bloom) ?? .understand,
                    keyTerms: o.keyTerms.map { clean($0, max: 60) }.filter { !$0.isEmpty }.prefix(8).map { $0 },
                    sourceChunkIDs: referenced.map(\.id), importance: Importance(rawValue: t.importance) ?? .standard,
                    origin: .ai, reviewStatus: .suggested, estimatedMinutes: nil, order: j))
            }
            guard !validObjectives.isEmpty else {
                rejections.append(AIRejection(item: title, reason: "Thema ohne belegte Lernziele"))
                continue
            }
            objectives.append(contentsOf: validObjectives)
            if topicTitleToID[key] == nil {
                topicTitleToID[key] = topicID
                topics.append(Topic(
                    id: topicID, examID: examID, title: title, summary: clean(t.summary, max: 400), order: orderOffset + i,
                    importance: Importance(rawValue: t.importance) ?? .standard, difficulty: min(max(t.difficulty, 1), 3),
                    prerequisiteTopicIDs: [], origin: .ai, reviewStatus: .suggested,
                    sourceChunkIDs: Array(Set(validObjectives.flatMap(\.sourceChunkIDs)))))
            }
        }
        // Voraussetzungen über Titel auflösen
        for (index, t) in topics.enumerated() {
            guard let source = response.topics.first(where: { clean($0.title, max: 120) == t.title }) else { continue }
            topics[index].prerequisiteTopicIDs = source.prerequisites.compactMap { topicTitleToID[TextNormalizer.normalize($0)] }.filter { $0 != t.id }
        }

        for term in response.terms {
            guard let chunk = chunkByID[term.chunkId] else { rejections.append(AIRejection(item: term.term, reason: "Unbekannter Abschnitt")); continue }
            guard QuoteVerifier.isSupported(quote: term.quote, by: chunk.text) else { rejections.append(AIRejection(item: term.term, reason: "Definition nicht im Material belegt")); continue }
            let name = clean(term.term, max: 80)
            guard !name.isEmpty, !term.definition.isEmpty else { continue }
            let objective = objectives.first { $0.keyTerms.contains { TextNormalizer.normalize($0) == TextNormalizer.normalize(name) } }
                ?? objectives.first { $0.sourceChunkIDs.contains(chunk.id) }
            terms.append(KeyTerm(examID: examID, topicID: objective?.topicID, objectiveID: objective?.id, term: name,
                                 definition: clean(term.definition, max: 500), kind: KeyTerm.Kind(rawValue: term.kind) ?? .definition,
                                 source: SourceReference(documentID: chunk.documentID, chunkID: chunk.id, page: chunk.pageStart, quote: term.quote)))
        }
        return CurriculumResult(topics: topics, objectives: objectives, terms: terms, rejections: rejections, warnings: response.warnings.map { clean($0, max: 300) })
    }

    public struct QuestionResult: Sendable {
        public var questions: [Question]
        public var rejections: [AIRejection]
        public var insufficientMaterial: Bool
    }

    public static func questions(_ response: AIContracts.QuestionsResponse, objective: LearningObjective, chunks: [SourceChunk], existing: [Question]) -> QuestionResult {
        let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id.uuidString, $0) })
        var accepted: [Question] = []
        var rejections: [AIRejection] = []
        let existingPrompts = existing.map { TextNormalizer.normalize($0.prompt) }

        for g in response.questions {
            let label = String(g.prompt.prefix(60))
            func reject(_ reason: String) { rejections.append(AIRejection(item: label, reason: reason)) }
            guard let kind = QuestionKind(rawValue: g.kind) else { reject("Unbekanntes Aufgabenformat"); continue }
            guard let difficulty = Difficulty(rawValue: g.difficulty) else { reject("Unbekannte Schwierigkeit"); continue }
            let prompt = clean(g.prompt, max: 1_200)
            guard prompt.count >= 8 else { reject("Fragetext zu kurz"); continue }
            guard let chunk = chunkByID[g.chunkId] else { reject("Kein gültiger Quellabschnitt"); continue }
            guard QuoteVerifier.isSupported(quote: g.sourceQuote, by: chunk.text) else { reject("Beleg steht nicht im Material"); continue }
            let normalized = TextNormalizer.normalize(prompt)
            if existingPrompts.contains(where: { TextNormalizer.similarity($0, normalized) >= 0.9 })
                || accepted.contains(where: { TextNormalizer.similarity(TextNormalizer.normalize($0.prompt), normalized) >= 0.9 }) {
                reject("Doppelte Frage")
                continue
            }
            var question = Question(
                examID: objective.examID, objectiveID: objective.id, kind: kind, prompt: prompt,
                explanation: clean(g.explanation, max: 1_500),
                simplerExplanation: g.simplerExplanation.isEmpty ? nil : clean(g.simplerExplanation, max: 1_500),
                commonMistakes: g.commonMistakes.map { clean($0, max: 300) }.filter { !$0.isEmpty },
                difficulty: difficulty, isTransfer: g.isTransfer,
                source: SourceReference(documentID: chunk.documentID, chunkID: chunk.id, page: chunk.pageStart, quote: g.sourceQuote),
                origin: .ai, status: .active)

            switch kind {
            case .multipleChoice:
                let options = g.options.map { clean($0, max: 300) }
                guard (2...6).contains(options.count), Set(options.map { TextNormalizer.normalize($0) }).count == options.count else { reject("Antwortoptionen ungültig"); continue }
                guard g.correctOptionIndices.count == 1, options.indices.contains(g.correctOptionIndices[0]) else { reject("Genau eine richtige Option nötig"); continue }
                question.options = options
                question.correctOptionIndices = g.correctOptionIndices
            case .trueFalse:
                guard g.correctOptionIndices.count == 1, [0, 1].contains(g.correctOptionIndices[0]) else { reject("Richtig/Falsch ungültig"); continue }
                question.options = ["Richtig", "Falsch"]
                question.correctOptionIndices = g.correctOptionIndices
            case .cloze, .shortAnswer:
                let answers = g.acceptedAnswers.map { clean($0, max: 120) }.filter { !$0.isEmpty }
                guard !answers.isEmpty else { reject("Keine Musterantwort"); continue }
                if kind == .cloze, !prompt.contains("___") { reject("Lücke fehlt"); continue }
                if answers.contains(where: { prompt.localizedCaseInsensitiveContains($0) && $0.count > 3 }) { reject("Lösung steht im Fragetext"); continue }
                question.acceptedAnswers = answers
            case .numeric:
                guard let n = g.numeric, n.value.isFinite else { reject("Zahlenwert fehlt"); continue }
                question.numeric = NumericAnswer(value: n.value, unit: n.unit.isEmpty ? nil : n.unit, relativeTolerance: MathUtil.clamp(n.relativeTolerance, 0.0001, 0.1))
            case .matching:
                let pairs = g.pairs.map { MatchPair(left: clean($0.left, max: 200), right: clean($0.right, max: 300)) }
                guard (2...6).contains(pairs.count), Set(pairs.map(\.left)).count == pairs.count, Set(pairs.map(\.right)).count == pairs.count else { reject("Zuordnung ungültig"); continue }
                question.pairs = pairs
            case .freeText:
                guard !g.referenceAnswer.isEmpty, !g.rubric.isEmpty else { reject("Musterlösung oder Bewertungskriterien fehlen"); continue }
                question.referenceAnswer = clean(g.referenceAnswer, max: 1_500)
                question.rubric = g.rubric.map { clean($0, max: 300) }.filter { !$0.isEmpty }
            }
            if kind != .freeText, !g.referenceAnswer.isEmpty { question.referenceAnswer = clean(g.referenceAnswer, max: 1_500) }
            question.points = Question.defaultPoints(kind: kind, difficulty: difficulty)
            accepted.append(question)
        }
        return QuestionResult(questions: accepted, rejections: rejections, insufficientMaterial: response.insufficientMaterial)
    }

    public static func grade(_ response: AIContracts.GradeResponse) -> AnswerEvaluation? {
        guard response.score.isFinite, !response.feedback.isEmpty else { return nil }
        let score = MathUtil.clamp(response.score, 0, 1)
        // Urteil und Punktzahl müssen zueinander passen; im Zweifel zählt die vorsichtigere Lesart.
        var verdict: AnswerEvaluation.Verdict
        switch response.verdict {
        case "correct": verdict = score >= 0.8 ? .correct : .partial
        case "partial": verdict = .partial
        default: verdict = .incorrect
        }
        if verdict == .incorrect && score >= 0.4 { verdict = .partial }
        let confidence = GradingConfidence(rawValue: response.confidence) ?? .low
        var feedback = clean(response.feedback, max: 1_500)
        if !response.missingPoints.isEmpty {
            feedback += "\nNoch nicht enthalten: " + response.missingPoints.map { clean($0, max: 200) }.joined(separator: "; ")
        }
        if confidence == .low { feedback += "\n(Die Bewertung ist unsicher – vergleiche selbst mit der Musterlösung.)" }
        return AnswerEvaluation(score: score, verdict: verdict, feedback: feedback, correctAnswer: "",
                                tags: confidence == .low ? ["aiLowConfidence"] : [], chosenDistractor: nil,
                                grading: GradingMethod(kind: .ai, confidence: confidence))
    }

    static func clean(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)) : t
    }
}

/// Fasst die Abschnitte in KI-Anfragen sinnvoller Größe zusammen.
public enum AIBatcher {
    public static func batches(_ chunks: [SourceChunk], maxCharacters: Int = 14_000, maxChunks: Int = 10) -> [[SourceChunk]] {
        var result: [[SourceChunk]] = []
        var current: [SourceChunk] = []
        var size = 0
        for chunk in chunks where chunk.duplicateOf == nil {
            if !current.isEmpty && (size + chunk.text.count > maxCharacters || current.count >= maxChunks) {
                result.append(current)
                current = []
                size = 0
            }
            current.append(chunk)
            size += chunk.text.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
