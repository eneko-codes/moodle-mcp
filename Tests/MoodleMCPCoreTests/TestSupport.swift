import Foundation

@testable import MoodleMCPCore

/// A token that exists only in the tests.
let fakeToken = "FAKEtokenFAKEtoken0000"

struct FakeTokenStore: TokenStore {
    var token: String? = fakeToken
    func readToken() throws(MoodleError) -> String {
        guard let token else { throw .tokenMissing }
        return token
    }
    func writeToken(_ token: String) throws(MoodleError) {}
}

/// Answers requests from a script, keyed by `wsfunction`, and records what was sent.
actor FakeTransport: HTTPTransport {
    enum Reply {
        case body(Data, status: Int = 200)
        case failure(URLError.Code)
    }

    struct Sent {
        let url: URL
        let fields: [String: String]
    }

    private var replies: [String: [Reply]]
    private(set) var sent: [Sent] = []

    init(_ replies: [String: [Reply]]) { self.replies = replies }

    func post(_ url: URL, body: Data) async throws -> (Data, Int) {
        let fields = Self.decode(body)
        sent.append(Sent(url: url, fields: fields))
        // A reply scripted for one course (`function|courseid=N`) wins over the generic one.
        let function = fields["wsfunction"] ?? url.lastPathComponent
        let specific = fields["courseid"].map { "\(function)|courseid=\($0)" }
        let key = specific.flatMap { replies[$0] == nil ? nil : $0 } ?? function
        guard var queue = replies[key], !queue.isEmpty else {
            return (Data(#"{"exception":"x","errorcode":"unscripted","message":"no reply scripted"}"#.utf8), 200)
        }
        let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
        replies[key] = queue
        switch reply {
        case .body(let data, let status): return (data, status)
        case .failure(let code): throw URLError(code)
        }
    }

    private(set) var downloads: [URL] = []
    var files: [String: Data] = [:]

    func setFile(_ path: String, _ data: Data) { files[path] = data }

    func get(_ url: URL) async throws -> (Data, Int, String?) {
        downloads.append(url)
        if let data = files[url.path] { return (data, 200, "application/pdf") }
        return (Data(#"{"error":"not found","errorcode":"filenotfound"}"#.utf8), 200, "application/json")
    }

    static func decode(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).removingPercentEncoding ?? String($0)
            }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try Data(contentsOf: url)
}

func json(_ text: String) -> FakeTransport.Reply { .body(Data(text.utf8)) }

let testSite = URL(string: "https://moodle.example.test")!

func makeClient(_ transport: FakeTransport, store: any TokenStore = FakeTokenStore()) -> MoodleClient {
    MoodleClient(
        siteURL: testSite, tokenStore: store, transport: transport,
        minimumInterval: .zero, retryDelay: .zero, sleep: { _ in })
}

func makeTools(_ transport: FakeTransport, allowed: Set<Int> = [9001, 9002]) -> MoodleTools {
    MoodleTools(
        session: MoodleSession(client: makeClient(transport), scope: CourseScope(allowed: allowed)),
        binaryPath: "/Users/user/moodle-mcp")
}

func standardTransport() throws -> FakeTransport {
    FakeTransport([
        "core_webservice_get_site_info": [.body(try fixture("site-info"))],
        "core_enrol_get_users_courses": [.body(try fixture("users-courses"))],
    ])
}

/// `#require` without importing Testing into every helper's signature.
import Testing
