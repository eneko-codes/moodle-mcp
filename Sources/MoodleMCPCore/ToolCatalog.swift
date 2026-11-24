import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Every tool but `file_download` only reads from Moodle, and that one writes only a local
/// file, so none carries a verb prefix. There is deliberately no generic
/// "call a web-service function" tool: each tool names its functions in code.
public enum ToolCatalog {

    public static let statusName = "moodle_status"
    public static let coursesName = "courses_list"
    public static let courseContentsName = "course_contents"
    public static let fileDownloadName = "file_download"
    public static let assignmentsName = "assignments_list"
    public static let quizzesName = "quizzes_list"
    public static let eventsName = "events_list"
    public static let notificationsName = "notifications_list"
    public static let forumsName = "forums_list"
    public static let forumDiscussionsName = "forum_discussions"
    public static let discussionPostsName = "discussion_posts"
    public static let conversationsName = "conversations_list"
    public static let conversationGetName = "conversation_get"
    public static let gradesName = "grades_get"
    public static let profileName = "profile_get"

    public static func all() -> [Tool] {
        [
            status, courses, courseContents, fileDownload, assignments, quizzes, events, notifications, forums,
            forumDiscussions, discussionPosts, conversations, conversationGet, grades, profile,
        ]
    }

    // MARK: Schema helpers

