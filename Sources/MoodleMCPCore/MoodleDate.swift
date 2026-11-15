import Foundation

/// A Moodle timestamp as every answer shows it: ISO 8601 with the Europe/Madrid offset
/// of that moment (`+01:00` in winter, `+02:00` in summer) and, beside it, the same
/// moment as `dd/mm/aaaa HH:mm` on a 24-hour clock.
///
/// Fixed to Europe/Madrid rather than the Mac's zone: the deadlines this was built for are
/// set in Madrid time, and an answer must not change meaning when the Mac travels.
public struct MoodleDate: Encodable, Equatable, Sendable {
    public let iso: String
    public let fechaLocal: String

    enum CodingKeys: String, CodingKey {
        case iso
        case fechaLocal = "fecha_local"
    }

    public static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    /// Moodle uses 0 for "no date"; that, and any negative value, is `nil` (rendered as
    /// JSON `null`), never 1 January 1970.
    public init?(unixSeconds: Int?) {
        guard let unixSeconds, unixSeconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        iso = date.formatted(Self.isoStyle)
        fechaLocal = date.formatted(Self.localStyle)
    }

    private static let isoStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone)

    private static let localStyle: Date.VerbatimFormatStyle = Date.VerbatimFormatStyle(
        format: "\(day: .twoDigits)/\(month: .twoDigits)/\(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: timeZone,
        calendar: Calendar(identifier: .gregorian))
}
