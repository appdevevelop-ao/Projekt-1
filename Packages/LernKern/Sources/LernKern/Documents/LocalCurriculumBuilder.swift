import Foundation

/// Erzeugt Themen und Lernziele OHNE KI – ausschließlich aus Struktur und Definitionen des Materials.
/// Ergebnisse sind als Vorschläge ("aus deinen Unterlagen erkannt") gekennzeichnet und bearbeitbar.
public enum LocalCurriculumBuilder {
    public struct Result: Sendable {
        public var topics: [Topic]
        public var objectives: [LearningObjective]
        public var terms: [KeyTerm]
    }

    public static let maxTopics = 20
    public static let maxObjectivesPerTopic = 8

    public static func build(examID: UUID, documentID: UUID, sections: [DocumentSection], chunks: [SourceChunk], extractedTerms: [ExtractedTerm],
                             existingTopics: [Topic], orderOffset: Int) -> Result {
        let usable = chunks.filter { $0.duplicateOf == nil }
        guard !usable.isEmpty else { return Result(topics: [], objectives: [], terms: []) }

        // Themen = oberste Gliederungsebene; ohne Gliederung: Gruppen von Abschnitten
        var groups: [(title: String, chunks: [SourceChunk])] = []
        let topLevelTitles = usable.map { $0.sectionPath.first ?? "" }
        let distinctTop = orderedUnique(topLevelTitles)
        if distinctTop.count >= 2 && distinctTop.count <= maxTopics && !distinctTop.contains("") {
            for title in distinctTop { groups.append((title, usable.filter { ($0.sectionPath.first ?? "") == title })) }
        } else if distinctTop.count > maxTopics {
            // Viele Abschnitte (z. B. Folien): zusammenhängende Gruppen bilden
            let size = Int((Double(distinctTop.count) / Double(maxTopics)).rounded(.up))
            for start in stride(from: 0, to: distinctTop.count, by: size) {
                let titles = Array(distinctTop[start..<min(start + size, distinctTop.count)])
                let set = Set(titles)
                groups.append((titles.first ?? "Abschnitt", usable.filter { set.contains($0.sectionPath.first ?? "") }))
            }
        } else {
            let size = 4
            for start in stride(from: 0, to: usable.count, by: size) {
                let part = Array(usable[start..<min(start + size, usable.count)])
                groups.append((sectionTitle(part), part))
            }
        }

        var topics: [Topic] = []
        var objectives: [LearningObjective] = []
        var keyTerms: [KeyTerm] = []

        for (i, group) in groups.enumerated() where !group.chunks.isEmpty {
            let title = group.title.isEmpty ? sectionTitle(group.chunks) : group.title
            let chunkIDs = group.chunks.map(\.id)
            let totalChars = group.chunks.reduce(0) { $0 + $1.text.count }
            let topic = Topic(examID: examID, title: title, summary: summary(group.chunks), order: orderOffset + i,
                              importance: .standard, difficulty: totalChars > 8_000 ? 3 : (totalChars > 3_000 ? 2 : 1),
                              origin: .local, reviewStatus: .suggested, sourceChunkIDs: chunkIDs)
            topics.append(topic)

            let chunkSet = Set(chunkIDs)
            let groupTerms = extractedTerms.filter { chunkSet.contains($0.chunkID) }
            var objectiveOrder = 0

            // Lernziele: je Unterabschnitt eines; Text ohne Unterabschnitt → Begriffe bzw. Kernaussagen
            let subgroups = orderedUnique(group.chunks.map { $0.sectionPath.count >= 2 ? $0.sectionPath[1] : "" })
            for sub in subgroups {
                guard objectiveOrder < maxObjectivesPerTopic else { break }
                let subChunks = group.chunks.filter { ($0.sectionPath.count >= 2 ? $0.sectionPath[1] : "") == sub }
                let subSet = Set(subChunks.map(\.id))
                let termsHere = groupTerms.filter { subSet.contains($0.chunkID) }
                if !sub.isEmpty {
                    objectives.append(LearningObjective(
                        examID: examID, topicID: topic.id, title: sub, detail: "Inhalte von „\(sub)“ verstehen und wiedergeben.",
                        bloom: .understand, keyTerms: Array(termsHere.map(\.term).prefix(6)),
                        sourceChunkIDs: subChunks.map(\.id), importance: .standard, origin: .local,
                        estimatedMinutes: estimatedMinutes(subChunks), order: objectiveOrder))
                    objectiveOrder += 1
                } else if termsHere.isEmpty {
                    let substantial = subChunks.reduce(0) { $0 + $1.text.count } >= 200
                    guard substantial || subgroups.count == 1 else { continue }
                    objectives.append(LearningObjective(
                        examID: examID, topicID: topic.id, title: "Kernaussagen: \(title)", detail: "Die wichtigsten Inhalte dieses Abschnitts erklären können.",
                        bloom: .understand, keyTerms: subChunks.first.map { TermExtractor.keywords(for: $0, in: usable, limit: 5) } ?? [],
                        sourceChunkIDs: subChunks.map(\.id), origin: .local, estimatedMinutes: estimatedMinutes(subChunks), order: objectiveOrder))
                    objectiveOrder += 1
                } else {
                    let slots = max(1, maxObjectivesPerTopic - objectiveOrder - (subgroups.count - 1))
                    let perObjective = max(1, Int((Double(termsHere.count) / Double(slots)).rounded(.up)))
                    for start in stride(from: 0, to: termsHere.count, by: perObjective) {
                        let slice = Array(termsHere[start..<min(start + perObjective, termsHere.count)])
                        let names = slice.map(\.term)
                        let objectiveTitle = names.count == 1 ? "\(names[0]) erklären" : names.joined(separator: ", ") + " erklären und unterscheiden"
                        objectives.append(LearningObjective(
                            examID: examID, topicID: topic.id, title: objectiveTitle, detail: "Begriffe sicher erklären und voneinander abgrenzen.",
                            bloom: slice.contains { $0.kind == .formula } ? .apply : .remember, keyTerms: names,
                            sourceChunkIDs: Array(Set(slice.map(\.chunkID))), origin: .local,
                            estimatedMinutes: 6 + 3 * slice.count, order: objectiveOrder))
                        objectiveOrder += 1
                    }
                }
            }

            // Begriffe mit Lernziel verknüpfen
            let topicObjectives = objectives.filter { $0.topicID == topic.id }
            for t in groupTerms {
                let objective = topicObjectives.first { o in o.keyTerms.contains(t.term) } ?? topicObjectives.first { $0.sourceChunkIDs.contains(t.chunkID) } ?? topicObjectives.first
                keyTerms.append(KeyTerm(examID: examID, topicID: topic.id, objectiveID: objective?.id, term: t.term, definition: t.definition, kind: t.kind,
                                        source: SourceReference(documentID: documentID, chunkID: t.chunkID, page: chunks.first { $0.id == t.chunkID }?.pageStart, quote: t.sentence)))
            }
        }
        return Result(topics: topics, objectives: objectives, terms: keyTerms)
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func sectionTitle(_ chunks: [SourceChunk]) -> String {
        if let path = chunks.first?.sectionPath.last { return path }
        let pages = chunks.compactMap(\.pageStart)
        if let lo = pages.min(), let hi = chunks.compactMap(\.pageEnd).max() { return lo == hi ? "Seite \(lo)" : "Seiten \(lo)–\(hi)" }
        return "Abschnitt"
    }

    static func summary(_ chunks: [SourceChunk]) -> String {
        guard let first = chunks.first else { return "" }
        let sentence = TermExtractor.sentences(in: first.text).first ?? ""
        return sentence.count > 220 ? String(sentence.prefix(217)) + "…" : sentence
    }

    /// Erstlernzeit aus Textmenge (ca. 200 Wörter/Min. konzentriertes Lesen + Verarbeiten), 8–30 Minuten.
    static func estimatedMinutes(_ chunks: [SourceChunk]) -> Int {
        let words = chunks.reduce(0) { $0 + $1.text.split(separator: " ").count }
        return min(30, max(8, Int((Double(words) / 120).rounded()) + 5))
    }
}

/// Liest Lehrpläne/Themenlisten. Die Einträge werden zur verbindlichen Grundlage der Stoffabdeckung.
public enum SyllabusParser {
    public struct Entry: Hashable, Sendable {
        public var title: String
        public var weight: Double?
        public var level: Int
    }

