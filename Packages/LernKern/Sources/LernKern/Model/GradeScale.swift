import Foundation

/// Eine Notenstufe. `minFraction` ist der Mindestanteil der erreichbaren Punkte (0…1).
public struct GradeBand: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var name: String
    public var minFraction: Double
    public var isPassing: Bool

    public init(id: String, label: String, name: String, minFraction: Double, isPassing: Bool) {
        self.id = id
        self.label = label
        self.name = name
        self.minFraction = minFraction
        self.isPassing = isPassing
    }
}

public enum GradeScaleKind: String, Codable, CaseIterable, Sendable {
    case austrian
    case german
    case points
    case percent
    case custom
}

/// Konfigurierbare Notenskala. Bänder sind von der besten zur schlechtesten Note sortiert.
public struct GradeScale: Codable, Hashable, Sendable {
    public var kind: GradeScaleKind
    public var name: String
    public var bands: [GradeBand]
    /// Bei Punktesystemen: maximal erreichbare Punkte.
    public var maxPoints: Double?
    /// `true`, wenn die Grenzen aus offiziellen Bewertungskriterien stammen.
    /// Andernfalls ist die Skala eine Schätzung und wird so gekennzeichnet.
    public var isOfficial: Bool

    public init(kind: GradeScaleKind, name: String, bands: [GradeBand], maxPoints: Double? = nil, isOfficial: Bool) {
        self.kind = kind
        self.name = name
        self.bands = bands.sorted { $0.minFraction > $1.minFraction }
        self.maxPoints = maxPoints
        self.isOfficial = isOfficial
    }

    /// Österreichische Skala 1–5 mit gleichmäßig verteilten, GESCHÄTZTEN Grenzen.
    /// Die tatsächlichen Grenzen legt die prüfende Stelle fest – deshalb `isOfficial = false`.
    public static let austrian = GradeScale(kind: .austrian, name: "Österreich (1–5)", bands: [
        GradeBand(id: "1", label: "1", name: "Sehr gut", minFraction: 0.875, isPassing: true),
        GradeBand(id: "2", label: "2", name: "Gut", minFraction: 0.75, isPassing: true),
        GradeBand(id: "3", label: "3", name: "Befriedigend", minFraction: 0.625, isPassing: true),
        GradeBand(id: "4", label: "4", name: "Genügend", minFraction: 0.5, isPassing: true),
        GradeBand(id: "5", label: "5", name: "Nicht genügend", minFraction: 0, isPassing: false),
    ], isOfficial: false)

    /// Deutsche Skala 1–6 mit geschätzten Grenzen (häufig verwendeter Notenschlüssel).
    public static let german = GradeScale(kind: .german, name: "Deutschland (1–6)", bands: [
        GradeBand(id: "1", label: "1", name: "Sehr gut", minFraction: 0.92, isPassing: true),
        GradeBand(id: "2", label: "2", name: "Gut", minFraction: 0.81, isPassing: true),
        GradeBand(id: "3", label: "3", name: "Befriedigend", minFraction: 0.67, isPassing: true),
        GradeBand(id: "4", label: "4", name: "Ausreichend", minFraction: 0.5, isPassing: true),
        GradeBand(id: "5", label: "5", name: "Mangelhaft", minFraction: 0.3, isPassing: false),
        GradeBand(id: "6", label: "6", name: "Ungenügend", minFraction: 0, isPassing: false),
    ], isOfficial: false)

    /// Bestehen/Nicht bestehen mit Prozentgrenze.
    public static func passFail(threshold: Double, isOfficial: Bool) -> GradeScale {
        GradeScale(kind: .percent, name: "Bestanden ab \(Int((threshold * 100).rounded())) %", bands: [
            GradeBand(id: "pass", label: "Bestanden", name: "Bestanden", minFraction: threshold, isPassing: true),
            GradeBand(id: "fail", label: "Nicht bestanden", name: "Nicht bestanden", minFraction: 0, isPassing: false),
        ], isOfficial: isOfficial)
    }

    /// Punktesystem: Grenzen in Punkten (z. B. 45 von 60 für "Gut").
    public static func points(maxPoints: Double, thresholds: [(label: String, name: String, minPoints: Double, isPassing: Bool)], isOfficial: Bool) -> GradeScale {
        let bands = thresholds.map { t in
            GradeBand(id: t.label, label: t.label, name: t.name, minFraction: maxPoints > 0 ? t.minPoints / maxPoints : 0, isPassing: t.isPassing)
        }
        return GradeScale(kind: .points, name: "Punkte (max. \(Int(maxPoints)))", bands: bands, maxPoints: maxPoints, isOfficial: isOfficial)
    }

    public func band(id: String) -> GradeBand? { bands.first { $0.id == id } }

    /// Note für einen Punkteanteil.
    public func band(for fraction: Double) -> GradeBand {
        let f = min(max(fraction, 0), 1)
        return bands.first { f >= $0.minFraction - 1e-9 } ?? bands[bands.count - 1]
    }

    /// 0 = beste Note.
    public func rank(of id: String) -> Int { bands.firstIndex { $0.id == id } ?? bands.count }

    /// Ist `id` mindestens so gut wie `target`?
    public func isAtLeast(_ id: String, _ target: String) -> Bool { rank(of: id) <= rank(of: target) }

    /// Standardziel: die zweitbeste bestandene Note (bei Bestanden/Nicht bestanden: Bestanden).
    public var defaultTargetID: String {
        let passing = bands.filter(\.isPassing)
        if passing.count >= 2 { return passing[1].id }
        return passing.first?.id ?? bands[0].id
    }

    /// Niedrigste noch bestandene Note.
    public var lowestPassingID: String { bands.last(where: \.isPassing)?.id ?? bands[0].id }

    /// Ob die Grenzen fachlich sinnvoll sind (absteigend, eindeutig, unterste Grenze 0).
    public var validationErrors: [String] {
        var errors: [String] = []
        if bands.count < 2 { errors.append("Mindestens zwei Notenstufen sind nötig.") }
        if Set(bands.map(\.id)).count != bands.count { errors.append("Notenbezeichnungen müssen eindeutig sein.") }
        if let last = bands.last, last.minFraction > 0 { errors.append("Die schlechteste Note muss bei 0 beginnen.") }
        for (a, b) in zip(bands, bands.dropFirst()) where a.minFraction <= b.minFraction {
            errors.append("Die Grenze für \(a.label) muss über der für \(b.label) liegen.")
        }
        if !bands.contains(where: \.isPassing) { errors.append("Mindestens eine Note muss als bestanden gelten.") }
        return errors
    }
}
