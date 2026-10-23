import Foundation

/// Erzeugt Übungsfragen OHNE KI ausschließlich aus belegten Begriffen und Sätzen des Materials.
///
/// Je Begriff entstehen mehrere Formulierungen (Wiedererkennen, Lückentext, freier Abruf,
/// Richtig/Falsch, schwerer Lückentext zum Inhalt), damit das Kriterium
/// "unterschiedliche Formulierungen" erfüllbar ist. Jede Frage verweist auf ihre Quelle.
public enum LocalQuestionGenerator {
    public static func questions(for objective: LearningObjective, terms: [KeyTerm], allTerms: [KeyTerm], chunks: [SourceChunk], existing: [Question]) -> [Question] {
        var result: [Question] = []
        let existingKeys = Set(existing.map { TextNormalizer.normalize($0.prompt) })
        func add(_ q: Question) {
            let key = TextNormalizer.normalize(q.prompt)
            guard !existingKeys.contains(key), !result.contains(where: { TextNormalizer.normalize($0.prompt) == key }) else { return }
            result.append(q)
        }

        let objectiveTerms = terms.filter { $0.objectiveID == objective.id || objective.keyTerms.contains($0.term) }
        for term in objectiveTerms {
            let pool = allTerms.filter { TextNormalizer.normalize($0.term) != TextNormalizer.normalize(term.term) && $0.kind == term.kind }
            let sameTopic = pool.filter { $0.topicID == term.topicID }
            let distractors = Array((sameTopic + pool.filter { $0.topicID != term.topicID }).prefix(12))
            let group = "term:\(StableHash.fnv1a(term.term))"
            let explanation = explanationText(term)
            var rng = SeededGenerator(term.term + objective.id.uuidString)

            if term.kind == .formula {
                if let q = formulaCloze(term, objective: objective, explanation: explanation, group: group) { add(q) }
                continue
            }

            let masked = mask(term.term, in: term.definition)
            // 1. Begriff erkennen (MC)
            if distractors.count >= 2 {
                var options = [term.term] + distractors.shuffled(using: &rng).prefix(3).map(\.term)
                options = Array(Set(options.map { $0 })).sorted()
                options.shuffle(using: &rng)
                if let correct = options.firstIndex(of: term.term) {
                    add(Question(examID: objective.examID, objectiveID: objective.id, kind: .multipleChoice,
                                 prompt: "Welcher Begriff passt zu dieser Beschreibung?\n„\(masked)“",
                                 options: options, correctOptionIndices: [correct],
                                 explanation: explanation, difficulty: sameTopic.count >= 2 ? .medium : .easy,
                                 source: term.source, origin: .local, variantGroup: group))
                }
            }
            // 2. Freier Abruf des Begriffs (Lückentext ohne Optionen)
            add(Question(examID: objective.examID, objectiveID: objective.id, kind: .cloze,
                         prompt: "Ergänze den Fachbegriff:\n„\(mask(term.term, in: term.source.quote ?? term.definition, placeholder: "___"))“",
                         acceptedAnswers: [term.term], explanation: explanation, difficulty: .medium,
                         source: term.source, origin: .local, variantGroup: group))
            // 3. Bedeutung erkennen (MC mit Definitionen)
            if distractors.count >= 2 {
                let correctText = optionText(term.definition)
                var options = [correctText] + distractors.shuffled(using: &rng).prefix(3).map { optionText(mask($0.term, in: $0.definition)) }
                options = Array(Set(options)).sorted()
                options.shuffle(using: &rng)
                if let correct = options.firstIndex(of: correctText) {
                    add(Question(examID: objective.examID, objectiveID: objective.id, kind: .multipleChoice,
                                 prompt: "Was beschreibt „\(term.term)“ laut deinen Unterlagen?",
                                 options: options, correctOptionIndices: [correct], explanation: explanation,
                                 difficulty: .medium, source: term.source, origin: .local, variantGroup: group))
                }
            }
            // 4. Richtig oder falsch (absichtlich mit fremder Definition, wenn vorhanden)
            if let other = distractors.first, Bool.random(using: &rng) {
                add(Question(examID: objective.examID, objectiveID: objective.id, kind: .trueFalse,
                             prompt: "Richtig oder falsch? „\(term.term)“ bezeichnet: \(shorten(mask(other.term, in: other.definition)))",
                             options: ["Richtig", "Falsch"], correctOptionIndices: [1],
                             explanation: "Falsch. " + explanation, difficulty: .easy, source: term.source, origin: .local, variantGroup: group))
            } else {
                add(Question(examID: objective.examID, objectiveID: objective.id, kind: .trueFalse,
                             prompt: "Richtig oder falsch? „\(term.term)“ bezeichnet: \(shorten(masked))",
                             options: ["Richtig", "Falsch"], correctOptionIndices: [0],
                             explanation: "Richtig. " + explanation, difficulty: .easy, source: term.source, origin: .local, variantGroup: group))
            }
            // 5. Schwer: zentrales Inhaltswort der Definition abrufen
            if let hard = contentCloze(term, objective: objective, explanation: explanation, group: group) { add(hard) }
            // 6. Erklären in eigenen Worten (Bewertung per KI oder Selbsteinschätzung)
            add(Question(examID: objective.examID, objectiveID: objective.id, kind: .freeText,
                         prompt: "Erkläre in eigenen Worten: Was bedeutet „\(term.term)“?",
                         referenceAnswer: term.definition, rubric: rubric(from: term.definition),
                         explanation: explanation, difficulty: .hard, source: term.source, origin: .local, variantGroup: group))
        }

        // Vergleichsübung, wenn mehrere Begriffe zum Lernziel gehören
        if objectiveTerms.filter({ $0.kind == .definition }).count >= 3 {
            let pairs = objectiveTerms.filter { $0.kind == .definition }.prefix(4).map { MatchPair(left: $0.term, right: shorten(mask($0.term, in: $0.definition), limit: 90)) }
            add(Question(examID: objective.examID, objectiveID: objective.id, kind: .matching,
                         prompt: "Ordne jedem Begriff die passende Beschreibung zu.", pairs: Array(pairs),
                         explanation: "Die Zuordnungen stammen aus deinen Unterlagen.", difficulty: .medium,
                         source: objectiveTerms.first?.source, origin: .local))
        }

        // Ohne Begriffe: Lückentexte aus aussagekräftigen Sätzen
        if objectiveTerms.isEmpty {
            let relevant = chunks.filter { objective.sourceChunkIDs.contains($0.id) && $0.duplicateOf == nil }
            for q in sentenceClozes(objective: objective, chunks: relevant, corpus: chunks, limit: 4) { add(q) }
        }
        return result
    }

