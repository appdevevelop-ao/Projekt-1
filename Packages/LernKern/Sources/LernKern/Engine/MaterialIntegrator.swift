import Foundation

public struct IntegrationSummary: Hashable, Sendable {
    public var newTopics: Int
    public var newObjectives: Int
    public var newTerms: Int
    public var newQuestions: Int
    public var source: AnalysisSource
    public var notes: [String]
}

/// Übernimmt analysiertes Material in den Lernstoff einer Prüfung.
/// Mehrere Dateien einer Prüfung werden zu einem gemeinsamen Lernstoff zusammengeführt.
public enum MaterialIntegrator {
    /// - Parameter aiResult: validiertes KI-Ergebnis (falls verfügbar). Abschnitte, die die KI nicht abdeckt,
    ///   werden mit der lokalen Analyse ergänzt, damit kein Stoff verloren geht.
    public static func integrate(_ state: inout AppState, document: SourceDocument, analysis: DocumentAnalysis,
                                 aiResult: AIResponseValidator.CurriculumResult?) -> IntegrationSummary {
        let examID = document.examID
        let existingTopics = state.topics.filter { $0.examID == examID }
        let orderOffset = (existingTopics.map(\.order).max() ?? -1) + 1
        var topics: [Topic] = []
        var objectives: [LearningObjective] = []
        var terms: [KeyTerm] = []
        var notes: [String] = []
        var source: AnalysisSource = .local

        if let ai = aiResult, !ai.objectives.isEmpty {
            source = .ai
            topics = ai.topics
            objectives = ai.objectives
            terms = ai.terms
            if !ai.rejections.isEmpty {
                notes.append("\(ai.rejections.count) KI-Vorschläge wurden verworfen, weil sie nicht eindeutig im Material belegt waren.")
            }
            // Lücken: Abschnitte ohne KI-Lernziel lokal ergänzen
            let covered = Set(ai.objectives.flatMap(\.sourceChunkIDs))
            let uncovered = analysis.chunks.filter { $0.duplicateOf == nil && !covered.contains($0.id) && $0.text.count >= 300 }
            if !uncovered.isEmpty {
                let uncoveredIDs = Set(uncovered.map(\.id))
                let local = LocalCurriculumBuilder.build(examID: examID, documentID: document.id, sections: analysis.sections, chunks: uncovered,
                                                         extractedTerms: analysis.terms.filter { uncoveredIDs.contains($0.chunkID) },
                                                         existingTopics: existingTopics + topics, orderOffset: orderOffset + topics.count)
                topics += local.topics
                objectives += local.objectives
                terms += local.terms
                notes.append("\(uncovered.count) Abschnitt(e) ohne KI-Lernziel wurden aus der lokalen Analyse ergänzt.")
            }
            // Lokal gefundene Definitionen ergänzen, sofern die KI sie nicht schon hat
            let aiTermKeys = Set(terms.map { TextNormalizer.normalize($0.term) })
            for t in analysis.terms where !aiTermKeys.contains(TextNormalizer.normalize(t.term)) {
                let objective = objectives.first { $0.sourceChunkIDs.contains(t.chunkID) }
                terms.append(KeyTerm(examID: examID, topicID: objective?.topicID, objectiveID: objective?.id, term: t.term, definition: t.definition, kind: t.kind,
                                     source: SourceReference(documentID: document.id, chunkID: t.chunkID, page: analysis.chunks.first { $0.id == t.chunkID }?.pageStart, quote: t.sentence)))
            }
        } else {
            let local = LocalCurriculumBuilder.build(examID: examID, documentID: document.id, sections: analysis.sections, chunks: analysis.chunks,
                                                     extractedTerms: analysis.terms, existingTopics: existingTopics, orderOffset: orderOffset)
            topics = local.topics
            objectives = local.objectives
            terms = local.terms
        }

        // Gleichnamige Themen zusammenführen (z. B. Skript + Folien zum selben Kapitel)
        var remap: [UUID: UUID] = [:]
        var newTopics: [Topic] = []
        for t in topics {
            if let match = (existingTopics + newTopics).first(where: { TextNormalizer.normalize($0.title) == TextNormalizer.normalize(t.title) && $0.id != t.id }) {
                remap[t.id] = match.id
            } else if !existingTopics.contains(where: { $0.id == t.id }) {
                newTopics.append(t)
            }
        }
        for i in objectives.indices { if let target = remap[objectives[i].topicID] { objectives[i].topicID = target } }
        for i in terms.indices { if let topic = terms[i].topicID, let target = remap[topic] { terms[i].topicID = target } }
        // Lehrplan-Themen ohne Material erhalten jetzt Material
        for i in state.topics.indices where state.topics[i].examID == examID && !state.topics[i].hasMaterial {
            if objectives.contains(where: { $0.topicID == state.topics[i].id }) { state.topics[i].hasMaterial = true }
        }

        // Doppelte Lernziele innerhalb eines Themas vermeiden
        let existingObjectives = state.objectives.filter { $0.examID == examID }
        var addedObjectives: [LearningObjective] = []
        for o in objectives {
            let key = TextNormalizer.normalize(o.title)
            if let duplicate = (existingObjectives + addedObjectives).first(where: { $0.topicID == o.topicID && TextNormalizer.similarity(TextNormalizer.normalize($0.title), key) >= 0.9 }) {
                if let index = state.objectives.firstIndex(where: { $0.id == duplicate.id }) {
                    state.objectives[index].sourceChunkIDs = Array(Set(state.objectives[index].sourceChunkIDs + o.sourceChunkIDs))
                }
                for i in terms.indices where terms[i].objectiveID == o.id { terms[i].objectiveID = duplicate.id }
                continue
            }
            addedObjectives.append(o)
        }
        let existingTermKeys = Set(state.terms.filter { $0.examID == examID }.map { TextNormalizer.normalize($0.term) })
        let addedTerms = terms.filter { !existingTermKeys.contains(TextNormalizer.normalize($0.term)) }

        state.topics.append(contentsOf: newTopics)
        state.objectives.append(contentsOf: addedObjectives)
        state.terms.append(contentsOf: addedTerms)

        // Lokale Übungsfragen sofort erzeugen (funktioniert offline)
        let examTerms = state.terms.filter { $0.examID == examID }
        var questionCount = 0
        for o in addedObjectives {
            let qs = LocalQuestionGenerator.questions(for: o, terms: examTerms, allTerms: examTerms, chunks: analysis.chunks, existing: state.questions.filter { $0.objectiveID == o.id })
            state.questions.append(contentsOf: qs)
            questionCount += qs.count
        }
        let withoutQuestions = addedObjectives.filter { o in !state.questions.contains { $0.objectiveID == o.id } }
        if !withoutQuestions.isEmpty {
            notes.append("Für \(withoutQuestions.count) Lernziel(e) konnten ohne KI-Dienst keine Fragen erzeugt werden.")
        }

        if let index = state.documents.firstIndex(where: { $0.id == document.id }) {
            state.documents[index].analysisSource = source
        }
        return IntegrationSummary(newTopics: newTopics.count, newObjectives: addedObjectives.count, newTerms: addedTerms.count,
                                  newQuestions: questionCount, source: source, notes: notes)
    }

