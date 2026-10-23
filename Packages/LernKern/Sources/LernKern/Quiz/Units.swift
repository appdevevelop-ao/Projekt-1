import Foundation

/// Physikalische/übliche Einheiten mit Umrechnung in eine Basiseinheit je Dimension.
public enum UnitTable {
    public struct UnitInfo: Hashable, Sendable {
        public var dimension: String
        public var factor: Double
    }

    static let table: [String: UnitInfo] = {
        var t: [String: UnitInfo] = [:]
        func add(_ dim: String, _ entries: [(String, Double)]) { for (k, f) in entries { t[k] = UnitInfo(dimension: dim, factor: f) } }
        add("length", [("m", 1), ("km", 1000), ("dm", 0.1), ("cm", 0.01), ("mm", 0.001), ("µm", 1e-6), ("um", 1e-6), ("nm", 1e-9)])
        add("mass", [("kg", 1), ("g", 0.001), ("mg", 1e-6), ("t", 1000)])
        add("time", [("s", 1), ("ms", 0.001), ("min", 60), ("h", 3600), ("d", 86_400)])
        add("force", [("n", 1), ("kn", 1000), ("mn", 1e6)])
        add("energy", [("j", 1), ("kj", 1000), ("mj", 1e6), ("wh", 3600), ("kwh", 3.6e6), ("ev", 1.602176634e-19)])
        add("power", [("w", 1), ("kw", 1000), ("mw", 1e6)])
        add("voltage", [("v", 1), ("mv", 0.001), ("kv", 1000)])
        add("current", [("a", 1), ("ma", 0.001)])
        add("resistance", [("ω", 1), ("ohm", 1), ("kω", 1000), ("kohm", 1000)])
        add("pressure", [("pa", 1), ("hpa", 100), ("kpa", 1000), ("mpa", 1e6), ("bar", 1e5), ("mbar", 100)])
        add("frequency", [("hz", 1), ("khz", 1000), ("mhz", 1e6), ("ghz", 1e9)])
        add("volume", [("l", 0.001), ("ml", 1e-6), ("m3", 1), ("m³", 1), ("cm3", 1e-6), ("cm³", 1e-6), ("dm3", 0.001), ("dm³", 0.001)])
        add("area", [("m2", 1), ("m²", 1), ("cm2", 1e-4), ("cm²", 1e-4), ("km2", 1e6), ("km²", 1e6), ("mm2", 1e-6), ("mm²", 1e-6)])
        add("speed", [("m/s", 1), ("km/h", 1 / 3.6)])
        add("acceleration", [("m/s2", 1), ("m/s²", 1)])
        add("percent", [("%", 1), ("prozent", 1)])
        add("currency", [("€", 1), ("eur", 1), ("euro", 1)])
        add("celsius", [("°c", 1)])
        add("kelvin", [("k", 1)])
        add("mol", [("mol", 1), ("mmol", 0.001)])
        return t
    }()

    public static func info(for unit: String) -> UnitInfo? {
        let key = unit.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "^2", with: "2").replacingOccurrences(of: "^3", with: "3")
        return table[key]
    }
}

/// Parst Zahlen in deutscher und englischer Schreibweise inkl. Einheit und Zehnerpotenz.
public enum NumberParser {
    public struct Parsed: Hashable, Sendable {
        public var value: Double
        public var unit: String?
    }

    public static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "≈", with: "")
            .replacingOccurrences(of: "=", with: "")
        if text.isEmpty { return nil }
        text = text.trimmingCharacters(in: .whitespaces)

        // Zahlteil am Anfang finden
        let numberChars = Set("0123456789.,-+ ")
        var numberPart = ""
        var index = text.startIndex
        while index < text.endIndex, numberChars.contains(text[index]) {
            numberPart.append(text[index])
            index = text.index(after: index)
        }
        var rest = String(text[index...]).trimmingCharacters(in: .whitespaces)
        numberPart = numberPart.trimmingCharacters(in: .whitespaces)
        // Leerzeichen als Tausendertrennzeichen ("1 000")
        numberPart = numberPart.replacingOccurrences(of: " ", with: "")
        guard var value = parseNumber(numberPart) else { return nil }

        // Zehnerpotenz: e3, E-3, ·10^3, x10^3, *10^3, × 10^-3
        let lower = rest.lowercased()
        if let match = lower.range(of: #"^(e|·\s*10\^|x\s*10\^|\*\s*10\^|×\s*10\^)\s*([-+]?\d+)"#, options: .regularExpression) {
            let expText = lower[match].replacingOccurrences(of: #"^(e|·\s*10\^|x\s*10\^|\*\s*10\^|×\s*10\^)\s*"#, with: "", options: .regularExpression)
            if let exp = Int(expText) { value *= pow(10, Double(exp)) }
            rest = String(rest[rest.index(rest.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: match.upperBound))...]).trimmingCharacters(in: .whitespaces)
        }
        let unit = rest.isEmpty ? nil : rest.trimmingCharacters(in: CharacterSet(charactersIn: " .;"))
        return Parsed(value: value, unit: unit?.isEmpty == true ? nil : unit)
    }

    static func parseNumber(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        var t = s
        let hasComma = t.contains(",")
        let hasDot = t.contains(".")
        if hasComma && hasDot {
            if let lastComma = t.lastIndex(of: ","), let lastDot = t.lastIndex(of: "."), lastComma > lastDot {
                t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                t = t.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            t = t.replacingOccurrences(of: ",", with: ".")
        } else if hasDot, t.range(of: #"^-?\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            t = t.replacingOccurrences(of: ".", with: "")
        }
        return Double(t)
    }
}
