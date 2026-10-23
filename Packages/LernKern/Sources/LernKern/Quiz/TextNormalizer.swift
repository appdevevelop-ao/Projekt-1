import Foundation

/// Vereinheitlicht Texte für den toleranten Vergleich von Antworten.
public enum TextNormalizer {
    static let articles: Set<String> = ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "the", "a", "an"]

    /// Kleinschreibung, Umlaute (ä→ae …), ß→ss, Akzente entfernt, Satzzeichen entfernt, Leerraum vereinheitlicht.
    public static func normalize(_ text: String, dropArticles: Bool = false) -> String {
        var s = text.lowercased()
        let replacements = ["ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"]
        for (k, v) in replacements { s = s.replacingOccurrences(of: k, with: v) }
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { scalars.append(u) }
            else if u == "%" || u == "-" { scalars.append(" ") }
            else { scalars.append(" ") }
        }
        var words = String(scalars).split(separator: " ").map(String.init)
        if dropArticles, words.count > 1 { words = words.filter { !articles.contains($0) } }
        return words.joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Inhaltswörter (ohne häufige Füllwörter), für Rubrik-Abgleich und Duplikaterkennung.
    public static func contentTokens(_ text: String) -> [String] {
        tokens(text).filter { $0.count > 2 && !stopwords.contains($0) }
    }

    static let stopwords: Set<String> = [
        "und", "oder", "aber", "auch", "nicht", "kein", "keine", "mit", "von", "fuer", "auf", "aus", "bei", "nach", "zum", "zur",
        "ist", "sind", "war", "wird", "werden", "wurde", "hat", "haben", "kann", "koennen", "muss", "sich", "dass", "wie", "was",
        "wenn", "als", "auch", "noch", "nur", "sehr", "mehr", "diese", "dieser", "dieses", "einer", "eines", "einem", "einen",
        "den", "dem", "des", "die", "der", "das", "ein", "eine", "the", "and", "for", "are", "with", "that", "this", "from",
        "man", "durch", "ueber", "unter", "zwischen", "sowie", "bzw", "etc", "usw", "also", "dann", "denn", "weil", "ohne",
    ]

    /// Ähnlichkeit 0…1 auf Basis der Levenshtein-Distanz.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        if longest == 0 { return 1 }
        return 1 - Double(distance(a, b)) / Double(longest)
    }

    /// Levenshtein-Distanz (Einfügen, Löschen, Ersetzen).
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Jaccard-Ähnlichkeit zweier Mengen.
    public static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}
