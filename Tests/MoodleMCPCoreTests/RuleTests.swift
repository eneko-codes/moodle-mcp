import Foundation
import Testing

@testable import MoodleMCPCore

/// One suite per non-negotiable rule. If one of these fails, the build must not ship.
@Suite("Rule 3.1 — only allow-listed, read-only functions")
struct FunctionAllowListTests {

    static let forbidden = [
        "mod_quiz_start_attempt", "mod_quiz_get_attempt_data", "mod_quiz_get_attempt_review",
        "mod_quiz_get_attempt_summary", "mod_quiz_process_attempt", "mod_quiz_save_attempt",
        "mod_assign_save_submission", "mod_assign_submit_for_grading", "core_files_upload",
        "core_message_send_instant_messages", "core_message_send_messages_to_conversation",
        "core_message_mark_message_read", "core_message_mark_all_conversation_messages_as_read",
        "core_message_mark_notification_read", "core_message_mark_all_notifications_as_read",
        "mod_forum_add_discussion", "mod_forum_add_discussion_post",
        "core_course_view_course", "mod_assign_view_assign", "mod_quiz_view_quiz", "mod_forum_view_forum",
        "mod_resource_view_resource", "mod_assign_view_submission_status", "mod_forum_view_forum_discussion",
        "core_completion_update_activity_completion_status_manually",
        "core_user_update_picture", "core_user_update_user_preferences", "core_user_update_users",
    ]

    @Test("Every forbidden function is refused before any request", arguments: forbidden)
    func forbiddenIsRefused(name: String) {
        #expect(throws: MoodleError.functionForbidden(name)) { try WebServiceFunction(validating: name) }
    }

    @Test("Every function named in the rules is in the exact deny list")
    func exactListCoversTheRules() {
        for name in Self.forbidden where !name.contains("_view_") && !name.contains("_mark_")
            && !name.hasPrefix("core_user_update_")
        {
            #expect(ForbiddenFunctions.exact.contains(name), "\(name)")
        }
    }

    @Test("No allow-listed function matches the deny rules")
    func allowListIsClean() {
        for function in WebServiceFunction.allCases {
            #expect(!ForbiddenFunctions.matches(function.rawValue), "\(function.rawValue)")
        }
    }

    @Test("A harmless but unlisted function is refused too")
    func unlistedIsRefused() {
        #expect(throws: MoodleError.functionNotAllowed("core_course_get_categories")) {
            try WebServiceFunction(validating: "core_course_get_categories")
        }
    }

    @Test("Allow-listed names round-trip")
    func allowedNamesValidate() throws {
        for function in WebServiceFunction.allCases {
            #expect(try WebServiceFunction(validating: function.rawValue) == function)
        }
    }

    @Test("The catalogue has no generic call tool; every tool but file_download is read-only")
    func catalogueIsReadOnly() {
        for tool in ToolCatalog.all() {
            // file_download writes a local file under ~/Downloads/moodle-mcp, never to Moodle.
            #expect(tool.annotations.readOnlyHint == (tool.name != ToolCatalog.fileDownloadName), "\(tool.name)")
            #expect(tool.annotations.destructiveHint == false, "\(tool.name)")
            #expect(!tool.name.contains("call") && !tool.name.contains("function"), "\(tool.name)")
        }
    }
}

@Suite("Rule 3.2 — only the allowed courses")
struct CourseScopeTests {

    @Test("A course outside the list is refused")
    func outsideIsRefused() {
        let scope = CourseScope(allowed: [9001])
        #expect(throws: MoodleError.courseNotAllowed(9100)) { try scope.validate(9100) }
        #expect(throws: Never.self) { try scope.validate(9001) }
    }

    @Test("An empty list refuses everything and says how to fill it")
    func emptyRefuses() {
        let scope = CourseScope(allowed: [])
        #expect(throws: MoodleError.noAllowedCourses) { try scope.validate(9001) }
        #expect(throws: MoodleError.noAllowedCourses) { try scope.resolve(nil) }
    }

    @Test("Omitting the course means every allowed course, in order")
    func resolveAll() throws {
        #expect(try CourseScope(allowed: [9002, 9001]).resolve(nil) == [9001, 9002])
    }

