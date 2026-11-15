import Foundation

/// What every tool shares: the client, the course scope, and the user id, which Moodle
/// gives only through `site_info` and which is fetched once per process.
public actor MoodleSession {
    public let client: MoodleClient
    public let scope: CourseScope
    private var cachedSiteInfo: SiteInfo?
    private var cachedAllowedCourses: [EnrolledCourse]?
    private var cachedContents: [Int: JSON] = [:]

    public init(client: MoodleClient, scope: CourseScope) {
        self.client = client
        self.scope = scope
    }

    public func siteInfo(refresh: Bool = false) async throws(MoodleError) -> SiteInfo {
        if !refresh, let cachedSiteInfo { return cachedSiteInfo }
        let info: SiteInfo = try await client.call(.siteInfo)
        cachedSiteInfo = info
        return info
    }

    public func userID() async throws(MoodleError) -> Int { try await siteInfo().userid }

    /// Every enrolled course, unfiltered. Only `allowedCourses` and the discovery command
    /// may see this list; tools never render it directly.
    func enrolledCourses() async throws(MoodleError) -> [EnrolledCourse] {
        let userID = try await userID()
        return try await client.call(.usersCourses, [.int("userid", userID)])
    }

    public func allowedCourses() async throws(MoodleError) -> [EnrolledCourse] {
        if let cachedAllowedCourses { return cachedAllowedCourses }
        let courses = try await enrolledCourses().filter { scope.contains($0.id) }.sorted { $0.id < $1.id }
        cachedAllowedCourses = courses
        return courses
    }

    public func course(_ courseID: Int) async throws(MoodleError) -> EnrolledCourse? {
        try await allowedCourses().first { $0.id == courseID }
    }

    /// `core_course_get_contents` for an allowed course. Cached per process only for the
    /// lookups that need it (which module belongs to which course); `course_contents`
    /// itself always asks again, so it shows what is there now.
    public func contents(of courseID: Int, refresh: Bool = false) async throws(MoodleError) -> JSON {
        try scope.validate(courseID)
        if !refresh, let cached = cachedContents[courseID] { return cached }
        let contents = try await client.callJSON(.courseContents, [.int("courseid", courseID)])
        cachedContents[courseID] = contents
        return contents
    }

    /// Module id → course, and module context id → course, over every allowed course.
    /// Used to attribute a notification or a file URL to a course.
    public func moduleIndex() async throws(MoodleError) -> (byModule: [Int: Int], byContext: [Int: Int]) {
        var byModule: [Int: Int] = [:]
        var byContext: [Int: Int] = [:]
        for courseID in scope.allowed.sorted() {
            for section in try await contents(of: courseID).array {
                for module in section["modules"].array {
                    if let id = module["id"].int { byModule[id] = courseID }
                    if let context = module["contextid"].int { byContext[context] = courseID }
                }
            }
        }
        return (byModule, byContext)
    }

    /// For `selftest --discover`, which shows the person the candidates before saving.
    public func courses(inCategory categoryID: Int) async throws(MoodleError) -> [EnrolledCourse] {
        try await enrolledCourses().filter { $0.category == categoryID }.sorted { $0.id < $1.id }
    }
}
