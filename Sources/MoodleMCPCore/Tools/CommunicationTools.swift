import Foundation

/// Forums, conversations and notifications. Every function here was checked against
/// Moodle 4.5's source: none marks anything as read or logs a view.
extension MoodleTools {

    // MARK: forums_list

    func forums(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.optionalIdentifier("courseid")
        let forumID = try arguments.optionalIdentifier("forumid")
        let page = try arguments.page(defaultLimit: ToolCatalog.defaultForumLimit, limits: ToolCatalog.forumLimitRange)
        let window = try arguments.window()
        let courseIDs = try session.scope.resolve(courseID)
        let forums = try await allowedForums(courseIDs).sorted {
            ($0["course"].int ?? 0, $0["id"].int ?? 0) < ($1["course"].int ?? 0, $1["id"].int ?? 0)
        }
        if let forumID {
            guard let forum = forums.first(where: { $0["id"].int == forumID }) else {
                throw .badArgument(name: "forumid", reason: "forum \(forumID) is not in an allowed course. Call forums_list.")
            }
            return Rows.one(
                Self.forum(forum), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices)
        }
        let rows: [Out?] = forums.map(Self.forum)
        let readOne = "forums_list, passing its forumid"
        return Rows.page(
            Array(rows.dropFirst(page.offset)), offset: page.offset, limit: page.limit, extent: .total(rows.count),
            things: "forums", notices: arguments.notices, readOne: ["intro": readOne, "intro_html": readOne],
            render: Out.array)
    }

    private static func forum(_ forum: JSON) -> Out {
        var row: [String: Out] = [
            "id": .int(forum["id"]), "cmid": .int(forum["cmid"]), "courseid": .int(forum["course"]),
            "name": .str(forum["name"]), "type": .str(forum["type"]),
            "discussions": .int(forum["numdiscussions"]), "unread_posts": .int(forum["unreadpostscount"]),
            "due": .date(forum["duedate"]), "cutoff": .date(forum["cutoffdate"]),
        ]
        Out.html(forum["intro"], into: &row, key: "intro")
        return .object(row)
    }

    private func allowedForums(_ courseIDs: [Int]) async throws(MoodleError) -> [JSON] {
        let answer = try await session.client.callJSON(.forums, [.ints("courseids", courseIDs)])
        return answer.array.filter { $0["course"].int.map(session.scope.contains) ?? false }
    }

    // MARK: forum_discussions