    /// Lehrplan/Themenliste als verbindliche Grundlage: fehlende Themen werden angelegt (ohne Material markiert),
    /// bekannte Prüfungsanteile werden übernommen.
    public static func integrateSyllabus(_ state: inout AppState, examID: UUID, entries: [SyllabusParser.Entry]) -> IntegrationSummary {
        let minLevel = entries.contains { $0.level >= 2 } ? 2 : 1
        var newTopics = 0
        var newObjectives = 0
        var order = (state.topics.filter { $0.examID == examID }.map(\.order).max() ?? -1) + 1
        for entry in entries where entry.level >= minLevel {
            let topics = state.topics.filter { $0.examID == examID }
            if let match = SyllabusParser.matchingTopic(for: entry, in: topics), let index = state.topics.firstIndex(where: { $0.id == match.id }) {
                if let w = entry.weight { state.topics[index].examWeight = w }
                state.topics[index].reviewStatus = .confirmed
                continue
            }
            let topic = Topic(examID: examID, title: entry.title, summary: "Aus dem Lehrplan – noch kein Lernmaterial.", order: order,
                              importance: .standard, examWeight: entry.weight, origin: .syllabus, reviewStatus: .confirmed, hasMaterial: false)
            order += 1
            state.topics.append(topic)
            state.objectives.append(LearningObjective(examID: examID, topicID: topic.id, title: "„\(entry.title)“ beherrschen",
                                                      detail: "Laut Lehrplan prüfungsrelevant. Lade passendes Material hoch, damit Übungen entstehen können.",
                                                      origin: .syllabus, reviewStatus: .confirmed))
            newTopics += 1
            newObjectives += 1
        }
        return IntegrationSummary(newTopics: newTopics, newObjectives: newObjectives, newTerms: 0, newQuestions: 0, source: .local,
                                  notes: newTopics > 0 ? ["\(newTopics) Lehrplan-Themen haben noch kein Lernmaterial."] : [])
    }

    /// Entfernt ein Dokument. Lernziele mit bisherigen Antworten bleiben erhalten (dein Fortschritt geht nicht verloren).
    public static func removeDocument(_ state: inout AppState, documentID: UUID, chunkIDs: Set<UUID>) {
        state.documents.removeAll { $0.id == documentID }
        state.terms.removeAll { $0.source.documentID == documentID }
        for i in state.questions.indices where state.questions[i].source?.documentID == documentID && state.questions[i].status == .active {
            state.questions[i].status = .retired
        }
        let practiced = Set(state.attempts.map(\.objectiveID))
        state.objectives.removeAll { o in
            !o.sourceChunkIDs.isEmpty && o.sourceChunkIDs.allSatisfy { chunkIDs.contains($0) } && !practiced.contains(o.id) && o.origin != .syllabus && o.origin != .user
        }
        for i in state.objectives.indices {
            state.objectives[i].sourceChunkIDs.removeAll { chunkIDs.contains($0) }
        }
        let remainingTopicIDs = Set(state.objectives.map(\.topicID))
        state.topics.removeAll { !remainingTopicIDs.contains($0.id) && $0.origin != .syllabus && $0.origin != .user }
    }

    /// Löscht eine Prüfung mit allen zugehörigen Daten.
    public static func removeExam(_ state: inout AppState, examID: UUID) {
        let taskIDs = Set(state.tasks.filter { $0.examID == examID }.map(\.id))
        state.exams.removeAll { $0.id == examID }
        state.documents.removeAll { $0.examID == examID }
        state.topics.removeAll { $0.examID == examID }
        state.objectives.removeAll { $0.examID == examID }
        state.terms.removeAll { $0.examID == examID }
        state.questions.removeAll { $0.examID == examID }
        state.attempts.removeAll { $0.examID == examID }
        state.checks.removeAll { $0.examID == examID }
        state.tasks.removeAll { $0.examID == examID }
        state.simulations.removeAll { $0.examID == examID }
        state.calendarLinks.removeAll { taskIDs.contains($0.taskID) }
    }
}
