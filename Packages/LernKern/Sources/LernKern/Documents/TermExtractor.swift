import Foundation

/// Ein im Material gefundener Begriff mit wörtlichem Beleg.
public struct ExtractedTerm: Hashable, Sendable {
    public var term: String
    public var definition: String
    /// Der vollständige Satz aus dem Material (Beleg).
    public var sentence: String
    public var chunkID: UUID
    public var kind: KeyTerm.Kind
}

/// Findet Definitionen, Fachbegriffe und Formeln mit einfachen, nachvollziehbaren Mustern.
/// Es wird nichts erfunden: Jeder Begriff ist mit dem Satz belegt, aus dem er stammt.
public enum TermExtractor {
    static let pronouns: Set<String> = ["es", "das", "dies", "dieser", "diese", "dieses", "er", "sie", "man", "hier", "dort", "dabei", "daher",
                                         "deshalb", "somit", "also", "wir", "ich", "du", "ihr", "it", "this", "that", "these", "there", "they", "we", "he", "she",
                                         "beispiel", "folgendes", "folgende", "jeder", "jede", "alle", "einige", "viele", "was", "wer", "wie"]
    static let leadingArticles = ["der ", "die ", "das ", "ein ", "eine ", "the ", "a ", "an "]

    public static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text.replacingOccurrences(of: "\n", with: " "))
        for (i, c) in chars.enumerated() {
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let nextNext = i + 2 < chars.count ? chars[i + 2] : " "
                let prevWord = current.split(separator: " ").last.map(String.init) ?? ""
                let isAbbreviation = ["z.b.", "bzw.", "usw.", "ca.", "vgl.", "d.h.", "u.a.", "s.", "abb.", "nr.", "etc.", "e.g.", "i.e.", "dr.", "prof."].contains(prevWord.lowercased())
                    || (prevWord.count <= 2 && prevWord.first?.isNumber == true)
                if next == " " && (nextNext.isUppercase || nextNext.isNumber || nextNext == "\"" || nextNext == "„") && !isAbbreviation {
                    let s = current.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { result.append(s) }
                    current = ""
                }
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    public static func extract(from chunks: [SourceChunk]) -> [ExtractedTerm] {
        var seen: Set<String> = []
        var result: [ExtractedTerm] = []
        for chunk in chunks where chunk.duplicateOf == nil {
            for line in chunk.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "• ", with: "")
                if let t = glossaryEntry(trimmed, chunkID: chunk.id) ?? formula(trimmed, chunkID: chunk.id) {
                    if seen.insert(TextNormalizer.normalize(t.term)).inserted { result.append(t) }
                    continue
                }
                for sentence in sentences(in: trimmed) {
                    if let t = definition(in: sentence, chunkID: chunk.id), seen.insert(TextNormalizer.normalize(t.term)).inserted {
                        result.append(t)
                    }
                }
            }
        }
        return result
    }

    static func definition(in sentence: String, chunkID: UUID) -> ExtractedTerm? {
        let s = sentence.trimmingCharacters(in: .whitespaces)
        guard s.count >= 25, s.count <= 400 else { return nil }
        let patterns: [(String, Bool)] = [
            // (Muster, Begriff steht am Ende)
            (#"^(?:Unter (?:einer |einem |einen |dem |der |den )?)(?<term>[^,]{2,60}?) versteht man (?<def>.+)$"#, false),
            (#"^(?:Als )(?<term>[^,]{2,60}?) (?:bezeichnet|definiert) man (?<def>.+)$"#, false),
            (#"^(?<def>.+?) (?:nennt man|heißt|bezeichnet man als|wird als|werden als) (?<term>[^,]{2,60}?)(?: bezeichnet)?\.$"#, true),
            (#"^(?<term>[A-ZÄÖÜ0-9][^,:;]{1,60}?) (?:ist|sind|bezeichnet|bezeichnen|beschreibt|beschreiben|bedeutet|meint|nennt sich) (?<def>(?:ein|eine|einer|eines|der|die|das|den|dem|des|jene|jener|alle|im|in|bei|the|a|an|eine Bezeichnung|die Bezeichnung|ein Begriff) .+)$"#, false),
            (#"^(?<term>[A-Z][^,:;]{1,60}?) (?:is|are) (?:defined as|a|an|the|called) (?<def>.+)$"#, false),
            (#"^(?<term>[A-Z][^,:;]{1,60}?) refers to (?<def>.+)$"#, false),
            (#"^Definition(?: von| des| der)?\s*(?<term>[^:]{2,60}?)?:\s*(?<def>.+)$"#, false),
        ]
        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            guard let termRange = Range(match.range(withName: "term"), in: s),
                  let defRange = Range(match.range(withName: "def"), in: s) else { continue }
            var term = String(s[termRange]).trimmingCharacters(in: CharacterSet(charactersIn: " „“\"'()"))
            for article in leadingArticles where term.lowercased().hasPrefix(article) { term = String(term.dropFirst(article.count)) }
            term = term.trimmingCharacters(in: .whitespaces)
            let definition = String(s[defRange]).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard isPlausibleTerm(term), definition.count >= 12 else { continue }
            return ExtractedTerm(term: term, definition: definition, sentence: s, chunkID: chunkID, kind: .definition)
        }
        return nil
    }

    /// Glossar-Zeilen wie "Mitose: Teilung des Zellkerns …".
    static func glossaryEntry(_ line: String, chunkID: UUID) -> ExtractedTerm? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let term = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let definition = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard isPlausibleTerm(term), definition.count >= 20, definition.count <= 400, term.split(separator: " ").count <= 4,
              !["beispiel", "hinweis", "merke", "achtung", "aufgabe", "lösung", "quelle", "seite", "note", "example", "definition", "notiz"].contains(term.lowercased()) else { return nil }
        return ExtractedTerm(term: term, definition: definition, sentence: line, chunkID: chunkID, kind: .definition)
    }

    /// Formeln wie "F = m · a".
    static func formula(_ line: String, chunkID: UUID) -> ExtractedTerm? {
        guard line.count <= 80, line.contains("="), !line.contains("=="),
              let regex = try? NSRegularExpression(pattern: #"^(?<lhs>[A-Za-zΑ-Ωα-ω][A-Za-z0-9_Α-Ωα-ω]{0,6})\s*=\s*(?<rhs>[^=]{1,70})$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let lhsRange = Range(match.range(withName: "lhs"), in: line),
              let rhsRange = Range(match.range(withName: "rhs"), in: line) else { return nil }
        let rhs = String(line[rhsRange]).trimmingCharacters(in: .whitespaces)
        let operators = rhs.filter { "+-·*/^×÷√()".contains($0) }.count
        let symbols = rhs.split(whereSeparator: { " +-·*/^×÷()".contains($0) }).count
        guard operators >= 1, symbols >= 2, rhs.split(separator: " ").count <= 12 else { return nil }
        return ExtractedTerm(term: String(line[lhsRange]), definition: line.trimmingCharacters(in: .whitespaces), sentence: line, chunkID: chunkID, kind: .formula)
    }

    static func isPlausibleTerm(_ term: String) -> Bool {
        let words = term.split(separator: " ")
        guard term.count >= 2, term.count <= 60, words.count <= 5, let first = words.first else { return false }
        if pronouns.contains(first.lowercased()) { return false }
        if term.rangeOfCharacter(from: .letters) == nil { return false }
        if term.hasSuffix(".") || term.contains("?") { return false }
        return true
    }

    /// Wichtige Wörter eines Abschnitts (TF-IDF über alle Abschnitte).
    public static func keywords(for chunk: SourceChunk, in corpus: [SourceChunk], limit: Int = 5) -> [String] {
        let docFrequency = corpus.reduce(into: [String: Int]()) { counts, c in
            for token in Set(TextNormalizer.contentTokens(c.text)) { counts[token, default: 0] += 1 }
        }
        var termFrequency: [String: Int] = [:]
        var original: [String: String] = [:]
        for word in chunk.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let raw = String(word)
            let token = TextNormalizer.normalize(raw)
            guard token.count > 3, !TextNormalizer.stopwords.contains(token) else { continue }
            termFrequency[token, default: 0] += 1
            if original[token] == nil || raw.first?.isUppercase == true { original[token] = raw }
        }
        let n = Double(max(corpus.count, 1))
        return termFrequency.map { token, tf -> (String, Double) in
            let idf = log((n + 1) / Double((docFrequency[token] ?? 0) + 1)) + 1
            return (token, Double(tf) * idf * (original[token]?.first?.isUppercase == true ? 1.2 : 1))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .prefix(limit)
        .compactMap { original[$0.0] }
    }
}