    /// Vergleichsübung für zwei verwechselte Begriffe (Schwächen-Detektor).
    public static func comparison(between a: KeyTerm, and b: KeyTerm, objectiveID: UUID) -> Question {
        Question(examID: a.examID, objectiveID: objectiveID, kind: .matching,
                 prompt: "Vergleiche: Ordne „\(a.term)“ und „\(b.term)“ die richtige Beschreibung zu.",
                 pairs: [MatchPair(left: a.term, right: shorten(mask(a.term, in: a.definition), limit: 110)),
                         MatchPair(left: b.term, right: shorten(mask(b.term, in: b.definition), limit: 110))],
                 explanation: "„\(a.term)“: \(a.definition)\n„\(b.term)“: \(b.definition)",
                 difficulty: .medium, source: a.source, origin: .local, variantGroup: "compare:\(a.term)|\(b.term)")
    }

    // MARK: - Bausteine

    static func explanationText(_ term: KeyTerm) -> String {
        let page = term.source.page.map { " (S. \($0))" } ?? ""
        return "Laut deinen Unterlagen\(page): „\(term.source.quote ?? term.definition)“"
    }

    static func mask(_ term: String, in text: String, placeholder: String = "…") -> String {
        guard !term.isEmpty else { return text }
        var result = text
        let escaped = NSRegularExpression.escapedPattern(for: term)
        if let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\w*", options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: placeholder)
        }
        return result
    }

    static func shorten(_ text: String, limit: Int = 160) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let cut = t.index(t.startIndex, offsetBy: limit)
        let prefix = t[..<cut]
        if let space = prefix.lastIndex(of: " ") { return String(prefix[..<space]) + " …" }
        return String(prefix) + " …"
    }

    /// Einheitliche Schreibweise für Antwortoptionen (keine Hinweise durch Groß-/Kleinschreibung oder Punkt).
    static func optionText(_ text: String) -> String {
        var t = shorten(text).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
    }

    static func rubric(from definition: String) -> [String] {
        let parts = definition.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.components(separatedBy: " und ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { TextNormalizer.contentTokens($0).count >= 1 && $0.count >= 6 }
        return Array(parts.prefix(4))
    }

    static func contentCloze(_ term: KeyTerm, objective: LearningObjective, explanation: String, group: String) -> Question? {
        let termTokens = Set(TextNormalizer.tokens(term.term))
        let words = term.definition.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        guard let key = words.filter({ $0.count >= 6 && !termTokens.contains(TextNormalizer.normalize($0)) && !TextNormalizer.stopwords.contains(TextNormalizer.normalize($0)) })
            .max(by: { $0.count < $1.count }) else { return nil }
        let blanked = mask(key, in: term.definition, placeholder: "___")
        guard blanked != term.definition else { return nil }
        return Question(examID: objective.examID, objectiveID: objective.id, kind: .cloze,
                        prompt: "Ergänze die fehlende Angabe zu „\(term.term)“:\n„\(blanked)“",
                        acceptedAnswers: [key], explanation: explanation, difficulty: .hard,
                        source: term.source, origin: .local, variantGroup: group)
    }

    static func formulaCloze(_ term: KeyTerm, objective: LearningObjective, explanation: String, group: String) -> Question? {
        let line = term.definition
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let rhs = line[line.index(after: eq)...]
        let symbols = rhs.split(whereSeparator: { " +-·*/^×÷()".contains($0) }).map(String.init).filter { !$0.isEmpty }
        guard let target = symbols.last(where: { $0.first?.isLetter == true }) else { return nil }
        var replaced = String(rhs)
        if let r = replaced.range(of: target, options: .backwards) { replaced.replaceSubrange(r, with: "___") }
        return Question(examID: objective.examID, objectiveID: objective.id, kind: .cloze,
                        prompt: "Ergänze die Formel:\n\(line[..<eq])=\(replaced)",
                        acceptedAnswers: [target], explanation: explanation, difficulty: .medium,
                        source: term.source, origin: .local, variantGroup: group)
    }

    static func sentenceClozes(objective: LearningObjective, chunks: [SourceChunk], corpus: [SourceChunk], limit: Int) -> [Question] {
        var result: [Question] = []
        for chunk in chunks {
            let keywords = TermExtractor.keywords(for: chunk, in: corpus, limit: 8)
            for sentence in TermExtractor.sentences(in: chunk.text) where sentence.count >= 60 && sentence.count <= 240 {
                guard let key = keywords.first(where: { sentence.contains($0) && $0.count >= 5 }) else { continue }
                let blanked = mask(key, in: sentence, placeholder: "___")
                guard blanked != sentence else { continue }
                let source = SourceReference(documentID: chunk.documentID, chunkID: chunk.id, page: chunk.pageStart, quote: sentence)
                let page = chunk.pageStart.map { " (S. \($0))" } ?? ""
                let others = keywords.filter { $0 != key }.prefix(3)
                let difficulty: Difficulty = result.count % 2 == 0 ? .medium : .hard
                result.append(Question(examID: objective.examID, objectiveID: objective.id, kind: .cloze,
                                       prompt: "Ergänze den Satz aus deinen Unterlagen:\n„\(blanked)“",
                                       acceptedAnswers: [key], explanation: "Originalsatz\(page): „\(sentence)“",
                                       difficulty: difficulty, source: source, origin: .local, variantGroup: "sentence:\(StableHash.fnv1a(sentence))"))
                if others.count >= 2 {
                    var rng = SeededGenerator(sentence)
                    var options = [key] + others
                    options.shuffle(using: &rng)
                    if let correct = options.firstIndex(of: key) {
                        result.append(Question(examID: objective.examID, objectiveID: objective.id, kind: .multipleChoice,
                                               prompt: "Welches Wort fehlt?\n„\(blanked)“", options: options, correctOptionIndices: [correct],
                                               explanation: "Originalsatz\(page): „\(sentence)“", difficulty: .easy, source: source, origin: .local,
                                               variantGroup: "sentence:\(StableHash.fnv1a(sentence))"))
                    }
                }
                if result.count >= limit * 2 { return result }
                break
            }
        }
        return result
    }
}
