import XCTest
@testable import ShieldLogic

final class DayKeyTests: XCTestCase {
    func testDayKeyUsesCalendarTimeZone() {
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-10-23 02:30 in Wien = 2026-10-22 20:30 in New York
        let date = ISO8601DateFormatter().date(from: "2026-10-23T00:30:00Z")!
        XCTAssertEqual(DayKey(date, calendar: vienna).description, "2026-10-23")
        XCTAssertEqual(DayKey(date, calendar: newYork).description, "2026-10-22")
    }
}