    @Test("courses_list never shows another course, not even its name")
    func coursesListFilters() async throws {
        let text = try await makeTools(try standardTransport()).run(ToolCatalog.coursesName, Arguments(nil))
        #expect(text.contains("9001") && text.contains("9002"))
        #expect(!text.contains("9100"))
        #expect(!text.contains("Ajeno"))
    }
}

@Suite("Rule 3.4 — the token never leaves")
struct TokenLeakTests {

    @Test("No tool answer contains the token, token= or userprivateaccesskey")
    func answersAreClean() async throws {
        let tools = makeTools(try standardTransport())
        for name in [ToolCatalog.statusName, ToolCatalog.coursesName] {
            let result = await tools.handle(.init(name: name, arguments: nil))
            let text = result.content.map { "\($0)" }.joined()
            #expect(result.isError == false, "\(name): \(text)")
            #expect(!text.contains(fakeToken), "\(name)")
            #expect(!text.contains("token="), "\(name)")
            #expect(!text.lowercased().contains("userprivateaccesskey"), "\(name)")
            #expect(!text.contains("FAKEprivatekey"), "\(name)")
        }
    }

    @Test("Cleaning drops secret keys at every depth")
    func cleanDropsKeys() throws {
        let cleaned = try MoodleClient.clean(try fixture("site-info"))
        let text = String(decoding: cleaned, as: UTF8.self)
        #expect(!text.contains("userprivateaccesskey"))
        #expect(!text.contains("FAKEprivatekey"))
    }

    @Test("File URLs lose their token parameter")
    func stripToken() {
        #expect(
            Redaction.stripToken(from: "https://h/webservice/pluginfile.php/1/a.pdf?token=abc&forcedownload=1")
                == "https://h/webservice/pluginfile.php/1/a.pdf?forcedownload=1")
        #expect(Redaction.stripToken(from: "https://h/pluginfile.php/1/a.pdf?token=abc") == "https://h/pluginfile.php/1/a.pdf")
    }

    @Test("Scrub removes token parameters and the literal token from free text")
    func scrubText() {
        let text = Redaction.scrub(
            "see https://h/a.pdf?token=abc123&x=1 and \(fakeToken) and https://h/b?wstoken=zz", token: fakeToken)
        #expect(!text.contains("token="))
        #expect(!text.contains(fakeToken))
        #expect(text.contains("https://h/a.pdf?x=1"))
    }

    @Test("The token goes in the body, never in the URL")
    func tokenOnlyInBody() async throws {
        let transport = try standardTransport()
        _ = try await makeClient(transport).callRaw(.siteInfo, [])
        let sent = try #require(await transport.sent.first)
        #expect(!sent.url.absoluteString.contains(fakeToken))
        #expect(sent.url.absoluteString == "https://moodle.example.test/webservice/rest/server.php?moodlewsrestformat=json")
        #expect(sent.fields["wstoken"] == fakeToken)
        #expect(sent.fields["wsfunction"] == "core_webservice_get_site_info")
    }

    @Test("Error messages never carry the token")
    func errorsAreClean() async {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [json(#"{"exception":"x","errorcode":"other","message":"bad \#(fakeToken)"}"#)]
        ])
        let result = await makeTools(transport).handle(.init(name: ToolCatalog.coursesName, arguments: nil))
        #expect(result.isError == true)
        #expect(!result.content.map { "\($0)" }.joined().contains(fakeToken))
    }
}

@Suite("Rule 3.5 — dates in Europe/Madrid, two formats")
struct DateTests {

    @Test("Winter time is +01:00")
    func winter() throws {
        // 2026-11-20 22:59:00 UTC
        let date = try #require(MoodleDate(unixSeconds: 1_795_215_540))
        #expect(date.iso == "2026-11-20T23:59:00+01:00")
        #expect(date.fechaLocal == "20/11/2026 23:59")
    }

    @Test("Summer time is +02:00")
    func summer() throws {
        // 2026-06-15 07:05:00 UTC
        let date = try #require(MoodleDate(unixSeconds: 1_781_507_100))
        #expect(date.iso == "2026-06-15T09:05:00+02:00")
        #expect(date.fechaLocal == "15/06/2026 09:05")
    }

    @Test("0 means no date and renders as null", arguments: [0, -1])
    func zeroIsNull(value: Int) throws {
        #expect(MoodleDate(unixSeconds: value) == nil)
        struct Row: Encodable { let due: MoodleDate? }
        let text = try Output.json(Row(due: MoodleDate(unixSeconds: value)))
        #expect(text.contains("\"due\" : null") || !text.contains("due"))
    }

