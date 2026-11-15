import Foundation

/// Forums, conversations and notifications. Every function here was checked against
/// Moodle 4.5's source: none marks anything as read or logs a view.
extension MoodleTools {

    // MARK: forums_list

    func forums(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseIDs = try session.scope.resolve(try arguments.int("courseid"))
        let forums = try await allowedForums(courseIDs)
        return try Output.json(Out.array(forums.map { forum in
            var row: [String: Out] = [
                "id": .int(forum["id"]), "cmid": .int(forum["cmid"]), "courseid": .int(forum["course"]),
                "name": .str(forum["name"]), "type": .str(forum["type"]),
                "discussions": .int(forum["numdiscussions"]), "unread_posts": .int(forum["unreadpostscount"]),
                "due": .date(forum["duedate"]), "cutoff": .date(forum["cutoffdate"]),
            ]
            Out.html(forum["intro"], into: &row, key: "intro")
            return .object(row)
        }))
    }

    private func allowedForums(_ courseIDs: [Int]) async throws(MoodleError) -> [JSON] {
        let answer = try await session.client.callJSON(.forums, [.ints("courseids", courseIDs)])
        return answer.array.filter { $0["course"].int.map(session.scope.contains) ?? false }
    }

    // MARK: forum_discussions

    func forumDiscussions(_ arguments: Arguments) async throws(MoodleError) -> String {
        let forumID = try arguments.requiredInt("forumid")
        let page = try arguments.int("page", default: 0, range: 0...1000)
        let perPage = try arguments.int("perpage", default: 20, range: 1...100)
        // The forum must be one of an allowed course's; Moodle's answer does not say which
        // course a discussion is in, so the check is made before asking.
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let forums = try await allowedForums(session.scope.allowed.sorted())
        guard forums.contains(where: { $0["id"].int == forumID }) else {
            throw .badArgument(name: "forumid", reason: "forum \(forumID) is not in an allowed course. Call forums_list.")
        }
        let answer = try await session.client.callJSON(
            .forumDiscussions,
            [.int("forumid", forumID), .value("sortorder", "-1"), .int("page", page), .int("perpage", perPage)])
        let rows: [Out] = answer["discussions"].array.map { discussion in
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
        return try Output.json(Out.object(["forumid": .int(forumID), "page": .int(page), "discussions": .array(rows)]))
    }

    // MARK: discussion_posts

    func discussionPosts(_ arguments: Arguments) async throws(MoodleError) -> String {
        let discussionID = try arguments.requiredInt("discussionid")
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let answer = try await session.client.callJSON(
            .discussionPosts,
            [.int("discussionid", discussionID), .value("sortby", "created"), .value("sortdirection", "ASC")])
        // The answer names its course; anything outside the list is refused, not shown.
        guard let courseID = answer["courseid"].int, session.scope.contains(courseID) else {
            throw .badArgument(name: "discussionid", reason: "discussion \(discussionID) is not in an allowed course.")
        }
        let rows: [Out] = answer["posts"].array.map { post in
            var row: [String: Out] = [
                "id": .int(post["id"]), "parentid": .int(post["parentid"]), "subject": .str(post["subject"]),
                "author": .str(post["author"]["fullname"]), "created": .date(post["timecreated"]),
                "unread": .bool(post["unread"]), "private_reply": .bool(post["isprivatereply"]),
                "deleted": .bool(post["isdeleted"]),
                "attachments": .array(post["attachments"].array.map(Self.attachment)),
            ]
            Out.html(post["message"], into: &row, key: "message")
            return .object(row)
        }
        return try Output.json(Out.object([
            "discussionid": .int(discussionID), "forumid": .int(answer["forumid"]), "courseid": .int(courseID),
            "posts": .array(rows),
        ]))
    }

    // MARK: conversations_list / conversation_get

    /// Conversation types in Moodle.
    static let conversationTypes = [1: "individual", 2: "group", 3: "self"]

    /// Group conversations belong to a course group and carry the course's full name as
    /// `subname`; only those naming an allowed course that no other enrolled course shares
    /// are kept. Individual and self conversations belong to no course and are kept.
    private func visibleConversations(limit: Int, offset: Int) async throws(MoodleError) -> [JSON] {
        let userID = try await session.userID()
        let allowedNames = try await session.uniqueAllowedCourseNames()
        let answer: JSON
        do {
            answer = try await session.client.callJSON(
                .conversations, [.int("userid", userID), .int("limitfrom", offset), .int("limitnum", limit)])
        } catch .moodleException(errorCode: "disabled", message: _) {
            throw .messagingDisabled
        }
        return answer["conversations"].array.filter { conversation in
            guard conversation["type"].int == 2 else { return true }
            return conversation["subname"].string.map(allowedNames.contains) ?? false
        }
    }

    func conversations(_ arguments: Arguments) async throws(MoodleError) -> String {
        let limit = try arguments.int("limit", default: 20, range: 1...50)
        let offset = try arguments.int("offset", default: 0, range: 0...10_000)
        let rows: [Out] = try await visibleConversations(limit: limit, offset: offset).map { conversation in
            let members = Dictionary(
                conversation["members"].array.compactMap { member in member["id"].int.map { ($0, member["fullname"].string) } },
                uniquingKeysWith: { first, _ in first })
            let last = conversation["messages"].array.first
            var lastRow: Out = .null
            if let last {
                var row: [String: Out] = [
                    "from": last["useridfrom"].int.flatMap { members[$0] ?? nil }.map(Out.string) ?? .null,
                    "date": .date(last["timecreated"]),
                ]
                Out.html(last["text"], into: &row, key: "text")
                lastRow = .object(row)
            }
            return .object([
                "id": .int(conversation["id"]),
                "type": conversation["type"].int.flatMap { Self.conversationTypes[$0] }.map(Out.string) ?? .null,
                "name": .str(conversation["name"]), "course": .str(conversation["subname"]),
                "members": .array(conversation["members"].array.map { .str($0["fullname"]) }),
                "member_count": .int(conversation["membercount"]),
                "unread": .int(conversation["unreadcount"]), "read": .bool(conversation["isread"]),
                "last_message": lastRow,
            ])
        }
        return try Output.json(Out.object(["offset": .int(offset), "conversations": .array(rows)]))
    }

    /// Reads messages without marking them read: the mark-read functions are forbidden,
    /// and `core_message_get_conversation_messages` does not mark.
    func conversation(_ arguments: Arguments) async throws(MoodleError) -> String {
        let conversationID = try arguments.requiredInt("conversationid")
        let limit = try arguments.int("limit", default: 50, range: 1...100)
        let offset = try arguments.int("offset", default: 0, range: 0...10_000)
        // Must be one the list shows. Moodle has no allow-listed call that fetches a single
        // conversation's course, so the list is paged (up to 500 conversations) to find it.
        var found = false
        for page in 0..<10 {
            let batch = try await visibleConversations(limit: 50, offset: page * 50)
            if batch.contains(where: { $0["id"].int == conversationID }) { found = true; break }
            if batch.isEmpty { break }
        }
        guard found else {
            throw .badArgument(name: "conversationid", reason: "conversation \(conversationID) is not one this server shows. Call conversations_list.")
        }
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(
            .conversationMessages,
            [.int("currentuserid", userID), .int("convid", conversationID), .int("limitfrom", offset),
             .int("limitnum", limit), .value("newest", "1")])
        let members = Dictionary(
            answer["members"].array.compactMap { member in member["id"].int.map { ($0, member["fullname"].string) } },
            uniquingKeysWith: { first, _ in first })
        let rows: [Out] = answer["messages"].array.map { message in
            var row: [String: Out] = [
                "id": .int(message["id"]),
                "from": message["useridfrom"].int.flatMap { members[$0] ?? nil }.map(Out.string) ?? .null,
                "from_you": .bool(message["useridfrom"].int.map { JSON.bool($0 == userID) } ?? .null),
                "date": .date(message["timecreated"]),
            ]
            Out.html(message["text"], into: &row, key: "text")
            return .object(row)
        }
        return try Output.json(Out.object([
            "conversationid": .int(conversationID), "offset": .int(offset), "newest_first": .bool(true),
            "messages": .array(rows),
        ]))
    }

    // MARK: notifications_list

    /// Popup notifications attributable to an allowed course. Attribution, in order: a
    /// `courseid` or `cmid` in the notification's custom data, then the context URL
    /// (`course/view.php?id=`, `?course=`, or a module page whose `id` is a module of an
    /// allowed course). A notification that cannot be attributed is not shown; only their
    /// number is reported.
    func notifications(_ arguments: Arguments) async throws(MoodleError) -> String {
        let limit = try arguments.int("limit", default: 20, range: 1...50)
        let offset = try arguments.int("offset", default: 0, range: 0...10_000)
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(
            .popupNotifications,
            [.int("useridto", userID), .value("newestfirst", "1"), .int("limit", limit), .int("offset", offset)])
        let index = try await session.moduleIndex()
        var rows: [Out] = []
        var hidden = 0
        let all = answer["notifications"].array
        for notification in all {
            guard let courseID = Self.attribute(notification, modules: index.byModule),
                session.scope.contains(courseID)
            else {
                hidden += 1
                continue
            }
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
            rows.append(.object(row))
        }
        return try Output.json(Out.object([
            "offset": .int(offset), "returned_by_moodle": .int(all.count), "hidden_other_or_unattributed": .int(hidden),
            "unread_count": .int(answer["unreadcount"]), "notifications": .array(rows),
        ]))
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
