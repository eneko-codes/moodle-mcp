import Foundation

/// One line per event on stderr, the only channel an MCP host captures from a stdio
/// server (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`).
/// stdout is the JSON-RPC stream, so nothing here may ever print to it.
///
/// Sensitive data cannot get in by construction: no function takes a message, an argument
/// or a response. A line carries a fixed event, a tool or web-service function name
/// (checked to be a plain identifier), the *kind* of an error (never its payload, which
/// quotes ids and Moodle's own text) and a duration. The token never reaches this type.
public enum Diagnostics {

    static func started(version: String) {
        emit("info", "started version=\(version)")
    }

    public static func fatal(_ error: Error) {
        emit("fatal", "exiting error=\(kind(of: error))")
    }

    static func toolFailed(_ name: String, error: Error, since start: ContinuousClock.Instant) {
        emit("error", "tool=\(identifier(name)) failed error=\(kind(of: error)) ms=\(milliseconds(since: start))")
    }

    static func request(_ function: String, attempt: Int, outcome: String, since start: ContinuousClock.Instant) {
        emit(
            "info",
            "wsfunction=\(identifier(function)) attempt=\(attempt) outcome=\(identifier(outcome)) ms=\(milliseconds(since: start))"
        )
    }

    /// Client-chosen strings are only echoed when they look like one of our own snake_case
    /// names; anything else, including a newline that would forge a second line, becomes
    /// `invalid`.
    static func identifier(_ raw: String) -> String {
        let isIdentifier =
            !raw.isEmpty && raw.utf8.count <= 80
            && raw.unicodeScalars.allSatisfy {
                ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_"
            }
        return isIdentifier ? raw : "invalid"
    }

    /// `MoodleError.courseNotAllowed` from `courseNotAllowed(9100)`: only what precedes the
    /// first parenthesis, because the associated values are where ids and text live.
    static func kind(of error: Error) -> String {
        if Mirror(reflecting: error).displayStyle == .enum {
            return "\(type(of: error)).\(String(describing: error).prefix { $0 != "(" })"
        }
        let bridged = error as NSError
        return "\(bridged.domain)#\(bridged.code)"
    }

    static func line(
        _ level: String, _ event: String, at date: Date = Date(),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String {
        "\(date.formatted(.iso8601)) \(level) \(ProcessInfo.processInfo.processName)[\(processID)] \(event)\n"
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    // One write per line, so concurrent calls cannot interleave halves of lines. `try?`
    // because a diagnostic must never be able to take the server down.
    private static func emit(_ level: String, _ event: String) {
        try? FileHandle.standardError.write(contentsOf: Data(line(level, event).utf8))
    }
}
