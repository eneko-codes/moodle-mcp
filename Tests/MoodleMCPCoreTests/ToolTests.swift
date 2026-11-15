import Foundation
import MCP
import Testing

typealias MCPValue = MCP.Value

@testable import MoodleMCPCore

/// Synthetic answers in the shape Moodle 4.5 gives. Course 9100 is never allowed: every
/// answer that can mention it does, so the filters are exercised.
enum Answers {
    static let site = "https://moodle.example.test"
    static let tokenURL = "\(site)/webservice/pluginfile.php/501/mod_resource/content/1/Tema%201.pdf?forcedownload=1&token=\(fakeToken)"

    static let contents = """
        [{"id":11,"section":0,"name":"General","visible":1,"summary":"<p>Bienvenida &amp; <a href=\\"https://x.test/guia?token=\(fakeToken)\\">guía</a></p>",
          "modules":[
            {"id":301,"instance":1,"modname":"resource","name":"Tema 1","visible":1,"uservisible":true,"contextid":501,
             "url":"\(site)/mod/resource/view.php?id=301",
             "dates":[{"label":"Abierto:","timestamp":1795215540}],
             "completiondata":{"state":1,"timecompleted":1795215540,"isautomatic":false},
             "contents":[{"type":"file","filename":"Tema 1.pdf","filesize":1234,"timemodified":1795215540,"mimetype":"application/pdf",
               "fileurl":"\(tokenURL)"}]},
            {"id":302,"instance":7,"modname":"assign","name":"Tarea 1","visible":1,"uservisible":true,"contextid":502,
             "url":"\(site)/mod/assign/view.php?id=302","dates":[],"contents":[]}
          ]}]
        """

    static let assignments = """
        {"courses":[
          {"id":9001,"assignments":[{"id":7,"cmid":302,"name":"Tarea 1","allowsubmissionsfromdate":1795215540,"duedate":1795215540,
            "cutoffdate":0,"gradingduedate":0,"grade":10,"intro":"<p>Entrega el <b>informe</b></p>",
            "introattachments":[{"filename":"enunciado.pdf","filesize":10,"timemodified":0,"fileurl":"\(site)/webservice/pluginfile.php/502/mod_assign/intro/enunciado.pdf?token=\(fakeToken)"}]},
            {"id":8,"cmid":303,"name":"Con escala","duedate":0,"grade":-3,"intro":""}]},
          {"id":9100,"assignments":[{"id":99,"cmid":999,"name":"Tarea Ajena","duedate":0,"grade":10,"intro":""}]}]}
        """

    static let submissionStatus = """
        {"lastattempt":{"submission":{"status":"submitted","timemodified":1795215540},"gradingstatus":"graded"},
         "feedback":{"grade":{"grade":"8.50000","timemodified":1795215540},"gradefordisplay":"8,50&nbsp;/&nbsp;10,00"}}
        """

    static let quizzes = """
        {"quizzes":[{"id":40,"course":9001,"coursemodule":304,"name":"Test 1","intro":"<p>Cuestionario</p>","timeopen":1795215540,
           "timeclose":0,"timelimit":1800,"attempts":2,"grade":10,"sumgrades":20},
          {"id":41,"course":9100,"coursemodule":998,"name":"Test Ajeno","timeopen":0,"timeclose":0,"timelimit":0,"attempts":0,"grade":10,"sumgrades":10}]}
        """

    static let attempts = """
        {"attempts":[{"id":1,"attempt":1,"state":"finished","timestart":1795215540,"timefinish":1795215600,"sumgrades":"15.00000",
          "layout":"1,2,0","questions":"must never appear"}]}
        """

    static let events = """
        {"events":[
          {"id":1,"name":"Tarea 1 vence","course":{"id":9001},"modulename":"assign","instance":7,"eventtype":"due","timesort":1795215540,
           "timestart":1795215540,"overdue":false,"url":"\(site)/mod/assign/view.php?id=302","action":{"name":"Añadir entrega","actionable":true},"description":""},
          {"id":2,"name":"Evento Ajeno","course":{"id":9100},"timesort":1795215540},
          {"id":3,"name":"Sin curso","timesort":1795215540}],"firstid":1,"lastid":3}
        """

