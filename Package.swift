// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "moodle-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        //
        // Networking is URLSession and the token store is Security.framework: both ship
        // with macOS, so the MCP SDK is the only package.
        .target(
            name: "MoodleMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "moodle-mcp",
            dependencies: ["MoodleMCPCore"],
            // The embedded Info.plist gives the binary a stable bundle identifier, which
            // together with a real signing identity is what the Keychain item's access
            // list recognises across rebuilds (see CLAUDE.md, "The token").
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MoodleMCPCoreTests",
            dependencies: ["MoodleMCPCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
