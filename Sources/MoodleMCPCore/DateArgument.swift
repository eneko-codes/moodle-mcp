import Foundation

/// A moment typed by a caller: `2026-11-20` (a day in Europe/Madrid), `2026-11-20T09:00`
/// (Europe/Madrid time, seconds optional) or `2026-11-20T09:00:00+01:00` (an explicit
/// offset, or `Z`).
public enum DateArgument {
    public static let help =
        "Accepts 2026-11-20 (a whole day, Europe/Madrid), 2026-11-20T09:00 (Europe/Madrid) or 2026-11-20T09:00:00+01:00."

    /// Unix seconds. `endOfRange` makes the moment the last second of the precision
    /// written, so an inclusive end such as `to_date=2026-11-20` keeps a deadline at 23:59
    /// on the 20th, and `to_date=2026-11-20T09:00` keeps one at 09:00:30.
    ///
    /// A date that does not exist is refused rather than rolled over: 30 February, and an
    /// hour that a clock change skips in Madrid.
    public static func parse(_ text: String, name: String, endOfRange: Bool = false) throws(MoodleError) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = #/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?)?$/#
        guard let match = trimmed.wholeMatch(of: pattern) else {
            throw .badArgument(name: name, reason: "'\(ToolStandard.echo(trimmed))' is not a date. \(help)")
        }
        var calendar = Calendar(identifier: .gregorian)
        if let offset = match.7 {
            guard let zone = timeZone(offset: String(offset)) else {
                throw .badArgument(name: name, reason: "'\(ToolStandard.echo(trimmed))' has no valid offset. \(help)")
            }
            calendar.timeZone = zone
        } else {
            calendar.timeZone = MoodleDate.timeZone
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = match.4.flatMap { Int($0) } ?? 0
        components.minute = match.5.flatMap { Int($0) } ?? 0
        components.second = match.6.flatMap { Int($0) } ?? 0

        // Calendar rolls an impossible date into a real one (30 February becomes 2 March,
        // a skipped 02:30 becomes 03:30), so the result must read back as what was written.
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        guard let date = calendar.date(from: components), sameFields(calendar.dateComponents(fields, from: date), components)
        else {
            throw .badArgument(
                name: name, reason: "'\(ToolStandard.echo(trimmed))' does not exist in Europe/Madrid or at that offset. \(help)")
        }
        let start = Int(date.timeIntervalSince1970)
        guard endOfRange else { return start }
        if match.4 == nil, let next = calendar.date(byAdding: .day, value: 1, to: date) {
            return Int(next.timeIntervalSince1970) - 1
        }
        return match.6 == nil ? start + 59 : start
    }

    private static func sameFields(_ read: DateComponents, _ written: DateComponents) -> Bool {
        read.year == written.year && read.month == written.month && read.day == written.day
            && read.hour == written.hour && read.minute == written.minute && read.second == written.second
    }

    /// `Z`, or `+hh:mm` / `-hh:mm` within the offsets in use on Earth.
    private static func timeZone(offset: String) -> TimeZone? {
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...14).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }
}