    static let notifications = """
        {"notifications":[
          {"id":1,"subject":"Nueva calificación","fullmessagehtml":"<p>Tienes nota</p>","timecreated":1795215540,"read":false,
           "contexturl":"\(site)/mod/assign/view.php?id=302","contexturlname":"Tarea 1","component":"mod_assign","eventtype":"assign_notification"},
          {"id":2,"subject":"Foro","fullmessage":"Texto","timecreated":1795215540,"read":true,"timeread":1795215600,
           "customdata":"{\\"courseid\\":9002}","contexturl":"\(site)/mod/forum/discuss.php?d=5"},
          {"id":3,"subject":"Curso Ajeno Secreto: aviso","fullmessage":"x","timecreated":1795215540,"contexturl":"\(site)/course/view.php?id=9100"},
          {"id":4,"subject":"Sin contexto","fullmessage":"y","timecreated":1795215540}],"unreadcount":1}
        """

    static let forums = """
        [{"id":60,"course":9001,"cmid":305,"name":"Foro de dudas","type":"general","intro":"<p>Dudas</p>","numdiscussions":2},
         {"id":61,"course":9100,"cmid":997,"name":"Foro Ajeno","type":"general","intro":""}]
        """

    static let discussions = """
        {"discussions":[{"id":700,"discussion":70,"name":"Duda","subject":"Duda tema 1","userfullname":"Profe Ejemplo","created":1795215540,
          "timemodified":1795215600,"usermodifiedfullname":"Alumno Ejemplo","numreplies":1,"numunread":0,"pinned":false,"message":"<p>¿Cómo?</p>"}]}
        """

    static func posts(course: Int) -> String {
        """
        {"posts":[{"id":700,"subject":"Duda tema 1","message":"<p>Mira <a href=\\"\(site)/webservice/pluginfile.php/503/mod_forum/post/700/a.pdf?token=\(fakeToken)\\">esto</a></p>",
          "author":{"id":5,"fullname":"Profe Ejemplo"},"timecreated":1795215540,"parentid":0,"unread":false,
          "attachments":[{"filename":"a.pdf","filesize":5,"url":"\(site)/pluginfile.php/503/mod_forum/attachment/700/a.pdf"}]}],
         "forumid":60,"courseid":\(course)}
        """
    }

    static let conversations = """
        {"conversations":[
          {"id":80,"name":"","subname":null,"type":1,"membercount":2,"unreadcount":1,"isread":false,
           "members":[{"id":5,"fullname":"Profe Ejemplo"}],"messages":[{"id":1,"useridfrom":5,"text":"<p>Hola</p>","timecreated":1795215540}]},
          {"id":81,"name":"Grupo A","subname":"Módulo de Ejemplo A (26-27)","type":2,"membercount":20,"members":[],"messages":[]},
          {"id":82,"name":"Grupo B","subname":"Curso Ajeno Secreto","type":2,"membercount":20,"members":[],"messages":[]}]}
        """

    static let conversationMessages = """
        {"id":80,"members":[{"id":5,"fullname":"Profe Ejemplo"},{"id":1001,"fullname":"Test User"}],
         "messages":[{"id":2,"useridfrom":1001,"text":"<p>Gracias</p>","timecreated":1795215600},{"id":1,"useridfrom":5,"text":"<p>Hola</p>","timecreated":1795215540}]}
        """

    static let grades = """
        {"usergrades":[{"courseid":9001,"userid":1001,"gradeitems":[
          {"id":1,"itemname":"Tarea 1","itemtype":"mod","itemmodule":"assign","cmid":302,"graderaw":8.5,"gradeformatted":"8,50",
           "grademin":0,"grademax":10,"rangeformatted":"0–10","percentageformatted":"85,00 %","weightformatted":"50,00 %",
           "feedback":"<p>Bien</p>","gradedategraded":1795215540},
          {"id":2,"itemname":null,"itemtype":"course","gradeformatted":"-","grademin":0,"grademax":10}]}]}
        """

    static let users = """
        [{"id":1001,"fullname":"Test User","email":"user@example.test","phone1":"600000000","address":"Calle Falsa 1","city":"Springfield",
          "customfields":[{"type":"text","value":"Sede Ejemplo","displayvalue":"Sede Ejemplo","name":"Exam venue","shortname":"Exam_venue"}]}]
        """
}

