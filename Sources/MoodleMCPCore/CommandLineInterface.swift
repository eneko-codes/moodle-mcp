import Darwin
import Foundation

/// The subcommands besides the stdio server. They live in the same binary on purpose: the
/// Keychain item trusts the program that wrote it, so `login` and `import-token` must be
/// the very program the server runs as.
///
/// These are for a person at a terminal, so they print to stdout. The server mode never
/// reaches this type. Nothing here prints the token or the password.
public enum CommandLineInterface {

    public enum Command: Equatable {
        case serve
        case selftest(discover: Bool, category: Int?)
        case login(account: String?)
        case importToken(account: String?)
        case help
    }

    public static func parse(_ arguments: [String]) throws(MoodleError) -> Command {
        guard let first = arguments.first else { return .serve }
        let rest = Array(arguments.dropFirst())
        func value(_ flag: String) throws(MoodleError) -> String? {
            guard let index = rest.firstIndex(of: flag) else { return nil }
            guard index + 1 < rest.count else { throw .missingArgument(flag) }
            return rest[index + 1]
        }
        func account() throws(MoodleError) -> String? { try value("--account") }
        func category() throws(MoodleError) -> Int? {
            guard let text = try value("--category") else { return nil }
            guard let id = Int(text), id > 0 else { throw .badArgument(name: "--category", reason: "expected a category id.") }
            return id
        }
        switch first {
        case "serve": return .serve
        case "selftest": return .selftest(discover: rest.contains("--discover"), category: try category())
        case "login": return .login(account: try account())
        case "import-token": return .importToken(account: try account())
        case "help", "--help", "-h": return .help
        default: throw .badArgument(name: "command", reason: "unknown command '\(first)'. Try `moodle-mcp help`.")
        }
    }

    public static let usage = """
        moodle-mcp [serve]         run the MCP server on stdio (what Claude starts)
        moodle-mcp selftest        check the token without any dialog; print release, user id, allowed courses
        moodle-mcp selftest --discover [--category ID]
                                   propose your courses in that category and, once confirmed, save them as the allowed list;
                                   --category can be left out once a category has been saved
        moodle-mcp login [--account NAME]
                                   ask for the site (first time), username and password without echo; store the token
        moodle-mcp import-token [--account NAME]
                                   rewrite an existing Keychain item so this program is its trusted application
        moodle-mcp help            show this text
        """

    // MARK: selftest

    public static func selftest(
        discover: Bool, category: Int? = nil, configurationURL: URL = Configuration.defaultURL
    ) async throws(MoodleError) {
        var configuration = try Configuration.load(from: configurationURL)
        guard configuration.siteURL != nil, configuration.account?.isEmpty == false else {
            throw .configuration("No site or account is configured. Run `moodle-mcp login` first.")
        }
        // allowsInteraction false: the point of the self-test is to prove the scheduled,
        // unattended read works, so a read that would need a dialog must fail here too.
        let session = try MoodleMCPServer.makeSession(configuration: configuration)
        let info = try await session.siteInfo()
        say("Moodle release: \(info.release ?? "unknown")")
        say("User id: \(info.userid)")
        let missing = info.missingFunctions
        say(missing.isEmpty ? "Functions: all granted" : "Functions not granted: \(missing.joined(separator: ", "))")

        if discover {
            guard let categoryID = category ?? configuration.discoverCategoryID else {
                throw .missingArgument("--category")
            }
            let candidates = try await session.courses(inCategory: categoryID)
            say("\nCourses in category \(categoryID):")
            for course in candidates { say("  \(course.id)\t\(course.fullname ?? course.shortname ?? "")") }
            guard !candidates.isEmpty else {
                say("None. Nothing saved.")
                return
            }
            guard confirm("Save these \(candidates.count) courses as the allowed list?") else {
                say("Nothing saved.")
                return
            }
            configuration.allowedCourseIDs = candidates.map(\.id)
            configuration.discoverCategoryID = categoryID
            try configuration.save(to: configurationURL)
            say("Saved to \(configurationURL.path).")
            return
        }

        guard !configuration.allowedCourseIDs.isEmpty else {
            say("Allowed courses: none yet — run `moodle-mcp selftest --discover`.")
            return
        }
        let tools = MoodleTools(session: session)
        say("\nAllowed courses (\(ToolCatalog.coursesName)):")
        say(try await tools.run(ToolCatalog.coursesName, Arguments(nil)))
    }

    // MARK: login

    public static func login(account: String?, configurationURL: URL = Configuration.defaultURL) async throws(MoodleError) {
        var configuration = try Configuration.load(from: configurationURL)
        let site: URL
        if let configured = configuration.siteURL {
            site = configured
        } else {
            site = try Configuration.parseSiteURL(readLine(prompt: "Moodle site (https://…): ") ?? "")
        }
        let proposed = account ?? configuration.account
        let entered = readLine(prompt: proposed.map { "Moodle username [\($0)]: " } ?? "Moodle username: ")
        guard let username = (entered?.isEmpty == false ? entered : proposed), !username.isEmpty else {
            throw .missingArgument("username")
        }
        guard let password = readSecret(prompt: "Password (not shown, not stored): "), !password.isEmpty else {
            throw .missingArgument("password")
        }
        let loginClient = MoodleClient(siteURL: site, tokenStore: NoTokenStore())
        let token = try await loginClient.requestToken(username: username, password: password)
        try KeychainTokenStore(account: username, allowsInteraction: true).writeToken(token)
        configuration.account = username
        configuration.siteURL = site
        try configuration.save(to: configurationURL)
        say("Token stored in the login keychain (service \(Configuration.keychainService)).")
        try await verifySilentRead(configuration: configuration)
    }

    // MARK: import-token

    public static func importToken(account: String?, configurationURL: URL = Configuration.defaultURL) async throws(MoodleError) {
        var configuration = try Configuration.load(from: configurationURL)
        guard let username = account ?? configuration.account, !username.isEmpty else {
            throw .missingArgument("--account")
        }
        say("macOS may ask for the login keychain password to let moodle-mcp read the existing item once.")
        let token = try KeychainTokenStore(account: username, allowsInteraction: true).readToken()
        try KeychainTokenStore(account: username, allowsInteraction: true).writeToken(token)
        configuration.account = username
        try configuration.save(to: configurationURL)
        say("Item rewritten by this program.")
        try await verifySilentRead(configuration: configuration)
    }

    /// Reads the item back with dialogs forbidden, which is how the server will read it.
    private static func verifySilentRead(configuration: Configuration) async throws(MoodleError) {
        let session = try MoodleMCPServer.makeSession(configuration: configuration)
        let info = try await session.siteInfo()
        say("Silent read works; the token answers for user id \(info.userid).")
    }

    // MARK: Terminal

    static func say(_ line: String) { print(line) }

    private static func confirm(_ question: String) -> Bool {
        let answer = readLine(prompt: "\(question) [y/N] ")?.lowercased()
        return answer == "y" || answer == "yes" || answer == "s" || answer == "si" || answer == "sí"
    }

    private static func readLine(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `readpassphrase(3)` with `RPP_REQUIRE_TTY`: echo off, read from the terminal itself
    /// (never a pipe), buffer wiped afterwards. The Swift `String` it becomes cannot be
    /// wiped; it lives only until the request body is built.
    private static func readSecret(prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// For `login/token.php`, which needs no token.
struct NoTokenStore: TokenStore {
    func readToken() throws(MoodleError) -> String { throw .tokenMissing }
    func writeToken(_ token: String) throws(MoodleError) {}
}
