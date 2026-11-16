import Foundation

/// Moodle HTML as plain text, keeping links as `text (url)`.
///
/// A deliberate small converter rather than `NSAttributedString(html:)`: that one runs
/// WebKit, must be on the main thread, and may fetch remote resources named in the markup.
/// This only rewrites strings.
public enum HTMLText {

    public static func plain(_ html: String) -> String {
        var text = html
        // Content that is never text.
        text = replace(#"(?is)<(script|style)\b.*?</\1>"#, in: text, with: "")
        text = replace(#"(?s)<!--.*?-->"#, in: text, with: "")
        // As in a browser, line breaks and runs of spaces in the source are one space;
        // only the markup below makes new lines. Without this, the indentation of an
        // e-mail template (notifications) comes out as dozens of blank lines.
        text = replace(#"[ \t\r\n]+"#, in: text, with: " ")
        // Links: keep the target. Inner tags are stripped later with everything else.
        text = replace(
            #"(?is)<a\b[^>]*?\bhref\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#, in: text,
            with: "$2 ($1)")
        // Block structure.
        text = replace(#"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replace(#"(?i)<li\b[^>]*>"#, in: text, with: "\n- ")
        text = replace(#"(?i)</li>"#, in: text, with: "")
        text = replace(#"(?i)</(p|div|h[1-6]|tr|ul|ol|table|blockquote)>"#, in: text, with: "\n")
        text = replace(#"(?i)<(p|div|h[1-6]|tr|ul|ol|table|blockquote)\b[^>]*>"#, in: text, with: "\n")
        text = replace(#"(?i)</t[dh]>"#, in: text, with: "\t")
        text = replace(#"(?s)<[^>]+>"#, in: text, with: "")
        text = decodeEntities(text)
        // Tidy whitespace: no trailing spaces, at most one blank line.
        text = replace(#"[ \t\x{00A0}]+\n"#, in: text, with: "\n")
        text = replace(#"\n[ \x{00A0}]+"#, in: text, with: "\n")
        text = replace(#"[ \x{00A0}]{2,}"#, in: text, with: " ")
        text = replace(#"\n{3,}"#, in: text, with: "\n\n")
        // Link targets in the text are file URLs too.
        return Redaction.scrub(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–",
            "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»", "euro": "€", "iexcl": "¡",
            "iquest": "¿", "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
            "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "ntilde": "ñ",
            "Ntilde": "Ñ", "uuml": "ü", "Uuml": "Ü", "ordm": "º", "ordf": "ª", "middot": "·",
            "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•", "copy": "©",
        ]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);"#) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = source.substring(with: match.range(at: 1))
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity]
            }
            result += replacement ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

/// A moment typed by a caller: `2026-11-20` (midnight in Madrid), `2026-11-20T09:00`
/// (Madrid time) or `2026-11-20T09:00:00+01:00` (explicit offset).
public enum DateArgument {
    public static let help =
        "Accepts 2026-11-20 (midnight, Europe/Madrid), 2026-11-20T09:00 (Europe/Madrid) or 2026-11-20T09:00:00+01:00."

    /// `endOfDay` makes a bare date mean the last second of that day, so an inclusive end
    /// such as `to=2026-11-20` keeps a deadline at 23:59 on the 20th.
    public static func parse(_ text: String, name: String, endOfDay: Bool = false) throws(MoodleError) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: false)) {
            return Int(date.timeIntervalSince1970)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MoodleDate.timeZone
        let pattern = #/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?)?$/#
        guard let match = trimmed.wholeMatch(of: pattern) else {
            throw .badArgument(name: name, reason: "'\(trimmed)' is not a date. \(help)")
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = match.4.flatMap { Int($0) } ?? 0
        components.minute = match.5.flatMap { Int($0) } ?? 0
        components.second = match.6.flatMap { Int($0) } ?? 0
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == components.day else {
            throw .badArgument(name: name, reason: "'\(trimmed)' is not a real date. \(help)")
        }
        if endOfDay, match.4 == nil, let next = calendar.date(byAdding: .day, value: 1, to: date) {
            return Int(next.timeIntervalSince1970) - 1
        }
        return Int(date.timeIntervalSince1970)
    }
}