func fullTransport() throws -> FakeTransport {
    FakeTransport([
        "core_webservice_get_site_info": [.body(try fixture("site-info"))],
        "core_enrol_get_users_courses": [.body(try fixture("users-courses"))],
        "core_course_get_contents": [json(Answers.contents)],
        "core_course_get_contents|courseid=9002": [json("[]")],
        "mod_assign_get_assignments": [json(Answers.assignments)],
        "mod_assign_get_submission_status": [json(Answers.submissionStatus)],
        "mod_quiz_get_quizzes_by_courses": [json(Answers.quizzes)],
        "mod_quiz_get_user_attempts": [json(Answers.attempts)],
        "core_calendar_get_action_events_by_timesort": [json(Answers.events)],
        "message_popup_get_popup_notifications": [json(Answers.notifications)],
        "mod_forum_get_forums_by_courses": [json(Answers.forums)],
        "mod_forum_get_forum_discussions": [json(Answers.discussions)],
        "mod_forum_get_discussion_posts": [json(Answers.posts(course: 9001))],
        "core_message_get_conversations": [json(Answers.conversations)],
        "core_message_get_conversation_messages": [json(Answers.conversationMessages)],
        "gradereport_user_get_grade_items": [json(Answers.grades)],
        "core_user_get_users_by_field": [json(Answers.users)],
    ])
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moodle-mcp-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func tools(_ transport: FakeTransport, downloads: URL? = nil) -> MoodleTools {
    MoodleTools(
        session: MoodleSession(client: makeClient(transport), scope: CourseScope(allowed: [9001, 9002])),
        binaryPath: "/Users/user/moodle-mcp",
        downloadsRoot: downloads ?? FileManager.default.temporaryDirectory.appendingPathComponent("moodle-mcp-unused"))
}

func call(_ tools: MoodleTools, _ name: String, _ arguments: [String: MCPValue] = [:]) async -> (text: String, isError: Bool) {
    let result = await tools.handle(.init(name: name, arguments: arguments))
    let text = result.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined()
    return (text, result.isError ?? false)
}

@Suite("Every tool")
struct EveryToolTests {

    static let calls: [(String, [String: MCPValue])] = [
        (ToolCatalog.statusName, [:]), (ToolCatalog.coursesName, [:]),
        (ToolCatalog.courseContentsName, ["courseid": .int(9001)]),
        (ToolCatalog.assignmentsName, [:]), (ToolCatalog.quizzesName, [:]),
        (ToolCatalog.eventsName, ["from": .string("2026-11-01"), "to": .string("2026-12-31")]),
        (ToolCatalog.notificationsName, [:]), (ToolCatalog.forumsName, [:]),
        (ToolCatalog.forumDiscussionsName, ["forumid": .int(60)]),
        (ToolCatalog.discussionPostsName, ["discussionid": .int(70)]),
        (ToolCatalog.conversationsName, [:]), (ToolCatalog.conversationGetName, ["conversationid": .int(80)]),
        (ToolCatalog.gradesName, ["courseid": .int(9001)]), (ToolCatalog.profileName, [:]),
    ]

    @Test("Every read tool answers, without the token, token=, the private key or another course")
    func cleanAnswers() async throws {
        let tools = tools(try fullTransport())
        for (name, arguments) in Self.calls {
            let (text, isError) = await call(tools, name, arguments)
            #expect(!isError, "\(name): \(text)")
            #expect(!text.contains(fakeToken), "\(name)")
            #expect(!text.contains("token="), "\(name)")
            #expect(!text.lowercased().contains("userprivateaccesskey"), "\(name)")
            #expect(!text.contains("Ajen"), "\(name) shows another course")
            #expect(!text.contains("9100"), "\(name) shows another course id")
        }
    }

    @Test("The catalogue covers every routed tool")
    func catalogueComplete() {
        #expect(ToolCatalog.all().count == Self.calls.count + 1)
    }
}

@Suite("course_contents and file_download")
struct CourseToolTests {

    @Test("Modules carry type, completion, dates and token-free file URLs")
    func contents() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.courseContentsName, ["courseid": .int(9001)])
        #expect(text.contains("\"state\" : \"complete\""))
        #expect(text.contains("\"fecha_local\" : \"20/11/2026 23:59\""))
        #expect(text.contains("Tema%201.pdf?forcedownload=1\""))
        #expect(text.contains("Bienvenida & guía (https://x.test/guia)"))
    }

    @Test("A course outside the list is refused before any request")
    func refusedBeforeRequest() async throws {
        let transport = try fullTransport()
        let (text, isError) = await call(tools(transport), ToolCatalog.courseContentsName, ["courseid": .int(9100)])
        #expect(isError)
        #expect(text.hasPrefix("COURSE_NOT_ALLOWED"))
        #expect(await transport.sent.isEmpty)
    }

    @Test("A file of the course is saved under its folder; the token goes only to the download")
    func download() async throws {
        let transport = try fullTransport()
        await transport.setFile("/webservice/pluginfile.php/501/mod_resource/content/1/Tema 1.pdf", Data("PDF".utf8))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = tools(transport, downloads: root)
        let url = Redaction.stripToken(from: Answers.tokenURL)
        let (text, isError) = await call(tools, ToolCatalog.fileDownloadName, ["courseid": .int(9001), "url": .string(url)])
        #expect(!isError, "\(text)")
        let saved = root.appendingPathComponent("MEA/Tema 1.pdf")
        #expect(try Data(contentsOf: saved) == Data("PDF".utf8))
        #expect(text.contains("\"sha256\" : \"\(sha("PDF"))\""))
        #expect(!text.contains(fakeToken))
        let fetched = try #require(await transport.downloads.first)
        #expect(URLComponents(url: fetched, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "token" && $0.value == fakeToken } == true)

        let (again, _) = await call(tools, ToolCatalog.fileDownloadName, ["courseid": .int(9001), "url": .string(url)])
        #expect(again.contains("\"already_present\" : true"))
    }

    @Test("A file of another course, another host or not a pluginfile is refused without downloading",
          arguments: [
            "https://moodle.example.test/webservice/pluginfile.php/999/mod_resource/content/1/x.pdf",
            "https://evil.example.test/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf",
            "https://moodle.example.test/mod/resource/view.php?id=301",
            "http://moodle.example.test/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf",
          ])
    func downloadRefused(url: String) async throws {
        let transport = try fullTransport()
        let (text, isError) = await call(tools(transport), ToolCatalog.fileDownloadName, ["courseid": .int(9001), "url": .string(url)])
        #expect(isError, "\(text)")
        #expect(await transport.downloads.isEmpty)
    }

    @Test("A refused download (JSON error body) is not saved")
    func downloadErrorBody() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://moodle.example.test/webservice/pluginfile.php/501/mod_resource/content/1/missing.pdf"
        let (text, isError) = await call(tools(try fullTransport(), downloads: root), ToolCatalog.fileDownloadName,
                                         ["courseid": .int(9001), "url": .string(url)])
        #expect(isError, "\(text)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MEA/missing.pdf").path))
    }

    @Test("Names cannot climb out of the folder")
    func safeNames() {
        #expect(MoodleTools.safeName("../../etc/passwd") == "_.._etc_passwd")
        #expect(MoodleTools.safeName("...") == nil)
        #expect(MoodleTools.safeName("a/b:c") == "a_b_c")
    }
}

