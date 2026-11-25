import Foundation
import Testing

@testable import MoodleMCPCore

/// Answers each request from what it asks for, so that paging at the source (an offset, a
/// page number, the last id seen) is exercised as Moodle would answer it. Every name, id
/// and text it hands out is invented.
actor ScriptedTransport: HTTPTransport {
    private let answer: @Sendable (_ function: String, _ fields: [String: String]) -> Any?
    private let delay: Duration
    private(set) var requests: [[String: String]] = []

    init(delay: Duration = .zero, _ answer: @escaping @Sendable (_ function: String, _ fields: [String: String]) -> Any?) {
        self.answer = answer
        self.delay = delay
    }

    func post(_ url: URL, body: Data) async throws -> (Data, Int) {
        let fields = FakeTransport.decode(body)
        requests.append(fields)
        if delay > .zero { try await Task.sleep(for: delay) }
        let function = fields["wsfunction"] ?? ""
        let value = answer(function, fields) ?? Self.common(function, fields)
        return (try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), 200)
    }

    func get(_ url: URL) async throws -> (Data, Int, String?) {
        if delay > .zero { try await Task.sleep(for: delay) }
        return (Data("PDF".utf8), 200, "application/pdf")
    }

    /// The answers every tool needs: who the token belongs to, the enrolled courses, and
    /// course contents with no module.
    static func common(_ function: String, _ fields: [String: String]) -> Any {
        switch function {
        case "core_webservice_get_site_info": return ["userid": 1001, "fullname": "Test User", "release": "4.5"]
        case "core_enrol_get_users_courses":
            return [
                ["id": 9001, "shortname": "MEA", "fullname": "Módulo de Ejemplo A (26-27)", "category": 50],
                ["id": 9002, "shortname": "TUT", "fullname": "Tutoría de Ejemplo (26-27)", "category": 50],
                ["id": 9100, "shortname": "AJENO", "fullname": "Curso Ajeno Secreto", "category": 12],
            ]
        case "core_course_get_contents": return [Any]()
        default: return ["exception": "x", "errorcode": "unscripted", "message": "no reply scripted"]
        }
    }
}

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, the time
/// limit, and the texts the model reads.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented rows

    private static func padded(_ index: Int) -> String { String(format: "%04d", index) }

    /// Text found in row `index` only, at the start of a short field so no clip removes it.
    private static func marker(_ index: Int) -> String { "Fila \(padded(index)) ·" }

    /// A name about as long as a real activity's.
    private static func name(_ index: Int, _ what: String) -> String {
        "\(marker(index)) \(what) de ejemplo con un nombre largo e inventado"
    }

    /// A long text, as HTML, far longer than a listing keeps.
    private static func html(_ wide: Bool) -> String {
        wide
            ? "<p>" + String(repeating: "Texto inventado para la prueba, <b>con marcas</b>. ", count: 200) + "</p>"
            : "<p>Breve.</p>"
    }

    private static func bounded(_ fields: [String: String], _ name: String, _ fallback: Int) -> Int {
        fields[name].flatMap { Int($0) } ?? fallback
    }

    private static func slice<T>(_ all: [T], from: Int, count: Int) -> [T] {
        Array(all.dropFirst(from).prefix(count))
    }

    // MARK: Listings

    /// One listing tool, and a site that gives it `count` rows in the order the tool lists
    /// them. `row(index)` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        /// False where Moodle gives no total and the tool knows only whether more follow.
        var knowsTotal = true
        var arguments: [String: Value] = [:]
        var allowed: @Sendable (Int) -> Set<Int> = { _ in [9001, 9002] }
        var answer: @Sendable (_ count: Int, _ wide: Bool, _ function: String, _ fields: [String: String]) -> Any?

        var testDescription: String { tool }

        func tools(_ count: Int, wide: Bool = false, workBudget: Duration = ToolCatalog.workBudget) -> MoodleTools {
            let transport = ScriptedTransport { function, fields in answer(count, wide, function, fields) }
            let client = MoodleClient(
                siteURL: testSite, tokenStore: FakeTokenStore(), transport: transport,
                minimumInterval: .zero, retryDelay: .zero, sleep: { _ in })
            return MoodleTools(
                session: MoodleSession(client: client, scope: CourseScope(allowed: allowed(count))),
                binaryPath: "/Users/user/moodle-mcp", workBudget: workBudget)
        }

        func call(_ count: Int, _ extra: [String: Value] = [:], wide: Bool = false) async -> (text: String, isError: Bool) {
            await MoodleMCPCoreTests.call(tools(count, wide: wide), tool, arguments.merging(extra) { _, new in new })
        }

        /// The rows of a site with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(BoundsTests.marker($0)) }
        }

        /// The sentence that places a page, as this listing words it.
        func position(first: Int, last: Int, total: Int) -> String {
            if knowsTotal || last == total {
                let next = last < total ? "Pass offset=\(last) for the next page." : "That is all."
                return "Showing \(first)–\(last) of \(total) \(things). \(next)"
            }
            return "Showing \(first)–\(last) \(things); more exist. Pass offset=\(last) for the next page."
        }
    }

    private static let courses = Listing(
        tool: ToolCatalog.coursesName, things: "courses", limits: ToolCatalog.courseLimitRange,
        defaultLimit: ToolCatalog.defaultCourseLimit, allowed: { Set((0..<$0).map { 20_000 + $0 }) },
        answer: { count, _, function, _ in
            guard function == "core_enrol_get_users_courses" else { return nil }
            return (0..<count).map {
                ["id": 20_000 + $0, "shortname": "C\(padded($0))", "fullname": name($0, "Curso"), "category": 50]
            }
        })

    private static let entries = Listing(
        tool: ToolCatalog.courseContentsName, things: "entries", limits: ToolCatalog.entryLimitRange,
        defaultLimit: ToolCatalog.defaultEntryLimit, arguments: ["courseid": 9001],
        answer: { count, wide, function, fields in
            guard function == "core_course_get_contents", fields["courseid"] == "9001", count > 0 else { return nil }
            let modules: [[String: Any]] = (1..<count).map { index in
                [
                    "id": 300 + index, "instance": index, "modname": "resource", "name": name(index, "Módulo"),
                    "visible": 1, "uservisible": true, "contextid": 500 + index,
                    "url": "https://moodle.example.test/mod/resource/view.php?id=\(300 + index)",
                    "description": html(wide),
                    "dates": [["label": "Abierto:", "timestamp": 1_795_215_540]],
                    "completiondata": ["state": 1, "timecompleted": 1_795_215_540, "isautomatic": false],
                    "contents": (0..<2).map { file in
                        [
                            "type": "file", "filename": "Documento inventado \(padded(index))-\(file).pdf",
                            "filesize": 123_456, "timemodified": 1_795_215_540, "mimetype": "application/pdf",
                            "fileurl": "https://moodle.example.test/webservice/pluginfile.php/\(500 + index)/mod_resource/content/1/Documento%20inventado%20\(padded(index))-\(file).pdf?forcedownload=1",
                        ]
                    },
                ]
            }
            return [["id": 11, "section": 0, "name": name(0, "Sección"), "visible": 1, "summary": html(wide), "modules": modules]]
        })

    private static let assignments = Listing(
        tool: ToolCatalog.assignmentsName, things: "assignments", limits: ToolCatalog.assignmentLimitRange,
        defaultLimit: ToolCatalog.defaultAssignmentLimit,
        answer: { count, wide, function, _ in
            switch function {
            case "mod_assign_get_assignments":
                return ["courses": [["id": 9001, "assignments": (0..<count).map { index in
                    [
                        "id": 700 + index, "cmid": 300 + index, "name": name(index, "Tarea"),
                        "allowsubmissionsfromdate": 1_795_000_000, "duedate": 1_795_215_540 + index * 60,
                        "cutoffdate": 1_795_300_000, "gradingduedate": 1_795_400_000, "grade": 10, "intro": html(wide),
                        "introattachments": [[
                            "filename": "enunciado.pdf", "filesize": 10, "timemodified": 1_795_000_000,
                            "fileurl": "https://moodle.example.test/webservice/pluginfile.php/\(500 + index)/mod_assign/intro/enunciado.pdf",
                        ]],
                    ]
                }]]]
            case "mod_assign_get_submission_status":
                return [
                    "lastattempt": ["submission": ["status": "submitted", "timemodified": 1_795_215_540], "gradingstatus": "graded"],
                    "feedback": ["grade": ["grade": "8.50000", "timemodified": 1_795_215_540], "gradefordisplay": html(wide)],
                ]
            default: return nil
            }
        })

    private static let quizzes = Listing(
        tool: ToolCatalog.quizzesName, things: "quizzes", limits: ToolCatalog.quizLimitRange,
        defaultLimit: ToolCatalog.defaultQuizLimit,
        answer: { count, wide, function, _ in
            switch function {
            case "mod_quiz_get_quizzes_by_courses":
                return ["quizzes": (0..<count).map { index in
                    [
                        "id": 400 + index, "course": 9001, "coursemodule": 300 + index, "name": name(index, "Cuestionario"),
                        "intro": html(wide), "timeopen": 1_795_000_000, "timeclose": 1_795_215_540 + index * 60,
                        "timelimit": 1800, "attempts": 3, "grade": 10, "sumgrades": 20,
                    ]
                }]
            case "mod_quiz_get_user_attempts":
                return ["attempts": (1...3).map {
                    ["id": $0, "attempt": $0, "state": "finished", "timestart": 1_795_215_540, "timefinish": 1_795_215_600, "sumgrades": "15.00000"]
                }]
            default: return nil
            }
        })

    /// Moodle walks action events by the last id seen, at most `limitnum` at a time.
    private static let events = Listing(
        tool: ToolCatalog.eventsName, things: "events", limits: ToolCatalog.eventLimitRange,
        defaultLimit: ToolCatalog.defaultEventLimit,
        arguments: ["from_date": "2026-11-01"],
        answer: { count, wide, function, fields in
            guard function == "core_calendar_get_action_events_by_timesort" else { return nil }
            let after = bounded(fields, "aftereventid", 0)
            let ids = (1...max(count, 1)).filter { $0 <= count && $0 > after }
            let page = Array(ids.prefix(bounded(fields, "limitnum", 20)))
            return [
                "events": page.map { id in
                    [
                        "id": id, "name": name(id - 1, "Entrega"), "course": ["id": 9001], "modulename": "assign",
                        "instance": id, "eventtype": "due", "timesort": 1_795_215_540 + id, "timestart": 1_795_215_540 + id,
                        "overdue": false, "url": "https://moodle.example.test/mod/assign/view.php?id=\(300 + id)",
                        "action": ["name": "Añadir entrega", "actionable": true], "description": html(wide),
                    ] as [String: Any]
                },
                "lastid": page.last ?? 0,
            ]
        })

    private static let notifications = Listing(
        tool: ToolCatalog.notificationsName, things: "notifications", limits: ToolCatalog.notificationLimitRange,
        defaultLimit: ToolCatalog.defaultNotificationLimit, knowsTotal: false,
        answer: { count, wide, function, fields in
            guard function == "message_popup_get_popup_notifications" else { return nil }
            let page = slice(Array(0..<count), from: bounded(fields, "offset", 0), count: bounded(fields, "limit", 20))
            return [
                "notifications": page.map { index in
                    [
                        "id": 5000 + index, "subject": name(index, "Aviso"), "fullmessagehtml": html(wide),
                        "timecreated": 1_795_215_540 - index, "read": false,
                        "contexturl": "https://moodle.example.test/course/view.php?id=9001", "contexturlname": "Curso",
                        "component": "mod_assign", "eventtype": "assign_notification",
                    ] as [String: Any]
                },
                "unreadcount": count,
            ]
        })

    private static let forums = Listing(
        tool: ToolCatalog.forumsName, things: "forums", limits: ToolCatalog.forumLimitRange,
        defaultLimit: ToolCatalog.defaultForumLimit,
        answer: { count, wide, function, _ in
            guard function == "mod_forum_get_forums_by_courses" else { return nil }
            return (0..<count).map { index in
                [
                    "id": 1000 + index, "course": 9001, "cmid": 300 + index, "name": name(index, "Foro"), "type": "general",
                    "intro": html(wide), "numdiscussions": 12, "unreadpostscount": 3, "duedate": 0, "cutoffdate": 0,
                ] as [String: Any]
            }
        })

    /// Moodle pages discussions by page number and page size.
    private static let discussions = Listing(
        tool: ToolCatalog.forumDiscussionsName, things: "discussions", limits: ToolCatalog.discussionLimitRange,
        defaultLimit: ToolCatalog.defaultDiscussionLimit, knowsTotal: false, arguments: ["forumid": 1000],
        answer: { count, wide, function, fields in
            switch function {
            case "mod_forum_get_forums_by_courses":
                return [["id": 1000, "course": 9001, "cmid": 300, "name": "Foro", "type": "general", "intro": ""]]
            case "mod_forum_get_forum_discussions":
                let size = bounded(fields, "perpage", 10)
                let page = slice(Array(0..<count), from: bounded(fields, "page", 0) * size, count: size)
                return ["discussions": page.map { index in
                    [
                        "id": 7000 + index, "discussion": 70 + index, "name": "Duda", "subject": name(index, "Duda"),
                        "userfullname": "Profe Ejemplo", "created": 1_795_215_540, "timemodified": 1_795_215_600,
                        "usermodifiedfullname": "Alumno Ejemplo", "numreplies": 1, "numunread": 0, "pinned": false,
                        "message": html(wide),
                    ] as [String: Any]
                }]
            default: return nil
            }
        })

    private static let posts = Listing(
        tool: ToolCatalog.discussionPostsName, things: "posts", limits: ToolCatalog.postLimitRange,
        defaultLimit: ToolCatalog.defaultPostLimit, arguments: ["discussionid": 70],
        answer: { count, wide, function, _ in
            guard function == "mod_forum_get_discussion_posts" else { return nil }
            return [
                "forumid": 1000, "courseid": 9001,
                "posts": (0..<count).map { index in
                    [
                        "id": 7000 + index, "subject": name(index, "Respuesta"), "message": html(wide),
                        "author": ["id": 5, "fullname": "Profe Ejemplo"], "timecreated": 1_795_215_540 + index,
                        "parentid": 7000, "unread": false,
                        "attachments": [["filename": "a.pdf", "filesize": 5, "url": "https://moodle.example.test/pluginfile.php/503/mod_forum/attachment/\(7000 + index)/a.pdf"]],
                    ] as [String: Any]
                },
            ]
        })

    private static func conversation(_ index: Int, wide: Bool) -> [String: Any] {
        [
            "id": 80 + index, "name": name(index, "Conversación"), "subname": NSNull(), "type": 1, "membercount": 2,
            "unreadcount": 1, "isread": false, "members": [["id": 5, "fullname": "Profe Ejemplo"]],
            "messages": [["id": 1, "useridfrom": 5, "text": html(wide), "timecreated": 1_795_215_540]],
        ]
    }

    private static let conversations = Listing(
        tool: ToolCatalog.conversationsName, things: "conversations", limits: ToolCatalog.conversationLimitRange,
        defaultLimit: ToolCatalog.defaultConversationLimit, knowsTotal: false,
        answer: { count, wide, function, fields in
            guard function == "core_message_get_conversations" else { return nil }
            let page = slice(Array(0..<count), from: bounded(fields, "limitfrom", 0), count: bounded(fields, "limitnum", 20))
            return ["conversations": page.map { conversation($0, wide: wide) }]
        })

    private static let messages = Listing(
        tool: ToolCatalog.conversationGetName, things: "messages", limits: ToolCatalog.messageLimitRange,
        defaultLimit: ToolCatalog.defaultMessageLimit, knowsTotal: false, arguments: ["conversationid": 80],
        answer: { count, wide, function, fields in
            switch function {
            case "core_message_get_conversations":
                return ["conversations": bounded(fields, "limitfrom", 0) == 0 ? [conversation(0, wide: false)] : []]
            case "core_message_get_conversation_messages":
                let page = slice(Array(0..<count), from: bounded(fields, "limitfrom", 0), count: bounded(fields, "limitnum", 20))
                return [
                    "id": 80, "members": [["id": 5, "fullname": "Profe Ejemplo"], ["id": 1001, "fullname": "Test User"]],
                    "messages": page.map { index in
                        ["id": 900 + index, "useridfrom": index % 2 == 0 ? 5 : 1001,
                         "text": "<p>\(marker(index))</p>" + html(wide), "timecreated": 1_795_215_540 - index] as [String: Any]
                    },
                ]
            default: return nil
            }
        })

    private static let grades = Listing(
        tool: ToolCatalog.gradesName, things: "grade items", limits: ToolCatalog.gradeLimitRange,
        defaultLimit: ToolCatalog.defaultGradeLimit, arguments: ["courseid": 9001],
        answer: { count, wide, function, _ in
            guard function == "gradereport_user_get_grade_items" else { return nil }
            return ["usergrades": [[
                "courseid": 9001, "userid": 1001,
                "gradeitems": (0..<count).map { index in
                    [
                        "id": 1 + index, "itemname": name(index, "Calificación"), "itemtype": "mod", "itemmodule": "assign",
                        "cmid": 300 + index, "graderaw": 8.5, "gradeformatted": "8,50", "grademin": 0, "grademax": 10,
                        "rangeformatted": "0,00&ndash;10,00", "percentageformatted": "85,00 %", "weightformatted": "50,00 %",
                        "feedback": html(wide), "gradedategraded": 1_795_215_540, "gradedatesubmitted": 1_795_215_000,
                    ] as [String: Any]
                },
            ]]]
        })

    private static let profileFields = Listing(
        tool: ToolCatalog.profileName, things: "custom fields", limits: ToolCatalog.profileFieldLimitRange,
        defaultLimit: ToolCatalog.defaultProfileFieldLimit,
        answer: { count, wide, function, _ in
            guard function == "core_user_get_users_by_field" else { return nil }
            return [[
                "id": 1001, "city": "Springfield", "email": "user@example.test",
                "customfields": (0..<count).map { index in
                    ["shortname": "campo\(padded(index))", "name": name(index, "Campo"), "value": html(wide), "type": "textarea"]
                },
            ]]
        })

    private static let listings = [
        courses, entries, assignments, quizzes, events, notifications, forums, discussions, posts, conversations,
        messages, grades, profileFields,
    ]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total, wide: true)
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.hasPrefix(listing.position(first: 1, last: listing.defaultLimit, total: total) + "\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage, "\(result.text.utf16.count)")
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(result.text.hasPrefix("{") || result.text.hasPrefix("["), "\(result.text.prefix(200))")
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)], wide: true)
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix(listing.position(first: 1, last: maximum, total: total) + "\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult, "\(result.text.utf16.count)")
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"
                    + listing.position(first: 1, last: maximum, total: total) + "\n\n"),
            "\(over.text.prefix(300))")
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(
            under.text.hasPrefix(
                "limit=0 is outside 1–\(maximum); 1 was used.\n" + listing.position(first: 1, last: 1, total: total) + "\n\n"),
            "\(under.text.prefix(300))")
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix(listing.position(first: 1, last: 3, total: 7) + "\n\n"), "\(first.text.prefix(300))")
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix(listing.position(first: 4, last: 6, total: 7) + "\n\n"), "\(second.text.prefix(300))")
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"), "\(last.text.prefix(300))")
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        let expected =
            listing.knowsTotal
            ? "Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"
            : "Nothing at offset=7: the \(listing.things) end before it. That is all.\n\n"
        #expect(past.text.hasPrefix(expected), "\(past.text.prefix(300))")
        #expect(listing.rows(in: past.text, of: 7).isEmpty)

        let negative = await listing.call(7, ["offset": .int(-1), "limit": .int(7)])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"),
            "\(negative.text.prefix(300))")
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A page of rows with long texts says which field was clipped and how to read one in full", arguments: listings)
    private func clippedFieldsAreAnnounced(_ listing: Listing) async {
        let wide = await listing.call(3, wide: true)
        let notices = wide.text.prefix { $0 != "{" && $0 != "[" }
        guard listing.tool != ToolCatalog.coursesName else {
            #expect(notices.isEmpty)
            return
        }
        #expect(notices.contains(" is clipped to \(ToolCatalog.clipWidth) characters in each row. Read one in full with "), "\(notices)")
        let narrow = await listing.call(3)
        #expect(!narrow.text.contains("is clipped"))
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // Course names are not clipped, so a site with absurdly long ones is the case the
        // halving exists for.
        let wide = String(repeating: "w", count: 3000)
        let count = 40
        let listing = Listing(
            tool: ToolCatalog.coursesName, things: "courses", limits: ToolCatalog.courseLimitRange,
            defaultLimit: ToolCatalog.defaultCourseLimit, allowed: { _ in Set((0..<count).map { 20_000 + $0 }) },
            answer: { _, _, function, _ in
                guard function == "core_enrol_get_users_courses" else { return nil }
                return (0..<count).map { ["id": 20_000 + $0, "shortname": "C", "fullname": "\(BoundsTests.marker($0)) \(wide)"] as [String: Any] }
            })
        var offset = 0
        var seen: [Int] = []
        while offset < count {
            let result = await listing.call(count, ["limit": .int(count), "offset": .int(offset)])
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = listing.rows(in: result.text, of: count)
            let last = try #require(shown.last)
            #expect(shown.first == offset && shown.count < count)
            #expect(result.text.hasPrefix(listing.position(first: offset + 1, last: last + 1, total: count) + "\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<count))
    }

    // MARK: One item read in full

    /// A tool's way of reading one item, and the long text it holds.
    private struct Single: Sendable, CustomTestStringConvertible {
        var listing: Listing
        var arguments: [String: Value]
        /// The label of the plain text in the window notices.
        var field: String

        var testDescription: String { "\(listing.tool) \(field)" }
    }

    private static let singles = [
        Single(listing: entries, arguments: ["cmid": 301], field: "description"),
        Single(listing: entries, arguments: ["sectionid": 11], field: "summary"),
        Single(listing: assignments, arguments: ["assignmentid": 700], field: "intro"),
        Single(listing: quizzes, arguments: ["quizid": 400], field: "intro"),
        Single(listing: events, arguments: ["eventid": 1], field: "description"),
        Single(listing: notifications, arguments: ["notificationid": 5000], field: "text"),
        Single(listing: forums, arguments: ["forumid": 1000], field: "intro"),
        Single(listing: posts, arguments: ["postid": 7000], field: "message"),
        Single(listing: messages, arguments: ["messageid": 900], field: "text"),
        Single(listing: grades, arguments: ["itemid": 1], field: "feedback"),
        Single(listing: profileFields, arguments: ["shortname": "campo0000"], field: "value"),
    ]

    /// The window on `field` that `text` holds, from its notice: (first, last, total).
    private func window(of field: String, in text: String) -> (first: Int, last: Int, total: Int)? {
        let pattern = "\(field): characters "
        guard let start = text.range(of: pattern) else { return nil }
        let rest = text[start.upperBound...].prefix { $0 != "." }
        let numbers = rest.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : nil
    }

    @Test("One item's long text comes as one default window, then as windows that chain to the end", arguments: singles)
    private func singleItemWindows(_ single: Single) async throws {
        let first = await single.listing.call(3, single.arguments, wide: true)
        #expect(!first.isError, "\(first.text.prefix(300))")
        let size = ToolCatalog.defaultMaxCharacters
        let opening = try #require(window(of: single.field, in: first.text), "\(first.text.prefix(400))")
        let total = opening.total
        #expect(opening.first == 1 && opening.last == min(size, total))
        if total > size {
            #expect(first.text.contains("\(single.field): characters 1–\(size) of \(total). Pass character_offset=\(size) for the rest."))
        }
        #expect(first.text.utf16.count <= ToolStandard.longestResult)

        var offset = 0
        while offset < total {
            let result = await single.listing.call(
                3, single.arguments.merging(["character_offset": .int(offset), "max_characters": .int(700)]) { _, new in new },
                wide: true)
            let placed = try #require(window(of: single.field, in: result.text), "\(result.text.prefix(400))")
            #expect(placed.first == offset + 1 && placed.last == min(offset + 700, total))
            let next = placed.last < total ? "Pass character_offset=\(placed.last) for the rest." : "That is all."
            #expect(result.text.contains("\(single.field): characters \(offset + 1)–\(placed.last) of \(total). \(next)"))
            offset = placed.last
        }

        let past = await single.listing.call(3, single.arguments.merging(["character_offset": .int(total + 5)]) { _, new in new }, wide: true)
        #expect(past.text.contains("\(single.field): characters 0 of \(total): character_offset=\(total + 5) is past the end. That is all."))
    }

    @Test("max_characters at its maximum is used as asked and fits; one past either end is moved and reported", arguments: singles)
    private func windowSizeBounds(_ single: Single) async {
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        let atMaximum = await single.listing.call(3, single.arguments.merging(["max_characters": .int(maximum)]) { _, new in new }, wide: true)
        #expect(!atMaximum.text.contains("is outside"))
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await single.listing.call(3, single.arguments.merging(["max_characters": .int(maximum + 1)]) { _, new in new }, wide: true)
        #expect(over.text.hasPrefix("max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"))

        let under = await single.listing.call(3, single.arguments.merging(["max_characters": .int(0)]) { _, new in new }, wide: true)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\n"))
    }

    @Test("A short text read in full carries no notice")
    func shortSingleHasNoNotice() async {
        let result = await Self.assignments.call(3, ["assignmentid": 701])
        #expect(result.text.hasPrefix("{"), "\(result.text.prefix(200))")
        #expect(result.text.contains(Self.marker(1)))
    }

    @Test("The windows of a long text join into the whole of it")
    func windowsJoin() async throws {
        let whole = HTMLText.plain(Self.html(true))
        var joined = ""
        var offset = 0
        while offset < whole.count {
            let result = await Self.posts.call(
                1, ["postid": 7000, "character_offset": .int(offset), "max_characters": .int(1000)], wide: true)
            let body = result.text.range(of: "\n\n{").map { String(result.text[result.text.index(before: $0.upperBound)...]) } ?? result.text
            let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let post = try #require(json["post"] as? [String: Any])
            let window = try #require(post["message"] as? String)
            #expect(!window.isEmpty)
            joined += window
            offset += window.count
        }
        #expect(joined == whole)
    }

    @Test("A module's files and a quiz's attempts beyond those a listing shows are announced")
    func nestedRowsAreAnnounced() async {
        let quizzes = await Self.quizzes.call(2, ["courseid": 9001])
        #expect(!quizzes.text.contains("attempts of the quizzes"))
        // Three attempts each, under a cap of attemptsPerQuiz: only a smaller cap hides some.
        #expect(ToolCatalog.attemptsPerQuiz >= 3)

        let one = await Self.quizzes.call(2, ["quizid": 400, "limit": .int(2)])
        #expect(one.text.hasPrefix("Showing 1–2 of 3 attempts. Pass offset=2 for the next page.\n\n"), "\(one.text.prefix(300))")

        let module = await Self.entries.call(3, ["cmid": 301, "limit": .int(1)])
        #expect(module.text.hasPrefix("Showing 1–1 of 2 files. Pass offset=1 for the next page.\n\n"), "\(module.text.prefix(300))")
    }

    @Test("With an id that pages something else, the default page is of that, and its own size")
    func secondaryDefaults() async {
        let folder = Listing(
            tool: ToolCatalog.courseContentsName, things: "files", limits: ToolCatalog.entryLimitRange,
            defaultLimit: ToolCatalog.defaultFileLimit, arguments: ["courseid": 9001, "cmid": 301],
            answer: { count, _, function, fields in
                guard function == "core_course_get_contents", fields["courseid"] == "9001" else { return nil }
                let files = (0..<count).map { ["type": "file", "filename": "\(BoundsTests.marker($0)).pdf", "filesize": 1] as [String: Any] }
                return [["id": 11, "section": 0, "name": "S", "modules": [["id": 301, "name": "Carpeta", "modname": "folder", "contents": files]]]]
            })
        let total = ToolCatalog.defaultFileLimit + 5
        let result = await folder.call(total)
        #expect(result.text.hasPrefix(folder.position(first: 1, last: ToolCatalog.defaultFileLimit, total: total) + "\n\n"))
        #expect(folder.rows(in: result.text, of: total) == Array(0..<ToolCatalog.defaultFileLimit))
        #expect(ToolCatalog.filesPerModule < ToolCatalog.defaultFileLimit)
        #expect(ToolCatalog.attemptsPerQuiz < ToolCatalog.defaultAttemptLimit)
    }

    @Test("A walk that stops on a full page says more exist and gives no total")
    func eventsWithoutTotal() async {
        let result = await Self.events.call(120)
        let size = ToolCatalog.defaultEventLimit
        #expect(result.text.hasPrefix("Showing 1–\(size) events; more exist. Pass offset=\(size) for the next page.\n\n"))
        let later = await Self.events.call(120, ["offset": 40, "limit": 5])
        #expect(later.text.hasPrefix("Showing 41–45 events; more exist. Pass offset=45 for the next page.\n\n"))
        #expect(Self.events.rows(in: later.text, of: 120) == Array(40..<45))
        // A walk that reaches the last event knows the total, even on a page before it.
        let near = await Self.events.call(120, ["offset": 100, "limit": 5])
        #expect(near.text.hasPrefix("Showing 101–105 of 120 events. Pass offset=105 for the next page.\n\n"))
        let end = await Self.events.call(120, ["offset": 115, "limit": 10])
        #expect(end.text.hasPrefix("Showing 116–120 of 120 events. That is all.\n\n"))
    }

    // MARK: Numbers moved, values refused

    @Test("A renamed or unknown argument is refused with the names the tool takes")
    func unknownArgumentsAreRefused() async {
        let cases: [(Listing, [String: Value], String)] = [
            (Self.events, ["from": "2026-11-01"], "'from' is not an argument of this tool. It takes: character_offset, eventid, from_date, limit, max_characters, offset, to_date."),
            (Self.events, ["to": "2026-11-30"], "'to' is not an argument of this tool."),
            (Self.discussions, ["page": 1], "'page' is not an argument of this tool."),
            (Self.discussions, ["perpage": 10], "'perpage' is not an argument of this tool."),
            (Self.profileFields, ["verbose": true], "'verbose' is not an argument of this tool."),
        ]
        for (listing, arguments, expected) in cases {
            let result = await listing.call(3, arguments)
            #expect(result.isError, "\(listing.tool) \(arguments)")
            #expect(result.text == "UNKNOWN_ARGUMENT: \(expected)" || result.text.contains(expected), "\(result.text)")
        }
        let status = await call(tools(try! fullTransport()), ToolCatalog.statusName, ["x": 1])
        #expect(status.isError && status.text.contains("This tool takes no arguments."))
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let cases: [(Listing, [String: Value], String)] = [
            (Self.posts, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected."),
            (Self.posts, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected."),
            (Self.posts, ["offset": true], "Argument 'offset' is not valid: a whole number was expected."),
            (Self.posts, ["discussionid": "70"], "Argument 'discussionid' is not valid: a whole number was expected."),
            (Self.events, ["from_date": 20261101], "Argument 'from_date' is not valid: text was expected."),
            (Self.profileFields, ["shortname": ["campo0000"]], "Argument 'shortname' is not valid: text was expected."),
            (Self.posts, ["postid": 7000, "max_characters": "all"], "Argument 'max_characters' is not valid"),
        ]
        for (listing, arguments, expected) in cases {
            let result = await listing.call(3, arguments)
            #expect(result.isError, "\(listing.tool) \(arguments)")
            #expect(result.text.contains(expected), "\(listing.tool) \(arguments): \(result.text)")
        }
    }

    @Test("A whole number sent as 3.0 is taken as 3, and a null as not given")
    func lenientForms() async {
        let result = await Self.posts.call(7, ["limit": 3.0, "offset": .null, "postid": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–3 of 7 posts."))
    }

    @Test("An id outside its range is refused, never moved to another one")
    func identifiersAreRefused() async {
        let range = ToolCatalog.identifierRange
        let expected = "a whole number from \(range.lowerBound) to \(range.upperBound) was expected."
        for (listing, name) in [(Self.posts, "discussionid"), (Self.grades, "courseid"), (Self.assignments, "assignmentid"), (Self.entries, "cmid")] {
            for id in [range.lowerBound - 1, range.upperBound + 1] {
                let result = await listing.call(3, [name: .int(id)])
                #expect(result.isError && result.text.contains("Argument '\(name)' is not valid: \(expected)"), "\(name)=\(id): \(result.text)")
            }
        }
        let missing = await Self.posts.call(3, ["postid": 7999])
        #expect(missing.isError && missing.text.contains("discussion 70 has no post 7999"))
    }

    @Test("A date that does not exist, or a range that ends before it starts, is refused")
    func datesAreRefused() async {
        let cases: [([String: Value], String)] = [
            (["from_date": "2026-02-30"], "does not exist"),
            (["from_date": "2026-03-29T02:30"], "does not exist"),
            (["to_date": "2026-13-01"], "does not exist"),
            (["from_date": "mañana"], "is not a date"),
            (["from_date": "2026-11-20T09:00+25:00"], "has no valid offset"),
            (["from_date": "2026-11-21", "to_date": "2026-11-20"], "Argument 'to_date' is not valid: is earlier than from_date."),
        ]
        for (arguments, expected) in cases {
            let result = await Self.events.call(3, arguments)
            #expect(result.isError && result.text.contains(expected), "\(arguments): \(result.text)")
        }
        let echoed = await Self.events.call(3, ["from_date": .string(String(repeating: "9", count: 5000))])
        #expect(echoed.text.count < 400)
    }

    @Test("to_date includes the whole of the day or minute written, and one alone runs to the end")
    func dateRange() async throws {
        let transport = ScriptedTransport { _, _ in nil }
        let client = MoodleClient(
            siteURL: testSite, tokenStore: FakeTokenStore(), transport: transport, minimumInterval: .zero,
            retryDelay: .zero, sleep: { _ in })
        let tools = MoodleTools(session: MoodleSession(client: client, scope: CourseScope(allowed: [9001])))
        _ = await call(tools, ToolCatalog.eventsName, ["from_date": "2026-11-20", "to_date": "2026-11-20"])
        _ = await call(tools, ToolCatalog.eventsName, ["to_date": "2026-11-20T09:00"])
        _ = await call(tools, ToolCatalog.eventsName, ["from_date": "2026-11-20T09:00:00+01:00"])
        let sent = await transport.requests.filter { $0["wsfunction"] == "core_calendar_get_action_events_by_timesort" }
        try #require(sent.count == 3)
        #expect(sent[0]["timesortfrom"] == "1795129200" && sent[0]["timesortto"] == "1795215599")
        #expect(sent[1]["timesortfrom"] == nil && sent[1]["timesortto"] == "1795161659")
        #expect(sent[2]["timesortfrom"] == "1795161600" && sent[2]["timesortto"] == nil)
    }

    // MARK: Searches, hidden rows, time

    @Test("A walk that reaches its ceiling says the scan stopped and how to narrow it")
    func scanStops() async {
        let ceiling = ToolCatalog.scanRequests * ToolCatalog.eventsPerRequest
        let listing = Listing(
            tool: ToolCatalog.eventsName, things: "events", limits: ToolCatalog.eventLimitRange,
            defaultLimit: ToolCatalog.defaultEventLimit, knowsTotal: false,
            answer: { _, _, function, fields in
                guard function == "core_calendar_get_action_events_by_timesort" else { return nil }
                let after = BoundsTests.bounded(fields, "aftereventid", 0)
                // Every event belongs to another course, so none counts towards the page.
                let page = (after + 1...after + 50).map { ["id": $0, "name": "Ajeno", "course": ["id": 9100], "timesort": $0] as [String: Any] }
                return ["events": page, "lastid": after + 50]
            })
        let result = await listing.call(0)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("The scan stopped after \(ceiling) events; more may exist. Narrow by from_date and to_date.\n\n"), "\(result.text.prefix(300))")
        #expect(!result.text.contains("Ajeno"))
    }

    @Test("Rows this server never shows are counted on the page they fall on")
    func hiddenRowsAreCounted() async {
        let transport = ScriptedTransport { function, _ in
            guard function == "core_message_get_conversations" else { return nil }
            var hidden = BoundsTests.conversation(1, wide: false)
            hidden["type"] = 2
            hidden["subname"] = "Curso Ajeno Secreto"
            return ["conversations": [BoundsTests.conversation(0, wide: false), hidden]]
        }
        let client = MoodleClient(
            siteURL: testSite, tokenStore: FakeTokenStore(), transport: transport, minimumInterval: .zero,
            retryDelay: .zero, sleep: { _ in })
        let tools = MoodleTools(session: MoodleSession(client: client, scope: CourseScope(allowed: [9001])))
        let result = await call(tools, ToolCatalog.conversationsName)
        #expect(result.text.hasPrefix("1 of these conversations are group conversations of other courses and are never shown.\n\n"), "\(result.text.prefix(300))")
        #expect(result.text.contains(Self.marker(0)) && !result.text.contains(Self.marker(1)))
    }

    @Test("A call that spends its work budget returns what it has, says it is partial, and where to resume")
    func partialResults() async {
        let assignments = await call(Self.assignments.tools(7, workBudget: .zero), ToolCatalog.assignmentsName)
        #expect(
            assignments.text.hasPrefix(
                "Partial: the time limit was reached after 1 assignments. Narrow by courseid or limit.\nShowing 1–1 of 7 assignments. Pass offset=1 for the next page.\n\n"),
            "\(assignments.text.prefix(300))")
        let quizzes = await call(Self.quizzes.tools(7, workBudget: .zero), ToolCatalog.quizzesName, ["offset": 2])
        #expect(
            quizzes.text.hasPrefix(
                "Partial: the time limit was reached after 1 quizzes. Narrow by courseid or limit.\nShowing 3–3 of 7 quizzes. Pass offset=3 for the next page.\n\n"),
            "\(quizzes.text.prefix(300))")
        let events = await call(Self.events.tools(120, workBudget: .zero), ToolCatalog.eventsName, ["from_date": "2026-11-01", "offset": 60])
        #expect(
            events.text.hasPrefix("Partial: the time limit was reached after 50 events. Narrow by from_date and to_date.\n\n"),
            "\(events.text.prefix(300))")
    }

    @Test("A call past its deadline is answered with an error; the download's says the file may exist")
    func deadline() async throws {
        let transport = ScriptedTransport(delay: .seconds(5)) { _, _ in nil }
        let client = MoodleClient(
            siteURL: testSite, tokenStore: FakeTokenStore(), transport: transport, minimumInterval: .zero,
            retryDelay: .zero, sleep: { _ in })
        let session = MoodleSession(client: client, scope: CourseScope(allowed: [9001]))
        let tools = MoodleTools(session: session, callTimeLimit: .milliseconds(100))
        let read = await call(tools, ToolCatalog.coursesName)
        #expect(read.isError && read.text.hasPrefix("TIMED_OUT: The call did not finish within 0 seconds"))
        #expect(read.text.contains("Nothing was changed"))
        let download = await call(
            tools, ToolCatalog.fileDownloadName,
            ["courseid": 9001, "url": "https://moodle.example.test/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf"])
        #expect(download.isError && download.text.contains("The file may still have been saved"))
    }

    @Test("The deadlines sit inside the standard's time limit, with room for one request and its retry")
    func deadlinesFit() {
        #expect(ToolCatalog.callTimeLimit <= ToolStandard.timeLimit)
        // A request may take 30 s, and its one retry another 30 s after a 2 s pause.
        #expect(ToolCatalog.workBudget + .seconds(62) < ToolCatalog.callTimeLimit)
    }

    // MARK: Errors

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async throws {
        let name = String(repeating: "n", count: 5000)
        let result = await call(tools(try fullTransport()), name)
        #expect(result.isError)
        #expect(result.text.contains(String(repeating: "n", count: ToolStandard.echoWidth) + "…"))
        #expect(result.text.count < ToolStandard.echoWidth + 80)

        let moodle = MoodleError.moodleException(errorCode: "x", message: String(repeating: "m", count: 50_000))
        #expect(moodle.message.count < MoodleError.quotedWidth + 80)
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let errors: [MoodleError] = [
            .tokenInvalid, .tokenMissing, .tokenNeedsTrust(status: -25308), .keychainFailure(status: -1),
            .functionForbidden("mod_quiz_start_attempt"), .functionNotAllowed("core_course_get_categories"),
            .courseNotAllowed(9100), .noAllowedCourses, .messagingDisabled, .network("URLError -1001"),
            .httpStatus(503), .unexpectedResponse("x"), .configuration("x"), .missingArgument("courseid"),
            .badArgument(name: "limit", reason: "a whole number was expected."),
            .unknownArgument(name: "from", allowed: ["from_date", "to_date", "eventid", "limit", "offset"]),
            .timedOut(seconds: 180, writes: true),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 10, "\(error.code)")
        }
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: MoodleMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema, case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema and description state the limit and offset the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        // Where one id argument turns the page into a page of something else, the default
        // differs between the two, so the schema states none and the description both.
        if [ToolCatalog.courseContentsName, ToolCatalog.quizzesName].contains(listing.tool) {
            #expect(limit["default"] == nil)
            #expect((limit["description"]?.stringValue ?? "").contains("(default \(listing.defaultLimit))"))
        } else {
            #expect(limit["default"]?.intValue == listing.defaultLimit)
        }
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit) to a page") == true)
    }

    @Test("Every window's schema states the range and default the code enforces")
    func schemaStatesTheWindow() {
        for tool in ToolCatalog.all() {
            guard let size = properties(of: tool)["max_characters"] else { continue }
            #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound, "\(tool.name)")
            #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound, "\(tool.name)")
            #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters, "\(tool.name)")
            let offset = properties(of: tool)["character_offset"]
            #expect(offset?["minimum"]?.intValue == 0 && offset?["default"]?.intValue == 0, "\(tool.name)")
            #expect(tool.description?.contains("up to \(ToolCatalog.maxCharactersRange.upperBound)") == true, "\(tool.name)")
        }
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page, window and date a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters", "from_date", "to_date"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "perpage", "page_size", "skip", "start", "from", "to",
            "since", "until", "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    @Test("The instructions state the bounds the code uses")
    func instructionsStateTheBounds() {
        let instructions = MoodleMCPServer.instructions
        #expect(instructions.contains("clipped to \(ToolCatalog.clipWidth) characters"))
        #expect(instructions.contains("after \(ToolCatalog.workBudget.components.seconds) seconds"))
        #expect(instructions.contains("after \(ToolCatalog.callTimeLimit.components.seconds) seconds"))
    }
}

