import Foundation

extension Sequence {
    /// Summe über einen Wert je Element (vermeidet schwer typisierbare `reduce`-Ausdrücke).
    func sum(_ value: (Element) -> Double) -> Double {
        var total = 0.0
        for element in self { total += value(element) }
        return total
    }
}

extension Dictionary where Value == Double {
    func value(_ key: Key) -> Double { self[key] ?? 0 }
}
