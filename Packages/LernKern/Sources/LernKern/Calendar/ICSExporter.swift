import Foundation

/// Exportiert Lerneinheiten als iCalendar-Datei (.ics) – für Nutzer ohne Kalenderberechtigung.
/// Stabile UIDs sorgen dafür, dass ein erneuter Import Termine aktualisiert statt verdoppelt.
public enum ICSExporter {
    public static func export(_ contents: [(taskID: UUID, content: CalendarEventContent)], now: Date) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//LernFokus//Lernplan//DE",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:LernFokus Lernplan",
        ]
        for item in contents {
            let c = item.content
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(item.taskID.uuidString.lowercased())@lernfokus.app")
            lines.append("DTSTAMP:\(utc(now))")
            lines.append("DTSTART:\(utc(c.start))")
            lines.append("DTEND:\(utc(c.end))")
            lines.append("SUMMARY:\(escape(c.title))")
            lines.append("DESCRIPTION:\(escape(c.notes))")
            lines.append("URL:\(c.url)")
            if let minutes = c.alarmMinutesBefore, minutes > 0 {
                lines.append("BEGIN:VALARM")
                lines.append("ACTION:DISPLAY")
                lines.append("DESCRIPTION:\(escape(c.title))")
                lines.append("TRIGGER:-PT\(minutes)M")
                lines.append("END:VALARM")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Zeilen nach RFC 5545 bei 75 Oktetts falten, ohne UTF-8-Zeichen zu zerteilen.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var result = ""
        var current = ""
        var currentBytes = 0
        var limit = 75
        for character in line {
            let bytes = String(character).utf8.count
            if currentBytes + bytes > limit {
                result += current + "\r\n "
                current = ""
                currentBytes = 0
                limit = 74
            }
            current.append(character)
            currentBytes += bytes
        }
        return result + current
    }
}
