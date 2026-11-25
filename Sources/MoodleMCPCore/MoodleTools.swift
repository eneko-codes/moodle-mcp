import Foundation

/// Routes a `tools/call` to the session and renders the answer. Every answer and every
/// error passes through `Redaction.scrub` before it leaves.
public struct MoodleTools: ToolHandler {
    let session: MoodleSession
    private let binaryPath: String
    /// `~/Downloads/moodle-mcp`, the only place `file_download` writes. A parameter so the
    /// tests write under a temporary directory.
    let downloadsRoot: URL
    /// `ToolCatalog.callTimeLimit` and `ToolCatalog.workBudget`; parameters so the tests
    /// reach both without waiting.
    let callTimeLimit: Duration
    let workBudget: Duration

    public init(
        session: MoodleSession, binaryPath: String = MoodleTools.currentBinaryPath,
        downloadsRoot: URL = MoodleTools.defaultDownloadsRoot,
        callTimeLimit: Duration = ToolCatalog.callTimeLimit, workBudget: Duration = ToolCatalog.workBudget
    ) {
        self.session = session
        self.binaryPath = binaryPath
        self.downloadsRoot = downloadsRoot
        self.callTimeLimit = callTimeLimit
        self.workBudget = workBudget
    }

    public static var defaultDownloadsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/moodle-mcp", isDirectory: true)
    }

    public static var currentBinaryPath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: callTimeLimit) {
            do throws(MoodleError) {
                return Result<String, MoodleError>.success(
                    try await run(parameters.name, Arguments(parameters.arguments), started: started))
            } catch {
                return .failure(error)
            }
        }
        let result =
            outcome
            ?? .failure(
                .timedOut(
                    seconds: Int(callTimeLimit.components.seconds),
                    writes: parameters.name == ToolCatalog.fileDownloadName))
        switch result {
        case .success(let text):
            return ToolOutput(text: session.client.redact(text), isError: false)
        case .failure(let error):
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: session.client.redact(error.message), isError: true)
        }
    }

    /// Plain-text answer of one tool, also used by `selftest`.
    public func run(
        _ name: String, _ arguments: Arguments, started: ContinuousClock.Instant = .now
    ) async throws(MoodleError) -> String {
        guard let allowed = ToolCatalog.argumentNames(of: name) else {
            throw .badArgument(name: "name", reason: "no tool is called '\(ToolStandard.echo(name))'.")
        }
        try arguments.refuseOthers(than: allowed)
        let budget = Budget(started: started, work: workBudget)
        switch name {
        case ToolCatalog.statusName: return try await status()
        case ToolCatalog.coursesName: return try await courses(arguments)
        case ToolCatalog.courseContentsName: return try await courseContents(arguments)
        case ToolCatalog.fileDownloadName: return try await fileDownload(arguments)
        case ToolCatalog.assignmentsName: return try await assignments(arguments, budget: budget)
        case ToolCatalog.quizzesName: return try await quizzes(arguments, budget: budget)
        case ToolCatalog.eventsName: return try await events(arguments, budget: budget)
        case ToolCatalog.notificationsName: return try await notifications(arguments, budget: budget)
        case ToolCatalog.forumsName: return try await forums(arguments)
        case ToolCatalog.forumDiscussionsName: return try await forumDiscussions(arguments)
        case ToolCatalog.discussionPostsName: return try await discussionPosts(arguments)
        case ToolCatalog.conversationsName: return try await conversations(arguments)
        case ToolCatalog.conversationGetName: return try await conversation(arguments, budget: budget)
        case ToolCatalog.gradesName: return try await grades(arguments)
        case ToolCatalog.profileName: return try await profile(arguments)
        default: throw .badArgument(name: "name", reason: "no tool is called '\(ToolStandard.echo(name))'.")
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

    private func courses(_ arguments: Arguments) async throws(MoodleError) -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultCourseLimit, limits: ToolCatalog.courseLimitRange)
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        // Already in id order, which no two courses share.
        let rows: [Out?] = try await session.allowedCourses().map { course in
            .object([
                "id": .int(course.id), "fullname": course.fullname.map(Out.string) ?? .null,
                "shortname": course.shortname.map(Out.string) ?? .null,
            ])
        }
        return Rows.page(
            Array(rows.dropFirst(page.offset)), offset: page.offset, limit: page.limit, extent: .total(rows.count),
            things: "courses", notices: arguments.notices, render: Out.array)
    }
}

/// The time a call has left for starting requests for more items.
struct Budget: Sendable {
    let started: ContinuousClock.Instant
    let work: Duration

    /// True once no request for another item may start.
    var isSpent: Bool { ContinuousClock.now - started >= work }
}
