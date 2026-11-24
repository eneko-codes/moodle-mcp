import Foundation

/// Routes a `tools/call` to the session and renders the answer. Every answer and every
/// error passes through `Redaction.scrub` before it leaves.
public struct MoodleTools: ToolHandler {
    let session: MoodleSession
    private let binaryPath: String
    /// `~/Downloads/moodle-mcp`, the only place `file_download` writes. A parameter so the
    /// tests write under a temporary directory.
    let downloadsRoot: URL

    public init(
        session: MoodleSession, binaryPath: String = MoodleTools.currentBinaryPath,
        downloadsRoot: URL = MoodleTools.defaultDownloadsRoot
    ) {
        self.session = session
        self.binaryPath = binaryPath
        self.downloadsRoot = downloadsRoot
    }

    public static var defaultDownloadsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/moodle-mcp", isDirectory: true)
    }

    public static var currentBinaryPath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            let text = try await run(parameters.name, Arguments(parameters.arguments))
            return ToolOutput(text: session.client.redact(text), isError: false)
        } catch {
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: session.client.redact(error.message), isError: true)
        }
    }

    /// Plain-text answer of one tool, also used by `selftest`.
    public func run(_ name: String, _ arguments: Arguments) async throws(MoodleError) -> String {
        switch name {
        case ToolCatalog.statusName: return try await status()
        case ToolCatalog.coursesName: return try await courses()
        case ToolCatalog.courseContentsName: return try await courseContents(arguments)
        case ToolCatalog.fileDownloadName: return try await fileDownload(arguments)
        case ToolCatalog.assignmentsName: return try await assignments(arguments)
        case ToolCatalog.quizzesName: return try await quizzes(arguments)
        case ToolCatalog.eventsName: return try await events(arguments)
        case ToolCatalog.notificationsName: return try await notifications(arguments)
        case ToolCatalog.forumsName: return try await forums(arguments)
        case ToolCatalog.forumDiscussionsName: return try await forumDiscussions(arguments)
        case ToolCatalog.discussionPostsName: return try await discussionPosts(arguments)
        case ToolCatalog.conversationsName: return try await conversations(arguments)
        case ToolCatalog.conversationGetName: return try await conversation(arguments)
        case ToolCatalog.gradesName: return try await grades(arguments)
        case ToolCatalog.profileName: return try await profile()
        default: throw .badArgument(name: "name", reason: "no tool is called '\(Diagnostics.identifier(name))'.")
        }
    }

    // MARK: Tools

    /// Answers even when the token fails: "why does nothing work" is exactly when it is asked.
    private func status() async throws(MoodleError) -> String {
        let scope = session.scope
        let report: StatusReport
        do {
            let info = try await session.siteInfo(refresh: true)
            report = StatusReport(
                server: MoodleMCPServer.name, serverVersion: MoodleMCPServer.version, binaryPath: binaryPath,
                site: session.client.siteURL.absoluteString, tokenValid: true, error: nil,
                moodleRelease: info.release, userid: info.userid, name: info.fullname,
                missingFunctions: info.missingFunctions, allowedCourseCount: scope.allowed.count)
        } catch {
            report = StatusReport(
                server: MoodleMCPServer.name, serverVersion: MoodleMCPServer.version, binaryPath: binaryPath,
                site: session.client.siteURL.absoluteString, tokenValid: false, error: error.message,
                moodleRelease: nil, userid: nil, name: nil, missingFunctions: nil,
                allowedCourseCount: scope.allowed.count)
        }
        return try Output.json(report)
    }

    private func courses() async throws(MoodleError) -> String {
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        return try Output.json(try await session.allowedCourses().map(CourseRow.init))
    }
}

/// Typed access to a call's arguments.
public struct Arguments: Sendable {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) { self.values = values ?? [:] }

    public func int(_ name: String) throws(MoodleError) -> Int? {
        guard let value = values[name], !value.isNull else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double.rounded() == double { return Int(double) }
        if let string = value.stringValue, let int = Int(string) { return int }
        throw .badArgument(name: name, reason: "expected an integer.")
    }

    public func requiredInt(_ name: String) throws(MoodleError) -> Int {
        guard let value = try int(name) else { throw .missingArgument(name) }
        return value
    }

    /// An integer within bounds, or the default when omitted.
    public func int(_ name: String, default value: Int, range: ClosedRange<Int>) throws(MoodleError) -> Int {
        let given = try int(name) ?? value
        guard range.contains(given) else {
            throw .badArgument(name: name, reason: "must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return given
    }

    public func string(_ name: String) throws(MoodleError) -> String? {
        guard let value = values[name], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw .badArgument(name: name, reason: "expected a string.") }
        return string
    }
}
