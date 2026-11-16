import Foundation

/// One `application/x-www-form-urlencoded` argument. Moodle's REST server reads lists in
/// PHP's bracket form: `courseids[0]=1&courseids[1]=2`, and lists of objects as
/// `values[0]=…` or `options[0][name]=…`.
public enum FormParameter: Equatable, Sendable {
    case value(String, String)
    case list(String, [String])

    public static func int(_ name: String, _ value: Int) -> FormParameter { .value(name, String(value)) }
    public static func ints(_ name: String, _ values: [Int]) -> FormParameter { .list(name, values.map(String.init)) }

    var pairs: [(String, String)] {
        switch self {
        case .value(let name, let value): [(name, value)]
        case .list(let name, let values): values.enumerated().map { ("\(name)[\($0.offset)]", $0.element) }
        }
    }
}

enum FormEncoding {
    /// RFC 3986 unreserved characters only; everything else, brackets included, is
    /// percent-encoded. PHP decodes `%5B0%5D` back into an array index.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ pairs: [(String, String)]) -> Data {
        let body = pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// The network, behind a protocol so the tests drive every branch with recorded answers.
public protocol HTTPTransport: Sendable {
    /// Returns the body and the HTTP status. Throws only for transport failures.
    func post(_ url: URL, body: Data) async throws -> (Data, Int)
    /// A file download: the body, the HTTP status and the Content-Type.
    func get(_ url: URL) async throws -> (Data, Int, String?)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Ephemeral: no cookies, cache or credentials are written to disk. 30 s per request.
    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "moodle-mcp"]
        session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    public func post(_ url: URL, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func get(_ url: URL) async throws -> (Data, Int, String?) {
        let (data, response) = try await session.data(from: url)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type"))
    }
}

/// URLSession follows redirects anywhere by default, and a 307 or 308 resends the POST
/// body — the token, or the password at login — to wherever `Location` points. Only a
/// redirect that stays on the same https origin is followed; any other is refused, and the
/// 3xx itself comes back as the answer (an HTTP status error).
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.allows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }
}

public enum RedirectPolicy {
    public static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return target.scheme?.lowercased() == "https"
            && original.scheme?.lowercased() == "https"
            && target.host?.lowercased() == original.host?.lowercased()
            && (target.port ?? 443) == (original.port ?? 443)
            && target.user == nil && target.password == nil
    }
}