@Suite("Assignments, quizzes, events")
struct ActivityToolTests {

    @Test("Assignments show dates, intro as text, submission and grade; scales have no maximum")
    func assignments() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.assignmentsName, [:])
        #expect(text.contains("\"intro\" : \"Entrega el informe\""))
        #expect(text.contains("\"status\" : \"submitted\""))
        #expect(text.contains("\"display\" : \"8,50 / 10,00\""))
        #expect(text.contains("\"cutoff\" : null"))
        #expect(text.contains("\"max_grade\" : null"))
    }

    @Test("Quizzes scale attempt grades and never pass on question data")
    func quizzes() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.quizzesName, [:])
        #expect(text.contains("\"grade\" : 7.5"))
        #expect(text.contains("\"attempts_allowed\" : 2"))
        #expect(!text.contains("must never appear"))
        #expect(!text.contains("layout"))
    }

    @Test("Events of other courses or of no course are dropped")
    func events() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.eventsName, [:])
        #expect(text.contains("Tarea 1 vence"))
        #expect(!text.contains("Sin curso"))
        #expect(text.contains("\"course\" : \"Módulo de Ejemplo A (26-27)\""))
    }

    @Test("Date arguments are Europe/Madrid unless they carry an offset")
    func dateArguments() throws {
        #expect(try DateArgument.parse("2026-11-20T23:59", name: "x") == 1_795_215_540)
        #expect(try DateArgument.parse("2026-11-20T23:59:00+01:00", name: "x") == 1_795_215_540)
        #expect(try DateArgument.parse("2026-06-15T09:05", name: "x") == 1_781_507_100)
        #expect(throws: MoodleError.self) { try DateArgument.parse("2026-02-30", name: "x") }
        #expect(throws: MoodleError.self) { try DateArgument.parse("mañana", name: "x") }
    }
}

@Suite("Forums, conversations, notifications")
struct CommunicationToolTests {

    @Test("A forum of another course is refused")
    func forumRefused() async throws {
        let (text, isError) = await call(tools(try fullTransport()), ToolCatalog.forumDiscussionsName, ["forumid": .int(61)])
        #expect(isError)
        #expect(!text.contains("Ajeno"))
    }

    @Test("Posts of another course are refused even though Moodle answered")
    func postsRefused() async throws {
        let replies = FakeTransport(["mod_forum_get_discussion_posts": [json(Answers.posts(course: 9100))]])
        let (text, isError) = await call(tools(replies), ToolCatalog.discussionPostsName, ["discussionid": .int(70)])
        #expect(isError)
        #expect(!text.contains("Profe"))
    }

