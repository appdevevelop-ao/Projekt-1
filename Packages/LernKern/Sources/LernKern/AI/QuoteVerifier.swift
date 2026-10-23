import Foundation

/// Prüft, ob ein von der KI genanntes Zitat tatsächlich im Material steht.
/// Fragen und Lernziele ohne nachprüfbaren Beleg werden verworfen.
public enum QuoteVerifier {
    public static func isSupported(quote: String, by text: String) -> Bool {
        let q = TextNormalizer.normalize(quote)
        let t = TextNormalizer.normalize(text)
        guard !q.isEmpty, !t.isEmpty else { return false }
        if t.contains(q) { return true }
        let quoteTokens = q.split(separator: " ").map(String.init)
        let textTokens = t.split(separator: " ").map(String.init)
        // Kurze Zitate müssen wörtlich vorkommen
        guard quoteTokens.count >= 5 else { return false }
        // Längste gemeinsame zusammenhängende Wortfolge (toleriert Auslassungen "…" und kleine OCR-Fehler)
        let textSet = Set(textTokens)
        let coverage = Double(quoteTokens.filter { textSet.contains($0) }.count) / Double(quoteTokens.count)
        guard coverage >= 0.85 else { return false }
        return longestCommonRun(quoteTokens, textTokens) >= min(6, quoteTokens.count)
    }

    static func longestCommonRun(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var best = 0
        var previous = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }
}