    /// Moodle pages discussions by page number and page size only, so the page that holds
    /// `offset` is asked for, and the next one when the range runs into it. The page size
    /// is one more than `limit`, so that a full page also says whether more follow.
    func forumDiscussions(_ arguments: Arguments) async throws(MoodleError) -> String {
        let forumID = try arguments.requiredIdentifier("forumid")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultDiscussionLimit, limits: ToolCatalog.discussionLimitRange)
        // The forum must be one of an allowed course's; Moodle's answer does not say which
        // course a discussion is in, so the check is made before asking.
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let forums = try await allowedForums(session.scope.allowed.sorted())
        guard forums.contains(where: { $0["id"].int == forumID }) else {
            throw .badArgument(name: "forumid", reason: "forum \(forumID) is not in an allowed course. Call forums_list.")
        }
        let size = page.limit + 1
        let first = page.offset / size
        let skip = page.offset - first * size
        var discussions = try await discussionPage(forumID, page: first, size: size)
        if skip > 0, discussions.count == size {
            discussions += try await discussionPage(forumID, page: first + 1, size: size)
        }
        let rest = Array(discussions.dropFirst(skip).prefix(size))
        let rows: [Out?] = rest.prefix(page.limit).map(Self.discussion)
        let readOne = "discussion_posts, passing its discussionid and its first_postid as postid"
        return Rows.page(
            rows, offset: page.offset, limit: page.limit, extent: rest.count > page.limit ? .moreAfter : .endsHere,
            things: "discussions", notices: arguments.notices,
            readOne: ["message": readOne, "message_html": readOne]
        ) { .object(["forumid": .int(forumID), "discussions": .array($0)]) }
    }

    private func discussionPage(_ forumID: Int, page: Int, size: Int) async throws(MoodleError) -> [JSON] {
        try await session.client.callJSON(
            .forumDiscussions,
            [.int("forumid", forumID), .value("sortorder", "-1"), .int("page", page), .int("perpage", size)]
        )["discussions"].array
    }

    private static func discussion(_ discussion: JSON) -> Out {
        var row: [String: Out] = [
            "discussionid": .int(discussion["discussion"]), "first_postid": .int(discussion["id"]),
            "subject": .str(discussion["subject"].isNull ? discussion["name"] : discussion["subject"]),
            "author": .str(discussion["userfullname"]), "created": .date(discussion["created"]),
            "last_post": .date(discussion["timemodified"]), "last_author": .str(discussion["usermodifiedfullname"]),
            "replies": .int(discussion["numreplies"]), "unread": .int(discussion["numunread"]),
            "pinned": .bool(discussion["pinned"]),
        ]
        Out.html(discussion["message"], into: &row, key: "message")
        return .object(row)
    }

    // MARK: discussion_posts

    func discussionPosts(_ arguments: Arguments) async throws(MoodleError) -> String {
        let discussionID = try arguments.requiredIdentifier("discussionid")
        let postID = try arguments.optionalIdentifier("postid")
        let page = try arguments.page(defaultLimit: ToolCatalog.defaultPostLimit, limits: ToolCatalog.postLimitRange)
        let window = try arguments.window()
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let answer = try await session.client.callJSON(
            .discussionPosts,
            [.int("discussionid", discussionID), .value("sortby", "created"), .value("sortdirection", "ASC")])
        // The answer names its course; anything outside the list is refused, not shown.
        guard let courseID = answer["courseid"].int, session.scope.contains(courseID) else {
            throw .badArgument(name: "discussionid", reason: "discussion \(discussionID) is not in an allowed course.")
        }
        let posts = answer["posts"].array.sorted {
            ($0["timecreated"].int ?? 0, $0["id"].int ?? 0) < ($1["timecreated"].int ?? 0, $1["id"].int ?? 0)
        }
        let heading: [String: Out] = [
            "discussionid": .int(discussionID), "forumid": .int(answer["forumid"]), "courseid": .int(courseID),
        ]
        if let postID {
            guard let post = posts.first(where: { $0["id"].int == postID }) else {
                throw .badArgument(name: "postid", reason: "discussion \(discussionID) has no post \(postID). Call discussion_posts.")
            }
            return Rows.one(
                Self.post(post), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices
            ) { .object(heading.merging(["post": $0]) { _, new in new }) }
        }
        let rows: [Out?] = posts.map(Self.post)
        let readOne = "discussion_posts, passing its id as postid"
        return Rows.page(
            Array(rows.dropFirst(page.offset)), offset: page.offset, limit: page.limit, extent: .total(rows.count),
            things: "posts", notices: arguments.notices, readOne: ["message": readOne, "message_html": readOne]
        ) { .object(heading.merging(["posts": .array($0)]) { _, new in new }) }
    }

    private static func post(_ post: JSON) -> Out {
        var row: [String: Out] = [
            "id": .int(post["id"]), "parentid": .int(post["parentid"]), "subject": .str(post["subject"]),
            "author": .str(post["author"]["fullname"]), "created": .date(post["timecreated"]),
            "unread": .bool(post["unread"]), "private_reply": .bool(post["isprivatereply"]),
            "deleted": .bool(post["isdeleted"]),
            "attachments": .array(post["attachments"].array.map(attachment)),
        ]
        Out.html(post["message"], into: &row, key: "message")
        return .object(row)
    }

    // MARK: conversations_list / conversation_get

    /// Conversation types in Moodle.
    static let conversationTypes = [1: "individual", 2: "group", 3: "self"]

    /// One page of conversations as Moodle has them, every one, shown or not.
    private func conversationPage(limit: Int, offset: Int) async throws(MoodleError) -> [JSON] {
        let userID = try await session.userID()
        do {
            return try await session.client.callJSON(
                .conversations, [.int("userid", userID), .int("limitfrom", offset), .int("limitnum", limit)]
            )["conversations"].array
        } catch .moodleException(errorCode: "disabled", message: _) {
            throw .messagingDisabled
        }
    }

    /// Group conversations belong to a course group and carry the course's full name as
    /// `subname`; only those naming an allowed course that no other enrolled course shares
    /// are shown. Individual and self conversations belong to no course and are shown.
    private static func isShown(_ conversation: JSON, allowedNames: Set<String>) -> Bool {
        guard conversation["type"].int == 2 else { return true }
        return conversation["subname"].string.map(allowedNames.contains) ?? false
    }

    func conversations(_ arguments: Arguments) async throws(MoodleError) -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultConversationLimit, limits: ToolCatalog.conversationLimitRange)
        let allowedNames = try await session.uniqueAllowedCourseNames()
        let fetched = try await conversationPage(limit: page.limit + 1, offset: page.offset)
        let rows: [Out?] = fetched.prefix(page.limit).map { conversation in
            Self.isShown(conversation, allowedNames: allowedNames) ? Self.conversation(conversation) : nil
        }
        return Rows.page(
            rows, offset: page.offset, limit: page.limit, extent: fetched.count > page.limit ? .moreAfter : .endsHere,
            things: "conversations", notices: arguments.notices,
            readOne: ["text": "conversation_get, passing its id as conversationid", "text_html": "conversation_get, passing its id as conversationid"],
            hidden: { "\($0) of these conversations are group conversations of other courses and are never shown." }
        ) { .object(["conversations": .array($0)]) }
    }

    private static func conversation(_ conversation: JSON) -> Out {
        let members = Dictionary(
            conversation["members"].array.compactMap { member in member["id"].int.map { ($0, member["fullname"].string) } },
            uniquingKeysWith: { first, _ in first })
        var lastRow: Out = .null
        if let last = conversation["messages"].array.first {
            var row: [String: Out] = [
                "from": last["useridfrom"].int.flatMap { members[$0] ?? nil }.map(Out.string) ?? .null,
                "date": .date(last["timecreated"]),
            ]
            Out.html(last["text"], into: &row, key: "text")
            lastRow = .object(row)
        }
        return .object([
            "id": .int(conversation["id"]),
            "type": conversation["type"].int.flatMap { conversationTypes[$0] }.map(Out.string) ?? .null,
            "name": .str(conversation["name"]), "course": .str(conversation["subname"]),
            "members": .array(conversation["members"].array.map { .str($0["fullname"]) }),
            "member_count": .int(conversation["membercount"]),
            "unread": .int(conversation["unreadcount"]), "read": .bool(conversation["isread"]),
            "last_message": lastRow,
        ])
    }

    /// Reads messages without marking them read: the mark-read functions are forbidden,
    /// and `core_message_get_conversation_messages` does not mark.
    func conversation(_ arguments: Arguments, budget: Budget) async throws(MoodleError) -> String {
        let conversationID = try arguments.requiredIdentifier("conversationid")
        let messageID = try arguments.optionalIdentifier("messageid")
        let page = try arguments.page(defaultLimit: ToolCatalog.defaultMessageLimit, limits: ToolCatalog.messageLimitRange)
        let window = try arguments.window()
        // Must be one the list shows. Moodle has no allow-listed call that fetches a single
        // conversation's course, so the list is paged to find it.
        let allowedNames = try await session.uniqueAllowedCourseNames()
        let batch = 50
        var found = false
        var searched = 0
        while searched < ToolCatalog.conversationSearchLimit {
            if searched > 0, budget.isSpent {
                throw .badArgument(
                    name: "conversationid",
                    reason: "the search for it reached the time limit after \(searched) conversations. Try again.")
            }
            let conversations = try await conversationPage(limit: batch, offset: searched)
            searched += conversations.count
            if conversations.contains(where: { $0["id"].int == conversationID && Self.isShown($0, allowedNames: allowedNames) }) {
                found = true
                break
            }
            if conversations.count < batch { break }
        }
        guard found else {
            throw .badArgument(name: "conversationid", reason: "conversation \(conversationID) is not one this server shows. Call conversations_list.")
        }
        let userID = try await session.userID()

        if let messageID {
            let size = 100
            for request in 0..<ToolCatalog.scanRequests {
                if request > 0, budget.isSpent { break }
                let answer = try await messagePage(conversationID, userID: userID, limit: size, offset: request * size)
                let members = Self.members(answer)
                let messages = answer["messages"].array
                if let message = messages.first(where: { $0["id"].int == messageID }) {
                    return Rows.one(
                        Self.message(message, members: members, userID: userID),
                        characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                        notices: arguments.notices
                    ) { .object(["conversationid": .int(conversationID), "message": $0]) }
                }
                if messages.count < size {
                    throw .badArgument(name: "messageid", reason: "conversation \(conversationID) has no message \(messageID).")
                }
            }
            throw .badArgument(
                name: "messageid", reason: "message \(messageID) was not among the newest messages read. Read the conversation in pages to find it.")
        }

        let answer = try await messagePage(conversationID, userID: userID, limit: page.limit + 1, offset: page.offset)
        let members = Self.members(answer)
        let messages = answer["messages"].array
        let rows: [Out?] = messages.prefix(page.limit).map { Self.message($0, members: members, userID: userID) }
        let readOne = "conversation_get, passing its id as messageid"
        return Rows.page(
            rows, offset: page.offset, limit: page.limit, extent: messages.count > page.limit ? .moreAfter : .endsHere,
            things: "messages", notices: arguments.notices, readOne: ["text": readOne, "text_html": readOne]
        ) { .object(["conversationid": .int(conversationID), "newest_first": .bool(true), "messages": .array($0)]) }
    }

    private func messagePage(_ conversationID: Int, userID: Int, limit: Int, offset: Int) async throws(MoodleError) -> JSON {
        try await session.client.callJSON(
            .conversationMessages,
            [.int("currentuserid", userID), .int("convid", conversationID), .int("limitfrom", offset),
             .int("limitnum", limit), .value("newest", "1")])
    }

    private static func members(_ answer: JSON) -> [Int: String?] {
        Dictionary(
            answer["members"].array.compactMap { member in member["id"].int.map { ($0, member["fullname"].string) } },
            uniquingKeysWith: { first, _ in first })
    }

    private static func message(_ message: JSON, members: [Int: String?], userID: Int) -> Out {
        var row: [String: Out] = [
            "id": .int(message["id"]),
            "from": message["useridfrom"].int.flatMap { members[$0] ?? nil }.map(Out.string) ?? .null,
            "from_you": .bool(message["useridfrom"].int.map { JSON.bool($0 == userID) } ?? .null),
            "date": .date(message["timecreated"]),
        ]
        Out.html(message["text"], into: &row, key: "text")
        return .object(row)
    }

    // MARK: notifications_list

    /// Popup notifications attributable to an allowed course. Attribution, in order: a
    /// `courseid` or `cmid` in the notification's custom data, then the context URL
    /// (`course/view.php?id=`, `?course=`, or a module page whose `id` is a module of an
    /// allowed course). A notification that cannot be attributed is not shown; only their
    /// number is reported.
    func notifications(_ arguments: Arguments, budget: Budget) async throws(MoodleError) -> String {
        let notificationID = try arguments.optionalIdentifier("notificationid")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultNotificationLimit, limits: ToolCatalog.notificationLimitRange)
        let window = try arguments.window()
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let userID = try await session.userID()
        let index = try await session.moduleIndex()
        func shown(_ notification: JSON) -> Out? {
            guard let courseID = Self.attribute(notification, modules: index.byModule), session.scope.contains(courseID)
            else { return nil }
            return Self.notification(notification, courseID: courseID)
        }

        if let notificationID {
            let size = 50
            for request in 0..<ToolCatalog.scanRequests {
                if request > 0, budget.isSpent { break }
                let answer = try await notificationPage(userID: userID, limit: size, offset: request * size)
                let notifications = answer["notifications"].array
                if let match = notifications.first(where: { $0["id"].int == notificationID }) {
                    guard let row = shown(match) else { break }
                    return Rows.one(
                        row, characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                        notices: arguments.notices)
                }
                if notifications.count < size { break }
            }
            throw .badArgument(
                name: "notificationid",
                reason: "notification \(notificationID) is not one this server shows among the newest it read. Call notifications_list.")
        }

        let answer = try await notificationPage(userID: userID, limit: page.limit + 1, offset: page.offset)
        let notifications = answer["notifications"].array
        let rows = notifications.prefix(page.limit).map(shown)
        let readOne = "notifications_list, passing its notificationid"
        return Rows.page(
            Array(rows), offset: page.offset, limit: page.limit,
            extent: notifications.count > page.limit ? .moreAfter : .endsHere, things: "notifications",
            notices: arguments.notices, readOne: ["text": readOne, "text_html": readOne],
            hidden: { "\($0) of these notifications belong to no allowed course, or to none that can be told, and are never shown." }
        ) { .object(["unread_count": .int(answer["unreadcount"]), "notifications": .array($0)]) }
    }

    private func notificationPage(userID: Int, limit: Int, offset: Int) async throws(MoodleError) -> JSON {
        try await session.client.callJSON(
            .popupNotifications,
            [.int("useridto", userID), .value("newestfirst", "1"), .int("limit", limit), .int("offset", offset)])
    }

    private static func notification(_ notification: JSON, courseID: Int) -> Out {
        var row: [String: Out] = [
            "id": .int(notification["id"]), "courseid": .int(courseID), "subject": .str(notification["subject"]),
            "date": .date(notification["timecreated"]), "read": .bool(notification["read"]),
            "read_at": .date(notification["timeread"]), "context_url": .url(notification["contexturl"]),
            "context_name": .str(notification["contexturlname"]), "component": .str(notification["component"]),
            "event_type": .str(notification["eventtype"]),
        ]
        let html = notification["fullmessagehtml"].string.flatMap { $0.isEmpty ? nil : $0 }
        if let html {
            Out.html(.string(html), into: &row, key: "text")
        } else {
            row["text"] = .str(notification["fullmessage"].isNull ? notification["smallmessage"] : notification["fullmessage"])
            row["text_html"] = .null
        }
        return .object(row)
    }

    static func attribute(_ notification: JSON, modules: [Int: Int]) -> Int? {
        if let custom = notification["customdata"].string, let data = custom.data(using: .utf8),
            let json = try? JSON.parse(data)
        {
            if let course = json["courseid"].int { return course }
            if let cmid = json["cmid"].int, let course = modules[cmid] { return course }
        }
        guard let raw = notification["contexturl"].string, let url = URLComponents(string: raw) else { return nil }
        let query = Dictionary((url.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
        if url.path.hasSuffix("/course/view.php"), let id = query["id"].flatMap(Int.init) { return id }
        if let course = query["course"].flatMap(Int.init) ?? query["courseid"].flatMap(Int.init) { return course }
        if url.path.contains("/mod/"), let id = query["id"].flatMap(Int.init) { return modules[id] }
        return nil
    }
}