    /// Every `type` is a single string, never a union: Claude Desktop's schema sanitiser
    /// drops a property whose `type` is an array.
    static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ])
    }

    static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static let courseID = integer("A course id from courses_list.", minimum: 1, maximum: 100_000_000)
    static let optionalCourseID = integer(
        "A course id from courses_list. Omit for every allowed course.", minimum: 1, maximum: 100_000_000)

    static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Moodle reachability",
        description: """
            Read-only. Reports whether the stored token still works, the Moodle release, \
            the user id and name the token belongs to, how many courses are allowed, and \
            which of the web-service functions this server needs the site does not grant.

            Call it first, and whenever another tool fails. It never returns the token.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )

    static let courses = Tool(
        name: coursesName,
        title: "Allowed courses",
        description: """
            Read-only. Lists the allowed courses — the ones confirmed for this server — \
            with id, full name and short name. Courses outside that list are never shown.

            Use these ids for every tool that takes a courseid.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )

    static let courseContents = Tool(
        name: courseContentsName,
        title: "Course contents",
        description: """
            Read-only. One allowed course's sections and their modules: type, name, id \
            (cmid), visibility, activity dates, your completion state, and each module's \
            files with name, size, date and URL (no token in it). Section summaries come \
            as plain text with links kept, and the original HTML in a separate field.

            Reading it does not record a view or change completion. Pass a file's url to \
            file_download to save it.
            """,
        inputSchema: object(properties: ["courseid": courseID], required: ["courseid"]),
        annotations: readOnly
    )

    static let fileDownload = Tool(
        name: fileDownloadName,
        title: "Download a course file",
        description: """
            Saves one file of an allowed course to ~/Downloads/moodle-mcp/<course short \
            name>/ and returns its path, size and SHA-256. Writes nothing to Moodle and \
            nowhere else on this Mac; never overwrites (an identical file is reported as \
            already present, a different one gets a numbered name).

            The url must be a file URL from course_contents, assignments_list or \
            discussion_posts, of a module in that course; anything else is refused.
            """,
        inputSchema: object(
            properties: [
                "courseid": courseID,
                "url": string("The file URL exactly as another tool returned it."),
            ], required: ["courseid", "url"]),
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    )

    static let assignments = Tool(
        name: assignmentsName,
        title: "Assignments",
        description: """
            Read-only. Assignments of one or every allowed course: opening, due, cut-off \
            and grading dates, maximum grade, the introduction as plain text (HTML \
            apart) with its attachments, your submission's status and date, and your \
            grade if there is one.

            One request per assignment, so every course at once takes a while. It never \
            submits or saves anything.
            """,
        inputSchema: object(properties: ["courseid": optionalCourseID]),
        annotations: readOnly
    )

    static let quizzes = Tool(
        name: quizzesName,
        title: "Quizzes",
        description: """
            Read-only. Quizzes of one or every allowed course: opening and closing \
            dates, time limit, attempts allowed, maximum grade, and your attempts \
            (state, start, finish, grade). Never questions or answers, and it cannot \
            start, open or review an attempt.
            """,
        inputSchema: object(properties: ["courseid": optionalCourseID]),
        annotations: readOnly
    )

    static let events = Tool(
        name: eventsName,
        title: "Upcoming action events",
        description: """
            Read-only. Calendar action events (deadlines, things to do) of the allowed \
            courses between two moments, sorted by date. Defaults: from now to 30 days \
            ahead. Events of other courses are dropped. At most 200 events per call; \
            truncated: true means there were more, so narrow the range.
            """,
        inputSchema: object(properties: [
            "from": string("Start, inclusive. \(DateArgument.help) Omit for now."),
            "to": string("End, inclusive; a bare date includes that whole day. \(DateArgument.help) Omit for 30 days after now."),
        ]),
        annotations: readOnly
    )

    static let notifications = Tool(
        name: notificationsName,
        title: "Notifications",
        description: """
            Read-only. Your notifications, newest first: subject, text (plain, HTML \
            apart), date, context URL, read or not. Only those attributable to an \
            allowed course are shown; the rest are counted, never shown. Reading does \
            not mark them read.
            """,
        inputSchema: object(properties: [
            "limit": integer("How many Moodle returns per page.", minimum: 1, maximum: 50),
            "offset": integer("Skip this many; use it to page.", minimum: 0, maximum: 10_000),
        ]),
        annotations: readOnly
    )

    static let forums = Tool(
        name: forumsName,
        title: "Forums",
        description: """
            Read-only. Forums of one or every allowed course with id, type, number of \
            discussions, unread posts and dates. Then forum_discussions with a forum id.
            """,
        inputSchema: object(properties: ["courseid": optionalCourseID]),
        annotations: readOnly
    )

    static let forumDiscussions = Tool(
        name: forumDiscussionsName,
        title: "Forum discussions",
        description: """
            Read-only. One page of a forum's discussions, pinned first, then latest activity: \
            discussionid, subject, author, dates, last poster, replies, unread count and \
            the first message (plain text, HTML apart). Then discussion_posts with a \
            discussionid. Cannot post.
            """,
        inputSchema: object(
            properties: [
                "forumid": integer("A forum id from forums_list.", minimum: 1, maximum: 100_000_000),
                "page": integer("Page number, from 0.", minimum: 0, maximum: 1000),
                "perpage": integer("Discussions per page.", minimum: 1, maximum: 100),
            ], required: ["forumid"]),
        annotations: readOnly
    )

    static let discussionPosts = Tool(
        name: discussionPostsName,
        title: "Discussion posts",
        description: """
            Read-only. Every post of one discussion, oldest first: author, date, parent, \
            message as plain text with links kept and the original HTML apart, and \
            attachments. Does not mark posts read. Cannot reply.
            """,
        inputSchema: object(
            properties: ["discussionid": integer("A discussionid from forum_discussions.", minimum: 1, maximum: 100_000_000)],
            required: ["discussionid"]),
        annotations: readOnly
    )

    static let conversations = Tool(
        name: conversationsName,
        title: "Message conversations",
        description: """
            Read-only. Your message conversations, most recent first: members, last \
            message, unread count. Group conversations of courses outside the allowed \
            list are dropped. Then conversation_get with an id. Cannot send.
            """,
        inputSchema: object(properties: [
            "limit": integer("How many conversations.", minimum: 1, maximum: 50),
            "offset": integer("Skip this many; use it to page.", minimum: 0, maximum: 10_000),
        ]),
        annotations: readOnly
    )

    static let conversationGet = Tool(
        name: conversationGetName,
        title: "Conversation messages",
        description: """
            Read-only. Messages of one conversation, newest first, with sender, date \
            and text (plain, HTML apart). Only conversations among the 500 most recent \
            that conversations_list shows can be opened. Does not mark them read. Cannot \
            send: messages to teachers are sent by the person from the site.
            """,
        inputSchema: object(
            properties: [
                "conversationid": integer("An id from conversations_list.", minimum: 1, maximum: 100_000_000),
                "limit": integer("How many messages.", minimum: 1, maximum: 100),
                "offset": integer("Skip this many of the newest; use it to page back.", minimum: 0, maximum: 10_000),
            ], required: ["conversationid"]),
        annotations: readOnly
    )

    static let grades = Tool(
        name: gradesName,
        title: "Grades",
        description: """
            Read-only. Your grade items in one allowed course: name, type, grade, range, \
            percentage, weight, feedback (plain text, HTML apart) and dates.
            """,
        inputSchema: object(properties: ["courseid": courseID], required: ["courseid"]),
        annotations: readOnly
    )

    static let profile = Tool(
        name: profileName,
        title: "Profile fields",
        description: """
            Read-only. Your custom profile fields (for example the exam venue) and your \
            city. Nothing else from the profile is returned.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly
    )
}
