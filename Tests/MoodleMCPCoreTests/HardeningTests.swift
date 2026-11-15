import Foundation
import Testing

@testable import MoodleMCPCore

/// The gaps an audit found after 0.2.0, each pinned by a test.
@Suite("Hardening")
struct HardeningTests {

    static let site = URL(string: "https://moodle.example.test")!
    static let siteWithPath = URL(string: "https://moodle.example.test/campus/aula")!

    @Test("Only this site's own pluginfile.php paths are accepted, with their context")
    func pluginfileAccepted() {
        #expect(MoodleClient.pluginfileContext(
            of: URL(string: "https://moodle.example.test/pluginfile.php/501/mod_resource/content/1/x.pdf")!, site: Self.site) == 501)
        #expect(MoodleClient.pluginfileContext(
            of: URL(string: "https://MOODLE.example.test:443/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf")!, site: Self.site) == 501)
        #expect(MoodleClient.pluginfileContext(
            of: URL(string: "https://moodle.example.test/campus/aula/pluginfile.php/501/mod_folder/content/0/Tema%201.pdf")!,
            site: Self.siteWithPath) == 501)
    }

    @Test("Traversal, other ports, user info, other scripts and encoded separators are refused",
          arguments: [
            "https://moodle.example.test/pluginfile.php/501/../999/mod_resource/content/0/x.pdf",
            "https://moodle.example.test/pluginfile.php/501/%2e%2e/999/mod_resource/content/0/x.pdf",
            "https://moodle.example.test/pluginfile.php/501/./mod_resource/content/0/x.pdf",
            "https://moodle.example.test/pluginfile.php/501%2F..%2F999/mod_resource/content/0/x.pdf",
            "https://moodle.example.test/pluginfile.php/501//mod_resource/x.pdf",
            "https://moodle.example.test:8443/pluginfile.php/501/mod_resource/content/0/x.pdf",
            "https://user@moodle.example.test/pluginfile.php/501/mod_resource/content/0/x.pdf",
            "https://moodle.example.test/mod/forum/post.php/pluginfile.php/501/x",
            "https://moodle.example.test/pluginfile.php/501",
            "https://moodle.example.test/other/pluginfile.php/501/mod_resource/content/0/x.pdf",
          ])
    func pluginfileRefused(url: String) {
        #expect(MoodleClient.pluginfileContext(of: URL(string: url)!, site: Self.site) == nil)
    }

    @Test("A path outside the site's own path is refused")
    func outsideSitePath() {
        #expect(MoodleClient.pluginfileContext(
            of: URL(string: "https://moodle.example.test/pluginfile.php/501/mod_resource/content/1/x.pdf")!,
            site: Self.siteWithPath) == nil)
    }

    @Test("A traversal URL is refused by file_download before any request")
    func traversalNotDownloaded() async throws {
        let transport = try fullTransport()
        let url = "https://moodle.example.test/pluginfile.php/501/../999/mod_resource/content/0/x.pdf"
        let (text, isError) = await call(tools(transport), ToolCatalog.fileDownloadName, ["courseid": .int(9001), "url": .string(url)])
        #expect(isError, "\(text)")
        #expect(await transport.downloads.isEmpty)
    }

    @Test("The download drops the caller's query and fragment and carries only the token")
    func downloadQueryDropped() async throws {
        let transport = try fullTransport()
        await transport.setFile("/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf", Data("PDF".utf8))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://moodle.example.test/pluginfile.php/501/mod_resource/content/1/x.pdf?reply=1&sesskey=a#frag"
        let (text, isError) = await call(tools(transport, downloads: root), ToolCatalog.fileDownloadName,
                                         ["courseid": .int(9001), "url": .string(url)])
        #expect(!isError, "\(text)")
        let fetched = try #require(await transport.downloads.first)
        let components = try #require(URLComponents(url: fetched, resolvingAgainstBaseURL: false))
        #expect(components.path == "/webservice/pluginfile.php/501/mod_resource/content/1/x.pdf")
        #expect(components.queryItems?.map(\.name) == ["token"])
        #expect(components.fragment == nil)
    }

    @Test("Redirects are followed only within the same https host and port")
    func redirects() {
        let origin = URL(string: "https://moodle.example.test/webservice/rest/server.php")
        #expect(RedirectPolicy.allows(from: origin, to: URL(string: "https://moodle.example.test/other")))
        #expect(RedirectPolicy.allows(from: origin, to: URL(string: "https://MOODLE.example.test:443/x")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://evil.example.test/x")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "http://moodle.example.test/x")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://moodle.example.test:8443/x")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://user@moodle.example.test/x")))
        #expect(!RedirectPolicy.allows(from: origin, to: nil))
    }

    @Test("A site edited into config.json must be https")
    func configurationHTTPS() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        try Data(#"{"siteURL":"http://moodle.example.org","account":"user"}"#.utf8).write(to: file)
        #expect(throws: MoodleError.self) { try Configuration.load(from: file) }
        try Data(#"{"siteURL":"https://moodle.example.org/","account":"user"}"#.utf8).write(to: file)
        #expect(try Configuration.load(from: file).siteURL?.absoluteString == "https://moodle.example.org")
    }

    @Test("Token parameters are removed in any case, encoding or HTML escaping",
          arguments: [
            ("https://a.test/f.pdf?TOKEN=abc123", "https://a.test/f.pdf"),
            ("https://a.test/f.pdf?x=1&amp;token=abc123", "https://a.test/f.pdf?x=1"),
            ("https://a.test/f.pdf?x=1&amp;token=abc123&amp;y=2", "https://a.test/f.pdf?x=1&amp;y=2"),
            ("https://a.test/f.pdf#token=abc123", "https://a.test/f.pdf"),
            ("https%3A%2F%2Fa.test%2Ff.pdf%3Fwstoken%3Dabc123", "https%3A%2F%2Fa.test%2Ff.pdf"),
            (#"{"u":"https:\/\/a.test\/f.pdf?token=abc123\"}"#, #"{"u":"https:\/\/a.test\/f.pdf\"}"#),
            ("Q&A: what? see ?x=1&y=2", "Q&A: what? see ?x=1&y=2"),
          ])
    func redaction(input: String, expected: String) {
        #expect(Redaction.scrub(input) == expected)
    }

    @Test("stripToken ignores case")
    func stripTokenCase() {
        #expect(Redaction.stripToken(from: "https://a.test/f.pdf?Token=abc&x=1") == "https://a.test/f.pdf?x=1")
    }

    @Test("The deny list also catches generic call and other write verbs; no allowed function matches it",
          arguments: [
            "tool_mobile_call_external_functions", "core_message_set_favourite_conversations",
            "core_message_mute_conversations", "core_message_block_user", "mod_forum_set_lock_state",
            "core_course_toggle_activity_recommendation", "mod_assign_override_grade",
            "core_message_confirm_contact_request", "core_message_decline_contact_request",
          ])
    func denyList(name: String) {
        #expect(ForbiddenFunctions.matches(name))
        #expect(throws: MoodleError.self) { try WebServiceFunction(validating: name) }
        for function in WebServiceFunction.allCases { #expect(!ForbiddenFunctions.matches(function.rawValue)) }
    }

    @Test("An expired-token error is TOKEN_INVALIDO")
    func expiredToken() {
        let body = Data(#"{"exception":"moodle_exception","errorcode":"invalidtimedtoken","message":"expired"}"#.utf8)
        #expect(throws: MoodleError.tokenInvalid) { try MoodleClient.raiseException(in: body) }
    }

    @Test("A bare end date includes the whole day")
    func endOfDay() throws {
        #expect(try DateArgument.parse("2026-11-20", name: "to", endOfDay: true) == 1_795_215_599)
        #expect(try DateArgument.parse("2026-11-20T10:00", name: "to", endOfDay: true)
            == DateArgument.parse("2026-11-20T10:00", name: "to"))
    }

    @Test("A group conversation is dropped when another enrolled course shares the allowed course's name")
    func sharedCourseName() async throws {
        var courses = try #require(try JSONSerialization.jsonObject(with: fixture("users-courses")) as? [[String: Any]])
        courses.append(["id": 9200, "shortname": "OLD", "fullname": "Módulo de Ejemplo A (26-27)", "category": 50])
        let transport = FakeTransport([
            "core_webservice_get_site_info": [.body(try fixture("site-info"))],
            "core_enrol_get_users_courses": [.body(try JSONSerialization.data(withJSONObject: courses))],
            "core_message_get_conversations": [json(Answers.conversations)],
        ])
        let (text, isError) = await call(tools(transport), ToolCatalog.conversationsName, [:])
        #expect(!isError, "\(text)")
        #expect(!text.contains("Grupo A"))
        #expect(text.contains("\"id\" : 80"))
    }
}
