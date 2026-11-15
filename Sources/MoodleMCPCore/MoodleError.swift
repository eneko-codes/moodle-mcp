import Foundation

/// Every failure this program reports. `message` is what a tool returns and what the
/// command line prints; it never carries the token (it is built from fixed text plus
/// values that cannot hold it, and `Redaction` scrubs it again on the way out).
public enum MoodleError: Error, Equatable, Sendable {
    /// Moodle refused the token (`invalidtoken`, `invalidtimedtoken`) or the token's
    /// service lacks access (`accessexception`). A new token is the usual fix; when it is
    /// not, `moodle_status` shows which functions the site withholds.
    case tokenInvalid
    /// No token in the Keychain yet.
    case tokenMissing
    /// The Keychain holds the token but would only hand it over through a dialog. The
    /// server never shows one; the item must be rewritten by this binary.
    case tokenNeedsTrust(status: Int32)
    case keychainFailure(status: Int32)
    case functionForbidden(String)
    case functionNotAllowed(String)
    case courseNotAllowed(Int)
    case noAllowedCourses
    /// Moodle answered with `exception`/`errorcode` in an HTTP 200 body.
    case moodleException(errorCode: String, message: String)
    /// `login/token.php` refused the credentials or the service.
    case loginRefused(errorCode: String, message: String)
    /// The site has internal messaging turned off (`errorcode: disabled`).
    case messagingDisabled
    case network(String)
    case httpStatus(Int)
    case unexpectedResponse(String)
    case configuration(String)
    case missingArgument(String)
    case badArgument(name: String, reason: String)

    /// The stable code at the start of the message, so a caller can branch on it.
    public var code: String {
        switch self {
        case .tokenInvalid: "TOKEN_INVALIDO"
        case .tokenMissing: "TOKEN_MISSING"
        case .tokenNeedsTrust: "TOKEN_NEEDS_TRUST"
        case .keychainFailure: "KEYCHAIN_FAILURE"
        case .functionForbidden: "FUNCTION_FORBIDDEN"
        case .functionNotAllowed: "FUNCTION_NOT_ALLOWED"
        case .courseNotAllowed: "COURSE_NOT_ALLOWED"
        case .noAllowedCourses: "NO_ALLOWED_COURSES"
        case .moodleException: "MOODLE_EXCEPTION"
        case .loginRefused: "LOGIN_REFUSED"
        case .messagingDisabled: "MESSAGING_DISABLED"
        case .network: "NETWORK"
        case .httpStatus: "HTTP_STATUS"
        case .unexpectedResponse: "UNEXPECTED_RESPONSE"
        case .configuration: "CONFIGURATION"
        case .missingArgument: "MISSING_ARGUMENT"
        case .badArgument: "BAD_ARGUMENT"
        }
    }

    public var message: String {
        "\(code): \(detail)"
    }

    private var detail: String {
        switch self {
        case .tokenInvalid:
            // Wording fixed by the project's rules.
            return "Token del aula caducado o revocado: ejecuta `moodle-mcp login`"
        case .tokenMissing:
            return """
                No Moodle token is stored in the Keychain. Run `moodle-mcp login` in \
                Terminal (or `moodle-mcp import-token` if one was stored by other means).
                """
        case .tokenNeedsTrust(let status):
            return """
                The Keychain holds the token but will not release it without a dialog \
                (OSStatus \(status)), and this program never shows one. Run \
                `moodle-mcp import-token` once in Terminal so the item trusts this \
                program.
                """
        case .keychainFailure(let status):
            return "The Keychain returned OSStatus \(status)."
        case .functionForbidden(let name):
            return """
                '\(name)' is forbidden: it would start, open or change a quiz attempt, \
                submit, upload, post, send, mark as read or record a view. This program \
                only reads, and never calls it.
                """
        case .functionNotAllowed(let name):
            return "'\(name)' is not one of the web-service functions this program calls."
        case .courseNotAllowed(let id):
            return """
                Course \(id) is not in the allowed course list. Only the courses confirmed \
                with `moodle-mcp selftest --discover` can be read; call courses_list for \
                their ids.
                """
        case .noAllowedCourses:
            return """
                The allowed course list is empty. Run `moodle-mcp selftest --discover` in \
                Terminal to choose the courses.
                """
        case .moodleException(let errorCode, let message):
            return "Moodle refused the request (\(errorCode)): \(message)"
        case .loginRefused(let errorCode, let message):
            return "Moodle refused the login (\(errorCode)): \(message)"
        case .messagingDisabled:
            return """
                This Moodle site has internal messaging turned off, so there are no \
                conversations to read. This is the site's setting, not a fault here.
                """
        case .network(let reason):
            return "Could not reach Moodle: \(reason)"
        case .httpStatus(let status):
            return "Moodle answered HTTP \(status)."
        case .unexpectedResponse(let reason):
            return "Moodle's answer was not in the expected shape: \(reason)"
        case .configuration(let reason):
            return reason
        case .missingArgument(let name):
            return "Missing required argument '\(name)'."
        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"
        }
    }

    /// The same error with any free text Moodle supplied scrubbed of `token`.
    func redacting(_ token: String) -> MoodleError {
        switch self {
        case .moodleException(let errorCode, let message):
            .moodleException(errorCode: errorCode, message: Redaction.scrub(message, token: token))
        case .loginRefused(let errorCode, let message):
            .loginRefused(errorCode: errorCode, message: Redaction.scrub(message, token: token))
        default: self
        }
    }

    /// Worth one more try after a pause: Moodle's own "come back later" and transport
    /// failures. Nothing that depends on the request's content.
    var isTransient: Bool {
        switch self {
        case .network: true
        case .moodleException(let errorCode, _): errorCode == "servicenotavailable"
        case .httpStatus(let status): status == 502 || status == 503 || status == 504
        default: false
        }
    }
}
