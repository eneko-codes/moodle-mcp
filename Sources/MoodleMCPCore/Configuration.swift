import Foundation

/// `~/Library/Application Support/moodle-mcp/config.json`.
///
/// It holds every site-specific and identifying value — the site, the Moodle account
/// name, the course ids, the category to discover — so none of them appears in the source,
/// the tests or the fixtures. It never holds the token or the password.
///
/// There is deliberately no default site: `login` asks for it once and saves it here.
public struct Configuration: Codable, Equatable, Sendable {
    public var siteURL: URL?
    /// The Keychain item's account, which is also the Moodle username for `login`.
    public var account: String?
    /// The only courses any tool may read. Empty until `selftest --discover` is confirmed.
    public var allowedCourseIDs: [Int]
    /// The course category `selftest --discover` proposes, remembered from `--category`.
    public var discoverCategoryID: Int?

    public static let keychainService = "com.eneko.moodle-mcp"

    /// Stands in for a site that is not configured yet, so the server can still start and
    /// `moodle_status` can say so. `.invalid` never resolves (RFC 2606), and no request is
    /// made anyway: the token read fails first.
    static let unconfiguredSite = URL(string: "https://moodle.invalid")!

    public init(
        siteURL: URL? = nil, account: String? = nil, allowedCourseIDs: [Int] = [],
        discoverCategoryID: Int? = nil
    ) {
        self.siteURL = siteURL
        self.account = account
        self.allowedCourseIDs = allowedCourseIDs
        self.discoverCategoryID = discoverCategoryID
    }

    /// Hand-written so a file edited by hand may leave out any key and get its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decodeIfPresent(URL.self, forKey: .siteURL)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        allowedCourseIDs = try container.decodeIfPresent([Int].self, forKey: .allowedCourseIDs) ?? []
        discoverCategoryID = try container.decodeIfPresent(Int.self, forKey: .discoverCategoryID)
    }

    /// A site URL as typed by a person: HTTPS only, no query, no trailing slash.
    public static func parseSiteURL(_ text: String) throws(MoodleError) -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil, url.query == nil else {
            throw .badArgument(name: "site", reason: "expected the site's https:// address, such as https://moodle.example.org.")
        }
        return url
    }

    public var scope: CourseScope { CourseScope(allowed: Set(allowedCourseIDs)) }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/moodle-mcp/config.json")
    }

    /// A missing file is the first run, not an error: the defaults apply and nothing is
    /// allowed yet. A file that exists but does not parse is an error, because silently
    /// falling back would discard the confirmed course list.
    public static func load(from url: URL = defaultURL) throws(MoodleError) -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        var configuration: Configuration
        do {
            configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        } catch {
            throw .configuration("\(url.path) could not be read as configuration.")
        }
        // The same rule as at the login prompt: a site edited into the file by hand must
        // not send the password or the token over plain http.
        if let site = configuration.siteURL {
            guard let checked = try? parseSiteURL(site.absoluteString) else {
                throw .configuration("siteURL in \(url.path) must be the site's https:// address.")
            }
            configuration.siteURL = checked
        }
        return configuration
    }

    /// The directory is created `0700` and the file written `0600`: the account name and
    /// the course list are nobody else's business on a shared Mac.
    public func save(to url: URL = defaultURL) throws(MoodleError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(self).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .configuration("\(url.path) could not be written.")
        }
    }
}

/// The course allow-list. Every tool that takes a course id asks `validate` first, and
/// every answer that can mention other courses goes through `contains` before it is
/// rendered, so a course outside the list is never shown — not even its name.
public struct CourseScope: Equatable, Sendable {
    public let allowed: Set<Int>

    public init(allowed: Set<Int>) { self.allowed = allowed }

    public func contains(_ courseID: Int) -> Bool { allowed.contains(courseID) }

    public func validate(_ courseID: Int) throws(MoodleError) {
        guard !allowed.isEmpty else { throw .noAllowedCourses }
        guard allowed.contains(courseID) else { throw .courseNotAllowed(courseID) }
    }

    /// For tools whose course is optional: the one asked for, or every allowed course.
    public func resolve(_ courseID: Int?) throws(MoodleError) -> [Int] {
        if let courseID {
            try validate(courseID)
            return [courseID]
        }
        guard !allowed.isEmpty else { throw .noAllowedCourses }
        return allowed.sorted()
    }
}
