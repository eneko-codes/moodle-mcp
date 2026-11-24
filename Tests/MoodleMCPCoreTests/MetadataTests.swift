import Foundation
import Testing

@testable import MoodleMCPCore

/// Reads this repository's own files, not the machine.
@Suite("Release metadata")
struct VersionTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        #expect(try manifest()["version"] as? String == MoodleMCPServer.version)
        #expect(try plist()["CFBundleShortVersionString"] as? String == MoodleMCPServer.version)
    }

    @Test("Names agree, and the display name gives the Moodle__ tool prefix")
    func namesAgree() throws {
        #expect(try manifest()["name"] as? String == MoodleMCPServer.name)
        #expect(try manifest()["display_name"] as? String == "Moodle")
        #expect(try plist()["CFBundleIdentifier"] as? String == "codes.eneko.\(MoodleMCPServer.name)")
    }

    @Test("The manifest lists exactly the catalogue's tools")
    func manifestToolsMatch() throws {
        let tools = try #require(try manifest()["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(ToolCatalog.all().map(\.name)))
    }

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}

@Suite("Diagnostics and command line")
struct DiagnosticsTests {

    @Test("Only plain identifiers are echoed into the log")
    func identifiers() {
        #expect(Diagnostics.identifier("courses_list") == "courses_list")
        #expect(Diagnostics.identifier("x\n2026 fatal forged") == "invalid")
    }

    @Test("Error kinds carry no payload")
    func kinds() {
        #expect(Diagnostics.kind(of: MoodleError.courseNotAllowed(9100)) == "MoodleError.courseNotAllowed")
        #expect(Diagnostics.kind(of: MoodleError.moodleException(errorCode: "a", message: "secret")) == "MoodleError.moodleException")
    }

    @Test("Subcommands parse")
    func parse() throws {
        #expect(try CommandLineInterface.parse([]) == .serve)
        #expect(try CommandLineInterface.parse(["selftest", "--discover"]) == .selftest(discover: true, category: nil))
        #expect(try CommandLineInterface.parse(["selftest", "--discover", "--category", "12"]) == .selftest(discover: true, category: 12))
        #expect(try CommandLineInterface.parse(["login", "--account", "user"]) == .login(account: "user"))
        #expect(try CommandLineInterface.parse(["import-token"]) == .importToken(account: nil))
        #expect(throws: MoodleError.self) { try CommandLineInterface.parse(["call", "mod_quiz_start_attempt"]) }
    }

    @Test("A configuration with missing keys has no site, no courses and no category")
    func configurationDefaults() throws {
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"{"account":"user"}"#.utf8))
        #expect(configuration.siteURL == nil)
        #expect(configuration.allowedCourseIDs.isEmpty)
        #expect(configuration.discoverCategoryID == nil)
    }

    @Test("Site URLs must be https and are normalised")
    func siteURL() throws {
        #expect(try Configuration.parseSiteURL(" https://moodle.example.org/ ").absoluteString == "https://moodle.example.org")
        #expect(throws: MoodleError.self) { try Configuration.parseSiteURL("http://moodle.example.org") }
        #expect(throws: MoodleError.self) { try Configuration.parseSiteURL("moodle.example.org") }
    }

    @Test("An unconfigured server still starts and says what is missing")
    func unconfigured() async throws {
        let session = try MoodleMCPServer.makeSession(configuration: Configuration())
        let (text, isError) = await call(MoodleTools(session: session), ToolCatalog.statusName)
        #expect(!isError)
        #expect(text.contains("moodle-mcp login"))
    }
}
