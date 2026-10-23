import SwiftUI

/// Ruhiges, zurückhaltendes Erscheinungsbild mit einem Akzentton (siehe AccentColor im Asset-Katalog).
enum Theme {
    static let corner: CGFloat = 16
    static let spacing: CGFloat = 16
    static let maxReadableWidth: CGFloat = 680

    static let success = Color.green
    static let warning = Color.orange
    static let calm = Color.accentColor

    static func color(for level: MasteryLevelColorKey) -> Color {
        switch level {
        case .notStarted: return Color.secondary.opacity(0.35)
        case .learned: return Color.orange.opacity(0.8)
        case .provisional: return Color.accentColor.opacity(0.6)
        case .stable: return Color.accentColor
        }
    }
}

enum MasteryLevelColorKey { case notStarted, learned, provisional, stable }

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM"
        return f
    }()

    static let dayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE, d. MMM"
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func minutes(_ value: Int) -> String {
        if value < 60 { return "\(value) Min." }
        let h = value / 60
        let m = value % 60
        return m == 0 ? "\(h) Std." : "\(h) Std. \(m) Min."
    }

    static func relativeDay(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInTomorrow(date) { return "Morgen" }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        return dayShort.string(from: date)
    }
}
