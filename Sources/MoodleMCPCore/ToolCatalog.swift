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

    // MARK: Bounds
    //
    // The schemas, the descriptions and the instructions quote these by interpolation, and
    // `BoundsTests` holds each to the tool standard. Every text field of an answer comes
    // twice, as plain text and as its HTML, so each size below counts both.

    /// Moodle's ids are `BIGINT(10)`. An id outside is refused, never moved, because the
    /// nearest allowed value would name something else.
    public static let identifierRange = 1...9_999_999_999

    public static let offsetRange = 0...1_000_000

    /// Each long text of a listing row, and its HTML beside it, is cut to this many
    /// characters, so a row's size no longer grows with its texts.
    public static let clipWidth = 200

    /// The window on one item's long texts. Each text and its HTML get the same window, so
    /// the default is half a usual page and the maximum a quarter of the longest result;
    /// `ToolStandard.fitting` shrinks the window of an item with more texts than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 4)
    public static let defaultMaxCharacters = ToolStandard.usualPage / 2

    // Pages. Each maximum is a number of rows with every long text at `clipWidth` that
    // fits the longest result, and each default makes an ordinary page about a usual page.
    public static let courseLimitRange = 1...200
    public static let defaultCourseLimit = 50
    public static let entryLimitRange = 1...15
    public static let defaultEntryLimit = 4
    /// Files shown under each module of a course_contents page; a folder can hold hundreds.
    public static let filesPerModule = 5
    /// The page of files of one module read by cmid, whose rows are small.
    public static let defaultFileLimit = entryLimitRange.upperBound
    public static let assignmentLimitRange = 1...15
    public static let defaultAssignmentLimit = 4
    public static let quizLimitRange = 1...15
    public static let defaultQuizLimit = 4
    /// Attempts shown under each quiz of a quizzes_list page.
    public static let attemptsPerQuiz = 5
    /// The page of attempts of one quiz read by quizid, whose rows are small.
    public static let defaultAttemptLimit = quizLimitRange.upperBound
    public static let eventLimitRange = 1...25
    public static let defaultEventLimit = 8
    public static let notificationLimitRange = 1...25
    public static let defaultNotificationLimit = 10
    public static let forumLimitRange = 1...50
    public static let defaultForumLimit = 12
    public static let discussionLimitRange = 1...25
    public static let defaultDiscussionLimit = 9
    public static let postLimitRange = 1...25
    public static let defaultPostLimit = 9
    public static let conversationLimitRange = 1...25
    public static let defaultConversationLimit = 10
    public static let messageLimitRange = 1...50
    public static let defaultMessageLimit = 13
    public static let gradeLimitRange = 1...25
    public static let defaultGradeLimit = 9
    public static let profileFieldLimitRange = 1...100
    public static let defaultProfileFieldLimit = 25

    // Time. Requests are paced 500 ms apart and each may take 30 s, and one more after a
    // transient failure.

    /// A call that has not answered by then is abandoned with an error, inside
    /// `ToolStandard.timeLimit`.
    public static let callTimeLimit = Duration.seconds(180)
    /// No request for another item starts after this much of a call has passed. One request
    /// started just before it, and its retry, end well before `callTimeLimit`.
    public static let workBudget = Duration.seconds(100)
    /// Moodle pages a search for one item, or a walk to an offset, reads before it stops.
    public static let scanRequests = 20
    /// Moodle's own largest page of action events.
    public static let eventsPerRequest = 50
    /// conversation_get opens only a conversation among this many that the list shows.
    public static let conversationSearchLimit = 500

    public static func all() -> [Tool] {
        [
            status, courses, courseContents, fileDownload, assignments, quizzes, events, notifications, forums,
            forumDiscussions, discussionPosts, conversations, conversationGet, grades, profile,
        ]
    }

    /// The argument names `tool` takes, from its schema: the only ones a call may pass.
    static func argumentNames(of tool: String) -> [String]? {
        guard let entry = all().first(where: { $0.name == tool }),
            case .object(let schema) = entry.inputSchema, case .object(let properties)? = schema["properties"]
        else { return nil }
        return Array(properties.keys)
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

    /// A `default` is advertised only where omitting the argument really means that value.
    static func integer(_ description: String, range: ClosedRange<Int>, default value: Int? = nil) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let value { schema["default"] = .int(value) }
        return .object(schema)
    }

    static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func identifier(_ description: String) -> Value { integer(description, range: identifierRange) }

    static let courseID = identifier("A course id from courses_list.")
    static let optionalCourseID = identifier("A course id from courses_list. Omit for every allowed course.")

    static func limit(_ things: String, range: ClosedRange<Int>, default value: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: value)
    }

    static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    static func characterOffset(_ selector: String) -> Value {
        integer(
            """
            With \(selector): number of characters of each long text to skip. A result that \
            does not hold a text whole says, in its first lines, the value to pass for the rest.
            """, range: offsetRange, default: 0)
    }

    static func maxCharacters(_ selector: String) -> Value {
        integer(
            "With \(selector): the most characters of each long text to return.",
            range: maxCharactersRange, default: defaultMaxCharacters)
    }

    /// The sentence every tool with long texts uses for them, from the same constants.
    static func longTexts(_ fields: String, selector: String) -> String {
        """
        \(fields) are clipped to \(clipWidth) characters in each row, both as plain text and \
        as HTML; pass \(selector) to read one in full, a window of max_characters (default \
        \(defaultMaxCharacters), up to \(maxCharactersRange.upperBound)) at a time from \
        character_offset.
        """
    }

    static func paging(_ range: ClosedRange<Int>) -> String {
        """
        When there are more than the page holds, the first lines of the result say so and \
        give the offset of the next page: pass limit (up to \(range.upperBound)) and offset.
        """
    }

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
            \(defaultCourseLimit) to a page in id order, with id, full name and short name. \
            Courses outside that list are never shown. \(paging(courseLimitRange))

            Use these ids for every tool that takes a courseid.
            """,
        inputSchema: object(properties: [
            "limit": limit("courses", range: courseLimitRange, default: defaultCourseLimit),
            "offset": offset,
        ]),
        annotations: readOnly
    )

    static let courseContents = Tool(
        name: courseContentsName,
        title: "Course contents",
        description: """
            Read-only. One allowed course's sections and modules as one list of entries in \
            course order, \(defaultEntryLimit) to a page: a section entry (number, name, \
            visibility, summary), then a module entry for each of its modules (type, name, \
            cmid, visibility, activity dates, your completion state, and its files with \
            name, size, date and URL, no token in it). Each module shows at most \
            \(filesPerModule) files and says how many it has. \(paging(entryLimitRange))

            \(longTexts("Summaries and descriptions", selector: "sectionid or cmid"))

            With cmid, the one module is returned with all its files in Moodle's order, \
            \(defaultFileLimit) to a page unless limit says fewer. With sectionid, the one section.

            Reading it does not record a view or change completion. Pass a file's url to \
            file_download to save it.
            """,
        inputSchema: object(
            properties: [
                "courseid": courseID,
                "cmid": identifier("Return this one module, with its description whole and every file."),
                "sectionid": identifier("Return this one section (its id, not its number), with its summary whole."),
                // No schema default: it is a different number with cmid.
                "limit": integer(
                    "Maximum number of entries in one page (default \(defaultEntryLimit)), or with cmid of files (default \(defaultFileLimit)).",
                    range: entryLimitRange),
                "offset": offset,
                "character_offset": characterOffset("cmid or sectionid"),
                "max_characters": maxCharacters("cmid or sectionid"),
            ], required: ["courseid"]),
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
            Read-only. Assignments of one or every allowed course, \(defaultAssignmentLimit) \
            to a page, soonest due first (none last, then by id): opening, due, cut-off and \
            grading dates, maximum grade, the introduction with its attachments, your \
            submission's status and date, and your grade if there is one. \
            \(paging(assignmentLimitRange))

            \(longTexts("Introductions and grade texts", selector: "assignmentid"))

            One request per assignment on the page, paced, so a call stops starting new ones \
            after \(workBudget.components.seconds) seconds and says it is partial. It never \
            submits or saves anything.
            """,
        inputSchema: object(properties: [
            "courseid": optionalCourseID,
            "assignmentid": identifier("Return this one assignment, with its texts whole."),
            "limit": limit("assignments", range: assignmentLimitRange, default: defaultAssignmentLimit),
            "offset": offset,
            "character_offset": characterOffset("assignmentid"),
            "max_characters": maxCharacters("assignmentid"),
        ]),
        annotations: readOnly
    )

    static let quizzes = Tool(
        name: quizzesName,
        title: "Quizzes",
        description: """
            Read-only. Quizzes of one or every allowed course, \(defaultQuizLimit) to a \
            page, soonest closing first (none last, then by id): opening and closing dates, \
            time limit, attempts allowed, maximum grade, and your attempts (state, start, \
            finish, grade), at most \(attemptsPerQuiz) per quiz with the count of all. Never \
            questions or answers, and it cannot start, open or review an attempt. \
            \(paging(quizLimitRange))

            \(longTexts("Introductions", selector: "quizid"))

            With quizid, the one quiz with all its attempts in attempt order, \
            \(defaultAttemptLimit) to a page unless limit says fewer. One request per quiz on the page, paced, so a call stops \
            starting new ones after \(workBudget.components.seconds) seconds and says it is \
            partial.
            """,
        inputSchema: object(properties: [
            "courseid": optionalCourseID,
            "quizid": identifier("Return this one quiz, with its introduction whole and every attempt."),
            // No schema default: it is a different number with quizid.
            "limit": integer(
                "Maximum number of quizzes in one page (default \(defaultQuizLimit)), or with quizid of attempts (default \(defaultAttemptLimit)).",
                range: quizLimitRange),
            "offset": offset,
            "character_offset": characterOffset("quizid"),
            "max_characters": maxCharacters("quizid"),
        ]),
        annotations: readOnly
    )

    static let events = Tool(
        name: eventsName,
        title: "Upcoming action events",
        description: """
            Read-only. Calendar action events (deadlines, things to do) of the allowed \
            courses, \(defaultEventLimit) to a page by date, then id, from now on with no \
            end. Events of other courses are never shown. from_date and to_date bound the \
            dates, both inclusive; one alone runs to the end, so to_date alone starts at \
            the earliest event. \(paging(eventLimitRange))

            Moodle gives no total: a page gives one when it reaches the last event, and \
            otherwise says whether more exist. Reaching a page walks the events before it, \
            at most \(scanRequests * eventsPerRequest) per call; past that the result says \
            the scan stopped, and a later from_date gets further.

            \(longTexts("Descriptions", selector: "eventid with the same dates"))
            """,
        inputSchema: object(properties: [
            "from_date": string("Earliest date, inclusive. \(DateArgument.help) Omit for now, or with to_date for no start."),
            "to_date": string("Latest date, inclusive: a bare date includes that whole day. \(DateArgument.help) Omit for no end."),
            "eventid": identifier("Return this one event, with its description whole, searched within the dates."),
            "limit": limit("events", range: eventLimitRange, default: defaultEventLimit),
            "offset": offset,
            "character_offset": characterOffset("eventid"),
            "max_characters": maxCharacters("eventid"),
        ]),
        annotations: readOnly
    )

    static let notifications = Tool(
        name: notificationsName,
        title: "Notifications",
        description: """
            Read-only. Your notifications, \(defaultNotificationLimit) to a page, newest \
            first: subject, text, date, context URL, read or not. Only those attributable to \
            an allowed course are shown; the result says how many of the page's are not. \
            Reading does not mark them read. \(paging(notificationLimitRange)) offset counts \
            every notification, shown or not.

            \(longTexts("Texts", selector: "notificationid"))
            """,
        inputSchema: object(properties: [
            "notificationid": identifier("Return this one notification, with its text whole."),
            "limit": limit("notifications", range: notificationLimitRange, default: defaultNotificationLimit),
            "offset": offset,
            "character_offset": characterOffset("notificationid"),
            "max_characters": maxCharacters("notificationid"),
        ]),
        annotations: readOnly
    )

    static let forums = Tool(
        name: forumsName,
        title: "Forums",
        description: """
            Read-only. Forums of one or every allowed course, \(defaultForumLimit) to a page \
            by course, then id, with id, type, number of discussions, unread posts and \
            dates. Then forum_discussions with a forum id. \(paging(forumLimitRange))

            \(longTexts("Introductions", selector: "forumid"))
            """,
        inputSchema: object(properties: [
            "courseid": optionalCourseID,
            "forumid": identifier("Return this one forum, with its introduction whole."),
            "limit": limit("forums", range: forumLimitRange, default: defaultForumLimit),
            "offset": offset,
            "character_offset": characterOffset("forumid"),
            "max_characters": maxCharacters("forumid"),
        ]),
        annotations: readOnly
    )

    static let forumDiscussions = Tool(
        name: forumDiscussionsName,
        title: "Forum discussions",
        description: """
            Read-only. A forum's discussions, \(defaultDiscussionLimit) to a page, pinned \
            first, then latest activity: discussionid, subject, author, dates, last poster, \
            replies, unread count and the first message. Moodle has no total: a page says \
            whether more exist. \(paging(discussionLimitRange))

            The first message is clipped to \(clipWidth) characters, as plain text and as \
            HTML; discussion_posts reads it in full. Cannot post.
            """,
        inputSchema: object(
            properties: [
                "forumid": identifier("A forum id from forums_list."),
                "limit": limit("discussions", range: discussionLimitRange, default: defaultDiscussionLimit),
                "offset": offset,
            ], required: ["forumid"]),
        annotations: readOnly
    )

    static let discussionPosts = Tool(
        name: discussionPostsName,
        title: "Discussion posts",
        description: """
            Read-only. The posts of one discussion, \(defaultPostLimit) to a page, oldest \
            first (then by id): author, date, parent, message and attachments. Does not \
            mark posts read. Cannot reply. \(paging(postLimitRange))

            \(longTexts("Messages", selector: "postid"))
            """,
        inputSchema: object(
            properties: [
                "discussionid": identifier("A discussionid from forum_discussions."),
                "postid": identifier("Return this one post of the discussion, with its message whole."),
                "limit": limit("posts", range: postLimitRange, default: defaultPostLimit),
                "offset": offset,
                "character_offset": characterOffset("postid"),
                "max_characters": maxCharacters("postid"),
            ],
            required: ["discussionid"]),
        annotations: readOnly
    )

    static let conversations = Tool(
        name: conversationsName,
        title: "Message conversations",
        description: """
            Read-only. Your message conversations, \(defaultConversationLimit) to a page, \
            most recent first: members, last message, unread count. Group conversations of \
            courses outside the allowed list are never shown; the result says how many of \
            the page's are not. \(paging(conversationLimitRange)) offset counts every \
            conversation, shown or not.

            The last message is clipped to \(clipWidth) characters, as plain text and as \
            HTML; conversation_get reads it in full. Then conversation_get with an id. \
            Cannot send.
            """,
        inputSchema: object(properties: [
            "limit": limit("conversations", range: conversationLimitRange, default: defaultConversationLimit),
            "offset": offset,
        ]),
        annotations: readOnly
    )

    static let conversationGet = Tool(
        name: conversationGetName,
        title: "Conversation messages",
        description: """
            Read-only. Messages of one conversation, \(defaultMessageLimit) to a page, \
            newest first, with sender, date and text. Moodle has no total: a page says \
            whether more exist. \(paging(messageLimitRange))

            \(longTexts("Texts", selector: "messageid"))

            Only conversations among the \(conversationSearchLimit) most recent that \
            conversations_list shows can be opened. Does not mark them read. Cannot send: \
            messages to teachers are sent by the person from the site.
            """,
        inputSchema: object(
            properties: [
                "conversationid": identifier("An id from conversations_list."),
                "messageid": identifier("Return this one message of the conversation, with its text whole."),
                "limit": limit("messages", range: messageLimitRange, default: defaultMessageLimit),
                "offset": offset,
                "character_offset": characterOffset("messageid"),
                "max_characters": maxCharacters("messageid"),
            ], required: ["conversationid"]),
        annotations: readOnly
    )

    static let grades = Tool(
        name: gradesName,
        title: "Grades",
        description: """
            Read-only. Your grade items in one allowed course, \(defaultGradeLimit) to a \
            page in grade book order: name, type, grade, range, percentage, weight, \
            feedback and dates. \(paging(gradeLimitRange))

            \(longTexts("Feedback texts", selector: "itemid"))
            """,
        inputSchema: object(
            properties: [
                "courseid": courseID,
                "itemid": identifier("Return this one grade item, with its feedback whole."),
                "limit": limit("grade items", range: gradeLimitRange, default: defaultGradeLimit),
                "offset": offset,
                "character_offset": characterOffset("itemid"),
                "max_characters": maxCharacters("itemid"),
            ], required: ["courseid"]),
        annotations: readOnly
    )

    static let profile = Tool(
        name: profileName,
        title: "Profile fields",
        description: """
            Read-only. Your city and your custom profile fields (for example the exam \
            venue), \(defaultProfileFieldLimit) to a page in Moodle's order. Nothing else \
            from the profile is returned. \(paging(profileFieldLimitRange))

            A value longer than \(clipWidth) characters is clipped; pass shortname to read \
            one in full, a window of max_characters (default \(defaultMaxCharacters), up to \
            \(maxCharactersRange.upperBound)) at a time from character_offset.
            """,
        inputSchema: object(properties: [
            "shortname": string("Return this one custom field, by its shortname, with its value whole."),
            "limit": limit("custom fields", range: profileFieldLimitRange, default: defaultProfileFieldLimit),
            "offset": offset,
            "character_offset": characterOffset("shortname"),
            "max_characters": maxCharacters("shortname"),
        ]),
        annotations: readOnly
    )
}
