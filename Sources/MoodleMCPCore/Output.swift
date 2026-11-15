import Foundation

/// Every tool answers with one JSON document. Keys are sorted so the same data always
/// renders the same way; the text passes through `Redaction.scrub` last.
enum Output {
    static func json<T: Encodable>(_ value: T, token: String? = nil) throws(MoodleError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            throw .unexpectedResponse("the answer could not be rendered.")
        }
        return Redaction.scrub(text, token: token)
    }
}

/// The rendered shapes. Each is built from a model, field by field, so nothing Moodle sends
/// reaches an answer unless it is named here.
struct StatusReport: Encodable {
    let server: String
    let serverVersion: String
    let binaryPath: String
    let site: String
    let tokenValid: Bool
    let error: String?
    let moodleRelease: String?
    let userid: Int?
    let name: String?
    let missingFunctions: [String]?
    let allowedCourseCount: Int

    enum CodingKeys: String, CodingKey {
        case server, site, error, userid, name
        case serverVersion = "server_version"
        case binaryPath = "binary_path"
        case tokenValid = "token_valid"
        case moodleRelease = "moodle_release"
        case missingFunctions = "missing_functions"
        case allowedCourseCount = "allowed_course_count"
    }
}

struct CourseRow: Encodable {
    let id: Int
    let fullname: String?
    let shortname: String?

    init(_ course: EnrolledCourse) {
        id = course.id
        fullname = course.fullname
        shortname = course.shortname
    }
}
