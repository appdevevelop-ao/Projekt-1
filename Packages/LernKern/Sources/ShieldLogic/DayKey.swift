import Foundation

/// Ein lokaler Kalendertag (z. B. "2026-10-23"), berechnet in der aktuellen Zeitzone des Geräts.
public struct DayKey: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension DayKey {
    /// Beginn dieses Tages (00:00 Ortszeit) im angegebenen Kalender.
    public func startDate(calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Beginn des Folgetages, also das Ende dieses Tages.
    public func endDate(calendar: Calendar) -> Date? {
        guard let start = startDate(calendar: calendar) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    public func adding(days: Int, calendar: Calendar) -> DayKey {
        guard let start = startDate(calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return self }
        return DayKey(shifted, calendar: calendar)
    }

    /// Parst "JJJJ-MM-TT".
    public init?(string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }
}