/// One request at a time, and at least `minimumInterval` between the starts of two
/// requests (about two a second): the site's server is shared and this is a reader,
/// not a crawler.
actor RequestGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastStart: ContinuousClock.Instant?
    private let minimumInterval: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(minimumInterval: Duration, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.minimumInterval = minimumInterval
        self.sleep = sleep
    }

    func acquire() async {
        if busy {
            // `release` hands the gate straight to the next waiter, so `busy` stays true.
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        if let lastStart {
            let elapsed = ContinuousClock.now - lastStart
            if elapsed < minimumInterval { await sleep(minimumInterval - elapsed) }
        }
        lastStart = .now
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// The Moodle REST client. It can only call `WebServiceFunction` cases, checks the name
/// again against `ForbiddenFunctions` immediately before sending, and turns Moodle's
/// HTTP-200 error bodies into `MoodleError`.
public final class MoodleClient: Sendable {
    public let siteURL: URL
    private let tokenStore: any TokenStore
    private let transport: any HTTPTransport
    private let gate: RequestGate
    private let sleep: @Sendable (Duration) async -> Void
    private let retryDelay: Duration

    public init(
        siteURL: URL, tokenStore: any TokenStore, transport: any HTTPTransport = URLSessionTransport(),
        minimumInterval: Duration = .milliseconds(500), retryDelay: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.siteURL = siteURL
        self.tokenStore = tokenStore
        self.transport = transport
        self.gate = RequestGate(minimumInterval: minimumInterval, sleep: sleep)
        self.sleep = sleep
        self.retryDelay = retryDelay
    }

    /// `POST /webservice/rest/server.php?moodlewsrestformat=json`. The token goes in the
    /// body, never in the URL, so no URL this program builds can leak it.
    var restURL: URL {
        var components = URLComponents(
            url: siteURL.appendingPathComponent("webservice/rest/server.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "moodlewsrestformat", value: "json")]
        return components.url!
    }

    var tokenURL: URL { siteURL.appendingPathComponent("login/token.php") }

    /// Calls `function` and decodes the answer, after dropping `Redaction.droppedKeys` at
    /// every depth.
    public func call<T: Decodable>(
        _ function: WebServiceFunction, _ parameters: [FormParameter] = [], as type: T.Type = T.self
    ) async throws(MoodleError) -> T {
        let data = try await callRaw(function, parameters)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .unexpectedResponse("\(function.rawValue) did not decode as \(T.self).")
        }
    }

    /// The answer as lenient `JSON`, for readers that tolerate Moodle's loose typing.
    public func callJSON(_ function: WebServiceFunction, _ parameters: [FormParameter] = []) async throws(MoodleError) -> JSON {
        try JSON.parse(try await callRaw(function, parameters))
    }

    /// Fetches a file URL that `file_download` has already checked belongs to an allowed
    /// course. The token is added here, to a copy of the URL that never leaves this
    /// function; files go through `/webservice/pluginfile.php`, which accepts it.
    public func downloadFile(_ fileURL: URL) async throws(MoodleError) -> Data {
        // Checked again here, so no caller can hand this function a URL that would carry
        // the token anywhere but this site's pluginfile.php.
        guard Self.pluginfileContext(of: fileURL, site: siteURL) != nil,
            var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        else {
            throw .badArgument(name: "url", reason: "only file URLs of this Moodle site (…/pluginfile.php/…) can be downloaded.")
        }
        let sitePath = Self.sitePath(siteURL)
        let plain = sitePath + "/pluginfile.php/"
        if components.percentEncodedPath.hasPrefix(plain) {
            components.percentEncodedPath = sitePath + "/webservice/pluginfile.php/"
                + components.percentEncodedPath.dropFirst(plain.count)
        }
        let token = try tokenStore.readToken()
        // The caller's query and fragment are dropped: the file is named by its path, and
        // nothing a caller adds may ride along with the token.
        components.fragment = nil
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let authorised = components.url else { throw .badArgument(name: "url", reason: "not a URL.") }

        var attempt = 1
        while true {
            let started = ContinuousClock.now
            await gate.acquire()
            let result: Result<(Data, Int, String?), any Error>
            do { result = .success(try await transport.get(authorised)) } catch { result = .failure(error) }
            await gate.release()
            do {
                let data = try Self.checkDownload(result)
                Diagnostics.request("pluginfile", attempt: attempt, outcome: "ok", since: started)
                return data
            } catch {
                let redacted = error.redacting(token)
                Diagnostics.request("pluginfile", attempt: attempt, outcome: redacted.code.lowercased(), since: started)
                guard redacted.isTransient, attempt == 1 else { throw redacted }
                attempt += 1
                await sleep(retryDelay)
            }
        }
    }

    /// The pluginfile context of a file URL of this site, or nil when the URL is not one
    /// this program may fetch: https on the site's own host and port, no user info, a path
    /// that is exactly `<site path>/pluginfile.php/<context>/…` or
    /// `<site path>/webservice/pluginfile.php/<context>/…`, and no `.`, `..`, empty or
    /// percent-encoded separator or dot segment. Foundation keeps `..` in a URL's path
    /// unnormalised, and the web server would resolve it after this check, so
    /// `pluginfile.php/501/../999/…` would otherwise pass as context 501.
    public static func pluginfileContext(of url: URL, site: URL) -> Int? {
        guard url.scheme?.lowercased() == "https", site.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(), host == site.host?.lowercased(),
            (url.port ?? 443) == (site.port ?? 443),
            url.user == nil, url.password == nil,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let raw = components.percentEncodedPath
        let lowered = raw.lowercased()
        guard !lowered.contains("%2f"), !lowered.contains("%5c"), !lowered.contains("%2e"), !raw.contains("\\") else {
            return nil
        }
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let siteSegments = sitePath(site).split(separator: "/").map(String.init)
        guard segments.starts(with: siteSegments) else { return nil }
        var rest = Array(segments.dropFirst(siteSegments.count))
        if rest.first == "webservice" { rest.removeFirst() }
        // At least the context and one more segment (component, file area, file name…).
        guard rest.count >= 3, rest[0] == "pluginfile.php" else { return nil }
        return Int(rest[1])
    }

    /// The site's path as it appears in a percent-encoded URL path, without a trailing
    /// slash; empty for a site at the root of its host.
    static func sitePath(_ site: URL) -> String {
        var path = URLComponents(url: site, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A refused download comes back as HTTP 200 with a JSON error body (or an HTML error
    /// page), not as a file; neither may be saved as if it were the file.
    static func checkDownload(_ result: Result<(Data, Int, String?), any Error>) throws(MoodleError) -> Data {
        let data: Data
        let status: Int
        let contentType: String?
        switch result {
        case .success(let answer): (data, status, contentType) = answer
        case .failure(let error):
            if let urlError = error as? URLError { throw .network("URLError \(urlError.code.rawValue)") }
            throw .network(String(describing: type(of: error)))
        }
        guard status == 200 else { throw .httpStatus(status) }
        if contentType?.lowercased().hasPrefix("application/json") == true || data.first == UInt8(ascii: "{") {
            try raiseException(in: data)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] != nil {
                throw .moodleException(
                    errorCode: object["errorcode"] as? String ?? "unknown",
                    message: Redaction.scrub(object["error"] as? String ?? ""))
            }
        }
        return data
    }

    /// The cleaned JSON bytes of a successful call.
    public func callRaw(_ function: WebServiceFunction, _ parameters: [FormParameter]) async throws(MoodleError) -> Data {
        // Defence in depth: the enum already makes this unreachable for a forbidden name.
        guard !ForbiddenFunctions.matches(function.rawValue) else { throw .functionForbidden(function.rawValue) }
        let token = try tokenStore.readToken()
        let pairs = [("wstoken", token), ("wsfunction", function.rawValue)] + parameters.flatMap(\.pairs)
        let body = FormEncoding.encode(pairs)
        do {
            return try await send(label: function.rawValue, url: restURL, body: body)
        } catch {
            // Moodle's own message text can quote anything, the request included.
            throw error.redacting(token)
        }
    }

    /// The last scrub before text leaves the program, with the literal token if it can be
    /// read (without a dialog) so even an unrecognised echo of it is removed.
    public func redact(_ text: String) -> String {
        Redaction.scrub(text, token: try? tokenStore.readToken())
    }

    /// `login/token.php` with `service=moodle_mobile_app`. The password goes into this one
    /// request body and nowhere else; only the token comes back (`privatetoken` is dropped).
    public func requestToken(username: String, password: String) async throws(MoodleError) -> String {
        let body = FormEncoding.encode([
            ("username", username), ("password", password), ("service", "moodle_mobile_app"),
        ])
        // Never retried: a resend would put the password on the wire a second time.
        let data = try await send(label: "login_token", url: tokenURL, body: body, cleaning: false, retrying: false)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .unexpectedResponse("login/token.php did not answer with a JSON object.")
        }
        if let token = object["token"] as? String, !token.isEmpty { return token }
        throw .loginRefused(
            errorCode: object["errorcode"] as? String ?? "unknown",
            message: Redaction.scrub(object["error"] as? String ?? "no reason given"))
    }

    /// Paced, with one retry after `retryDelay` for a transient failure unless `retrying`
    /// is false.
    private func send(
        label: String, url: URL, body: Data, cleaning: Bool = true, retrying: Bool = true
    ) async throws(MoodleError) -> Data {
        var attempt = 1
        while true {
            let started = ContinuousClock.now
            do {
                let data = try await exchange(url: url, body: body)
                Diagnostics.request(label, attempt: attempt, outcome: "ok", since: started)
                return cleaning ? try Self.clean(data) : data
            } catch {
                Diagnostics.request(label, attempt: attempt, outcome: error.code.lowercased(), since: started)
                guard retrying, error.isTransient, attempt == 1 else { throw error }
                attempt += 1
                await sleep(retryDelay)
            }
        }
    }

    private func exchange(url: URL, body: Data) async throws(MoodleError) -> Data {
        await gate.acquire()
        let result: Result<(Data, Int), any Error>
        do { result = .success(try await transport.post(url, body: body)) } catch { result = .failure(error) }
        await gate.release()

        let data: Data
        let status: Int
        switch result {
        case .success(let answer): (data, status) = answer
        case .failure(let error):
            // The URLError code only: its userInfo carries the URL, and nothing else here
            // is worth showing.
            if let urlError = error as? URLError { throw .network("URLError \(urlError.code.rawValue)") }
            throw .network(String(describing: type(of: error)))
        }
        guard status == 200 else { throw .httpStatus(status) }
        try Self.raiseException(in: data)
        return data
    }

    /// Moodle reports errors with HTTP 200 and `exception`/`errorcode`/`message` in the
    /// body (and `error`/`errorcode` from `login/token.php`).
    static func raiseException(in data: Data) throws(MoodleError) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["exception"] != nil || (object["errorcode"] != nil && object["token"] == nil)
        else { return }
        let errorCode = object["errorcode"] as? String ?? "unknown"
        if ["invalidtoken", "invalidtimedtoken", "accessexception"].contains(errorCode) { throw .tokenInvalid }
        let message = object["message"] as? String ?? object["error"] as? String ?? "no message"
        throw .moodleException(errorCode: errorCode, message: Redaction.scrub(message))
    }

    static func clean(_ data: Data) throws(MoodleError) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw .unexpectedResponse("the body is not JSON.")
        }
        guard let cleaned = try? JSONSerialization.data(withJSONObject: Redaction.dropSecrets(json), options: [.fragmentsAllowed])
        else { throw .unexpectedResponse("the body could not be re-encoded.") }
        return cleaned
    }
}
