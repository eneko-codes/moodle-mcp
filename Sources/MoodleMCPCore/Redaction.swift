import Foundation

/// The last gate before anything leaves this program — a tool answer, an error message, a
/// command-line line. Models never decode the token or `userprivateaccesskey` in the first
/// place; this catches what slipped through anyway.
public enum Redaction {

    /// Keys dropped from every decoded JSON object before it is used.
    public static let droppedKeys: Set<String> = ["userprivateaccesskey", "token", "privatetoken", "wstoken"]

    /// Removes any `token=` / `wstoken=` query parameter (Moodle appends one to file URLs
    /// in web-service answers), any `userprivateaccesskey`, and the literal token wherever
    /// it appears.
    public static func scrub(_ text: String, token: String? = nil) -> String {
        var result = text
        if let token, token.count >= 8 {
            result = result.replacingOccurrences(of: token, with: "[redacted]")
        }
        // Only the separator that belonged to the token parameter goes with it, so a lone
        // `&` or `?` in ordinary text is never touched.
        // `?token=abc&x=1` → `?x=1`, `&token=abc&x=1` → `&x=1`:
        // Any case, `&amp;` (HTML fields), `#`, and percent-encoded `?`, `&` and `=` count.
        // A value stops at `%` and `\` too: tokens are hex, and a JSON-escaped quote must
        // survive.
        let separator = #"(?:&amp;|[?&#]|%3F|%26)"#
        let parameter = #"(?:ws)?token(?:=|%3D)[^&#%\\\s"'<>()]*"#
        result = result.replacingOccurrences(
            of: "(\(separator))\(parameter)(?:&amp;|&|%26)", with: "$1",
            options: [.regularExpression, .caseInsensitive])
        // `?token=abc` or `&token=abc` as the last parameter: the separator goes too.
        result = result.replacingOccurrences(
            of: separator + parameter, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: #""?userprivateaccesskey"?\s*[:=]\s*"?[A-Za-z0-9]*"?"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        return result
    }

    /// For a file URL returned to a caller: the same URL with no token parameter.
    public static func stripToken(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return scrub(url) }
        components.queryItems = components.queryItems?.filter {
            !["token", "wstoken"].contains($0.name.lowercased())
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? scrub(url)
    }

    /// Removes `droppedKeys` at every depth of a JSON value from `JSONSerialization`.
    static func dropSecrets(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var cleaned: [String: Any] = [:]
            for (key, inner) in object where !droppedKeys.contains(key.lowercased()) {
                cleaned[key] = dropSecrets(inner)
            }
            return cleaned
        }
        if let array = value as? [Any] { return array.map(dropSecrets) }
        return value
    }
}
