import Foundation

enum TestCalendar {
    static func make(_ identifier: String = "Europe/Vienna") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "de_AT")
        calendar.firstWeekday = 2
        return calendar
    }
}

extension Calendar {
    /// Erzeugt ein Datum aus lokalen Komponenten.
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
