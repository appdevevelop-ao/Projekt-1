import Foundation

/// Erkennt Überschriften, Listen und Kopf-/Fußzeilen in reinem Text.
public enum StructureDetector {
    static let chapterWords = ["kapitel", "chapter", "teil", "abschnitt", "lektion", "einheit", "modul", "lesson", "unit", "part", "thema"]

    /// Ebene einer Überschrift (1 = Kapitel) oder nil.
    public static func headingLevel(of line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 90 else { return nil }
        // Markdown
        if t.hasPrefix("#") {
            let hashes = t.prefix { $0 == "#" }.count
            if hashes <= 6, t.dropFirst(hashes).first == " " { return min(hashes, 3) }
        }
        let lower = t.lowercased()
        // "Kapitel 3: Zellteilung", "Teil II"
        for word in chapterWords where lower.hasPrefix(word + " ") {
            let rest = lower.dropFirst(word.count + 1)
            if let first = rest.first, first.isNumber || "ivxlc".contains(first) { return 1 }
        }
        // "§ 3 Titel"
        if t.hasPrefix("§") && t.count < 70 { return 2 }
        // Nummerierung "2", "2.1", "2.1.3" gefolgt von Großbuchstabe/Wort, ohne Satzende
        if let match = t.range(of: #"^(\d{1,2})(\.\d{1,2}){0,3}\.?\s+\S"#, options: .regularExpression) {
            let numberPart = t[match].split(separator: " ").first ?? ""
            let depth = numberPart.split(separator: ".").filter { !$0.isEmpty }.count
            let firstContentChar = t[t.index(before: match.upperBound)]
            let endsLikeSentence = t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
            let wordCount = t.split(separator: " ").count
            if !endsLikeSentence && (firstContentChar.isUppercase || firstContentChar.isNumber) && wordCount <= 10 && !t.contains(",") {
                return min(depth, 3)
            }
        }
        // GROSSGESCHRIEBENE ZEILE
        let letters = t.filter(\.isLetter)
        if letters.count >= 4, letters.allSatisfy({ $0.isUppercase }), t.split(separator: " ").count <= 8, !t.hasSuffix(".") {
            return 1
        }
        return nil
    }

    public static func cleanHeading(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(":") { t.removeLast() }
        // Großgeschriebene Zeilen lesbarer machen
        let letters = t.filter(\.isLetter)
        if letters.count >= 4, letters.allSatisfy({ $0.isUppercase }) { t = t.capitalized }
        return t
    }

    /// Entfernt eine führende Nummerierung ("2.1 Mitose" → "Mitose").
    public static func stripNumbering(_ heading: String) -> String {
        var t = heading
        if let r = t.range(of: #"^(kapitel|chapter|teil|abschnitt|lektion|einheit|modul|lesson|unit|part|thema)\s+[\divxlcIVXLC]+[:.\s-]*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: #"^§?\s*\d{1,2}(\.\d{1,2}){0,3}\.?\s*"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        let cleaned = t.trimmingCharacters(in: CharacterSet(charactersIn: " :-–"))
        return cleaned.isEmpty ? heading : cleaned
    }

    public static func isListItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("• ") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("– ") || t.hasPrefix("▪ ") || t.hasPrefix("◦ ") { return true }
        return t.range(of: #"^([a-z]|\d{1,2})[\)]\s+\S"#, options: .regularExpression) != nil
    }

    public static func stripListMarker(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^([•\-\*–▪◦]|([a-z]|\d{1,2})\))\s+"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    /// Seitenzahlen und typische Kopf-/Fußzeilen.
    public static func isLikelyPageFurniture(_ line: String, pageNumber: Int) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == String(pageNumber) { return true }
        if t.range(of: #"^(seite|page|s\.)\s*\d+(\s*(von|of|/)\s*\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if t.range(of: #"^\d+\s*/\s*\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