    public static func entries(from document: ExtractedDocument) -> [Entry] {
        var result: [Entry] = []
        for block in document.blocks {
            let level: Int
            switch block.kind {
            case .heading(let l): level = l
            case .listItem, .tableRow: level = 2
            case .paragraph: level = block.text.count <= 90 && !block.text.hasSuffix(".") ? 2 : 0
            case .note: level = 0
            }
            guard level > 0 else { continue }
            var title = StructureDetector.stripNumbering(block.text.components(separatedBy: " | ").first ?? block.text)
            var weight: Double?
            if let r = title.range(of: #"\(?\s*(\d{1,3})\s*%\s*\)?"#, options: .regularExpression) {
                let digits = title[r].filter(\.isNumber)
                if let v = Double(digits), v > 0, v <= 100 { weight = v / 100 }
                title.removeSubrange(r)
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " :-–"))
            guard title.count >= 3, title.count <= 120 else { continue }
            result.append(Entry(title: title, weight: weight, level: level))
        }
        return result
    }

    /// Ordnet Lehrplan-Einträge vorhandenen Themen zu (Ähnlichkeit der Begriffe).
    public static func matchingTopic(for entry: Entry, in topics: [Topic]) -> Topic? {
        let entryTokens = Set(TextNormalizer.contentTokens(entry.title))
        guard !entryTokens.isEmpty else { return nil }
        var best: (Topic, Double)?
        for t in topics where t.origin != .syllabus {
            let score = TextNormalizer.jaccard(entryTokens, Set(TextNormalizer.contentTokens(t.title + " " + t.summary)))
            let contains = TextNormalizer.normalize(t.title).contains(TextNormalizer.normalize(entry.title)) || TextNormalizer.normalize(entry.title).contains(TextNormalizer.normalize(t.title))
            let s = contains ? max(score, 0.6) : score
            if s >= 0.3, s > (best?.1 ?? 0) { best = (t, s) }
        }
        return best?.0
    }
}