    @Test("Posts come as plain text with links, HTML apart, attachments without token")
    func posts() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.discussionPostsName, ["discussionid": .int(70)])
        #expect(text.contains("Mira esto (https://moodle.example.test/webservice/pluginfile.php/503/mod_forum/post/700/a.pdf)"))
        #expect(text.contains("\"message_html\""))
    }

    @Test("Group conversations of other courses are dropped; a hidden one cannot be opened")
    func conversations() async throws {
        let transport = try fullTransport()
        let (list, _) = await call(tools(transport), ToolCatalog.conversationsName, [:])
        #expect(list.contains("Grupo A") && !list.contains("Grupo B"))
        let (hidden, isError) = await call(tools(transport), ToolCatalog.conversationGetName, ["conversationid": .int(82)])
        #expect(isError, "\(hidden)")
        let (messages, _) = await call(tools(transport), ToolCatalog.conversationGetName, ["conversationid": .int(80)])
        #expect(messages.contains("\"from_you\" : true") && messages.contains("Profe Ejemplo"))
    }

    @Test("A site with messaging turned off says so")
    func messagingDisabled() async throws {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [.body(try fixture("site-info"))],
            "core_enrol_get_users_courses": [.body(try fixture("users-courses"))],
            "core_message_get_conversations": [json(#"{"exception":"moodle_exception","errorcode":"disabled","message":"Messaging is disabled"}"#)],
        ])
        let (text, isError) = await call(tools(transport), ToolCatalog.conversationsName, [:])
        #expect(isError && text.hasPrefix("MESSAGING_DISABLED"))
    }

    @Test("Notifications are attributed to allowed courses; the rest only counted")
    func notifications() async throws {
        let (text, _) = await call(tools(try fullTransport()), ToolCatalog.notificationsName, [:])
        #expect(text.contains("Nueva calificación"))
        #expect(text.contains("\"courseid\" : 9002"))
        #expect(!text.contains("Sin contexto"))
        #expect(text.contains("\"hidden_other_or_unattributed\" : 2"))
    }

    @Test("No forbidden function is ever sent by any tool")
    func nothingForbiddenSent() async throws {
        let transport = try fullTransport()
        let tools = tools(transport)
        for (name, arguments) in EveryToolTests.calls { _ = await call(tools, name, arguments) }
        for sent in await transport.sent {
            let function = sent.fields["wsfunction"] ?? ""
            #expect(WebServiceFunction(rawValue: function) != nil, "\(function)")
            #expect(!ForbiddenFunctions.matches(function), "\(function)")
        }
    }
}

@Suite("Grades and profile")
struct PersonalToolTests {

    @Test("Grades list items with formatted grade, range and feedback text")
    func grades() async throws {
        let transport = try fullTransport()
        let (text, _) = await call(tools(transport), ToolCatalog.gradesName, ["courseid": .int(9001)])
        #expect(text.contains("\"percentage\" : \"85,00 %\""))
        #expect(text.contains("\"feedback\" : \"Bien\""))
        #expect(text.contains("\"name\" : \"Course total\""))
        let request = await transport.sent.first { $0.fields["wsfunction"] == "gradereport_user_get_grade_items" }
        #expect(request?.fields["userid"] == "1001")
    }

    @Test("The profile returns custom fields and city, nothing else")
    func profile() async throws {
        let transport = try fullTransport()
        let (text, _) = await call(tools(transport), ToolCatalog.profileName, [:])
        #expect(text.contains("Exam_venue") && text.contains("Springfield"))
        #expect(!text.contains("@") && !text.contains("600000000") && !text.contains("Calle"))
        let request = await transport.sent.first { $0.fields["wsfunction"] == "core_user_get_users_by_field" }
        #expect(request?.fields["field"] == "id" && request?.fields["values[0]"] == "1001")
    }
}

@Suite("HTML to text")
struct HTMLTextTests {

    @Test("Links are kept, entities decoded, blocks become lines")
    func convert() {
        let text = HTMLText.plain("<h3>Título</h3><p>Uno&nbsp;&amp; <a href=\"https://a.test/b\">dos</a></p><ul><li>a</li><li>b</li></ul>&#191;Ok&#x3F;")
        #expect(text == "Título\n\nUno & dos (https://a.test/b)\n\n- a\n- b\n¿Ok?")
    }
}

func sha(_ text: String) -> String {
    // SHA-256 of "PDF", computed with `shasum -a 256`.
    text == "PDF" ? "1d393b0081b632c54654eb08c345ff76b92ae4efe0768b4c0f64b9ebbe920492" : ""
}
