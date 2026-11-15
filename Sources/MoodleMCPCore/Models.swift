import Foundation

/// The subset of `core_webservice_get_site_info` this program uses. Unlisted keys —
/// `userprivateaccesskey` among them — are never decoded.
public struct SiteInfo: Decodable, Sendable {
    public let sitename: String?
    public let fullname: String?
    public let userid: Int
    public let release: String?
    public let version: String?
    public let functions: [Function]?

    public struct Function: Decodable, Sendable {
        public let name: String
    }

    /// Functions this program calls that the site's service does not grant the token.
    public var missingFunctions: [String] {
        let granted = Set((functions ?? []).map(\.name))
        return WebServiceFunction.allCases.map(\.rawValue).filter { !granted.contains($0) }.sorted()
    }
}

/// One row of `core_enrol_get_users_courses`.
public struct EnrolledCourse: Decodable, Sendable {
    public let id: Int
    public let shortname: String?
    public let fullname: String?
    public let category: Int?
}
