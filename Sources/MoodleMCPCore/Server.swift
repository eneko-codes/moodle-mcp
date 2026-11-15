import Foundation
import MCP

public enum MoodleMCPServer {

    public static let name = "moodle-mcp"
    public static let version = "0.2.1"

    /// Returned from `initialize`: what per-tool descriptions cannot say once.
    public static let instructions = """
        Read-only access to one Moodle site through its web-service API, limited to an \
        allow-list of courses confirmed by the person.

        NOTHING HERE WRITES. No tool can start, open or review a quiz attempt, see quiz \
        questions or answers, submit or upload anything, post to a forum, send a message, \
        mark anything as read, or record a view or a completion. The web-service functions \
        are a fixed list in code and there is no generic call tool. Messages to teachers \
        are sent by the person from the site itself.

        Only the allowed courses exist for this server. A courseid outside the list is \
        refused, and answers that can mention other courses are filtered before they are \
        returned — other courses are never shown, not even their names.

        Dates are Europe/Madrid: each is an object with "iso" (ISO 8601 with offset) and \
        "fecha_local" (dd/mm/aaaa HH:mm, 24-hour). null means Moodle has no date for it.

        Text fields come twice: plain text with links kept as "text (url)", and the \
        original HTML in a field ending in _html. File URLs never carry a token.

        Workflow: moodle_status first, and whenever a tool fails; courses_list for the \
        course ids the other tools take. course_contents for a course's materials, then \
        file_download with a file's url to save it under ~/Downloads/moodle-mcp/<course>/ \
        — the only thing any tool writes, and only on this Mac. assignments_list and \
        quizzes_list for deadlines, submission state and grades; events_list for what is \
        due between two dates; grades_get for the grade book. forums_list, then \
        forum_discussions, then discussion_posts; conversations_list, then \
        conversation_get (MESSAGING_DISABLED means the site has internal messaging \
        off, so there is nothing to read there); notifications_list. Reading never marks anything as read. \
        profile_get gives only custom profile fields and the city.

        assignments_list and quizzes_list make one request per activity and requests are \
        paced, so asking for every course at once takes a while; pass a courseid when one \
        course is enough.

        An error starting with TOKEN_INVALIDO means Moodle refused the token: it expired, \
        was revoked, or its service lacks access to a function. Tell the person to run \
        `moodle-mcp login` in Terminal. If it persists after a new login, moodle_status \
        lists any needed function the site does not grant, which only the site's \
        administrators can change.
        """

    public static func run(
        configuration: Configuration, tokenStore: (any TokenStore)? = nil,
        transport: (any HTTPTransport)? = nil
    ) async throws {
        let session = try makeSession(configuration: configuration, tokenStore: tokenStore, transport: transport)
        let tools = MoodleTools(session: session)
        let server = Server(
            name: name, version: version, instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op. Leave it that way: a logger writing
        // to stdout would interleave with the JSON-RPC stream.
        Diagnostics.started(version: version)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    public static func makeSession(
        configuration: Configuration, tokenStore: (any TokenStore)? = nil,
        transport: (any HTTPTransport)? = nil, allowsInteraction: Bool = false
    ) throws(MoodleError) -> MoodleSession {
        let store: any TokenStore
        if let tokenStore {
            store = tokenStore
        } else {
            guard let account = configuration.account, !account.isEmpty else {
                // The server still starts, so moodle_status can say what is missing.
                return MoodleSession(
                    client: MoodleClient(
                        siteURL: configuration.siteURL ?? Configuration.unconfiguredSite,
                        tokenStore: UnconfiguredTokenStore(),
                        transport: transport ?? URLSessionTransport()),
                    scope: configuration.scope)
            }
            guard configuration.siteURL != nil else {
                return MoodleSession(
                    client: MoodleClient(
                        siteURL: Configuration.unconfiguredSite, tokenStore: UnconfiguredTokenStore(),
                        transport: transport ?? URLSessionTransport()),
                    scope: configuration.scope)
            }
            store = KeychainTokenStore(account: account, allowsInteraction: allowsInteraction)
        }
        let client = MoodleClient(
            siteURL: configuration.siteURL ?? Configuration.unconfiguredSite, tokenStore: store, transport: transport ?? URLSessionTransport())
        return MoodleSession(client: client, scope: configuration.scope)
    }
}

/// Stands in when no account is configured: every read explains the fix.
struct UnconfiguredTokenStore: TokenStore {
    func readToken() throws(MoodleError) -> String {
        throw .configuration("No site or account is configured. Run `moodle-mcp login` in Terminal first.")
    }
    func writeToken(_ token: String) throws(MoodleError) {}
}
