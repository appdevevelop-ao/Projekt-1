import Foundation

/// Erkennt (nahezu) doppelte Abschnitte – z. B. dieselben Folien als PDF und PPTX.
public enum Deduplicator {
    public static let threshold = 0.8

    static func shingles(_ text: String, size: Int = 5) -> Set<String> {
        let tokens = TextNormalizer.tokens(text)
        guard tokens.count >= size else { return tokens.isEmpty ? [] : [tokens.joined(separator: " ")] }
        var result: Set<String> = []
        for i in 0...(tokens.count - size) { result.insert(tokens[i..<(i + size)].joined(separator: " ")) }
        return result
    }

    /// Markiert in `newChunks` alle Abschnitte, die einem bereits vorhandenen (oder früheren neuen) Abschnitt entsprechen.
    public static func markDuplicates(newChunks: [SourceChunk], existing: [SourceChunk]) -> [SourceChunk] {
        var reference: [(UUID, Set<String>)] = existing.filter { $0.duplicateOf == nil }.map { ($0.id, shingles($0.text)) }
        var result: [SourceChunk] = []
        for var chunk in newChunks {
            let s = shingles(chunk.text)
            if s.count >= 3, let match = reference.first(where: { TextNormalizer.jaccard($0.1, s) >= threshold }) {
                chunk.duplicateOf = match.0
            } else {
                reference.append((chunk.id, s))
            }
            result.append(chunk)
        }
        return result
    }
}

/// Prüft Qualität und Vollständigkeit der Extraktion und warnt, statt Lücken zu verschweigen.
public enum ExtractionQualityChecker {
    public static func check(_ document: ExtractedDocument, kind: DocumentKind) -> [ExtractionWarning] {
        var warnings = document.warnings
        var textPerPage: [Int: String] = [:]
        for block in document.blocks {
            if let p = block.page { textPerPage[p, default: ""] += block.text + " " }
        }
        if kind == .pdf || kind == .scan || kind == .image {
            for page in 1...max(1, document.pageCount) {
                let text = textPerPage[page] ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    warnings.append(ExtractionWarning(kind: .emptyPage, page: page, message: "Seite \(page) enthält kaum lesbaren Text (z. B. nur Bilder oder Grafiken). Inhalte dieser Seite fehlen in der Analyse."))
                }
            }
        }
        for (page, confidence) in document.recognitionConfidence.sorted(by: { $0.key < $1.key }) where confidence < 0.5 {
            warnings.append(ExtractionWarning(kind: .lowRecognitionConfidence, page: page, message: "Die Texterkennung auf Seite \(page) ist unsicher. Prüfe den Text oder scanne die Seite erneut bei besserem Licht."))
        }
        for (page, text) in textPerPage.sorted(by: { $0.key < $1.key }) where isGarbled(text) {
            warnings.append(ExtractionWarning(kind: .garbledText, page: page, message: "Der Text auf Seite \(page) wirkt fehlerhaft (ungewöhnliche Zeichen). Möglicherweise ist die Schrift im PDF nicht korrekt eingebettet."))
        }
        return warnings
    }

    static func isGarbled(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard visible.count >= 40 else { return false }
        let letters = visible.filter { $0.isLetter || $0.isNumber }.count
        let replacement = visible.filter { $0 == "\u{FFFD}" }.count
        return Double(letters) / Double(visible.count) < 0.55 || replacement > 3
    }
}