    @Test("The JSON keys are iso and fecha_local")
    func keys() throws {
        let text = try Output.json(MoodleDate(unixSeconds: 1_795_215_540))
        #expect(text.contains("\"fecha_local\" : \"20/11/2026 23:59\""))
        #expect(text.contains("\"iso\" : \"2026-11-20T23:59:00+01:00\""))
    }
}

@Suite("Rule 3.6 — Moodle errors become typed errors")
struct ErrorMappingTests {

    @Test("invalidtoken and accessexception become TOKEN_INVALIDO", arguments: ["invalidtoken", "accessexception"])
    func tokenInvalid(code: String) async {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [
                json(#"{"exception":"moodle_exception","errorcode":"\#(code)","message":"Invalid token"}"#)
            ]
        ])
        await #expect(throws: MoodleError.tokenInvalid) { try await makeClient(transport).callRaw(.siteInfo, []) }
        #expect(MoodleError.tokenInvalid.message
            == "TOKEN_INVALIDO: Token del aula caducado o revocado: ejecuta `moodle-mcp login`")
    }

    @Test("servicenotavailable is retried once, then succeeds")
    func retryThenSucceed() async throws {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [
                json(#"{"exception":"x","errorcode":"servicenotavailable","message":"later"}"#),
                .body(try fixture("site-info")),
            ]
        ])
        let info: SiteInfo = try await makeClient(transport).call(.siteInfo)
        #expect(info.userid == 1001)
        #expect(await transport.sent.count == 2)
    }

    @Test("A network failure is retried once and then reported")
    func networkRetriedOnce() async {
        let transport = FakeTransport(["core_webservice_get_site_info": [.failure(.timedOut)]])
        await #expect(throws: MoodleError.network("URLError \(URLError.Code.timedOut.rawValue)")) {
            try await makeClient(transport).callRaw(.siteInfo, [])
        }
        #expect(await transport.sent.count == 2)
    }

    @Test("Other Moodle errors are not retried")
    func noRetryForOthers() async {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [json(#"{"exception":"x","errorcode":"invalidparameter","message":"bad"}"#)]
        ])
        await #expect(throws: MoodleError.moodleException(errorCode: "invalidparameter", message: "bad")) {
            try await makeClient(transport).callRaw(.siteInfo, [])
        }
        #expect(await transport.sent.count == 1)
    }

    @Test("moodle_status reports a dead token instead of failing")
    func statusSurvivesDeadToken() async {
        let transport = FakeTransport([
            "core_webservice_get_site_info": [json(#"{"exception":"x","errorcode":"invalidtoken","message":"m"}"#)]
        ])
        let result = await makeTools(transport).handle(.init(name: ToolCatalog.statusName, arguments: nil))
        let text = result.content.map { "\($0)" }.joined()
        #expect(result.isError == false)
        #expect(text.contains("TOKEN_INVALIDO"))
        #expect(text.contains("\\\"token_valid\\\" : false") || text.contains("\"token_valid\" : false"))
    }
}

@Suite("Requests")
struct RequestTests {

    @Test("Lists are sent in PHP bracket form")
    func listEncoding() {
        let fields = FakeTransport.decode(FormEncoding.encode(FormParameter.ints("courseids", [4, 7]).pairs))
        #expect(fields == ["courseids[0]": "4", "courseids[1]": "7"])
    }

    @Test("Requests are paced: the second start waits for the minimum interval")
    func pacing() async throws {
        let waits = WaitLog()
        let client = MoodleClient(
            siteURL: testSite, tokenStore: FakeTokenStore(), transport: try standardTransport(),
            minimumInterval: .seconds(10), retryDelay: .zero, sleep: { await waits.record($0) })
        _ = try await client.callRaw(.siteInfo, [])
        _ = try await client.callRaw(.siteInfo, [])
        let recorded = await waits.durations
        #expect(recorded.count == 1)
        #expect(recorded[0] > .seconds(9))
    }

    @Test("The missing-function report lists only what this server calls")
    func missingFunctions() throws {
        let info = try JSONDecoder().decode(SiteInfo.self, from: try fixture("site-info"))
        #expect(info.missingFunctions.isEmpty)
    }
}

actor WaitLog {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
