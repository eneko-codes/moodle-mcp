import Foundation
import MoodleMCPCore

// Launcher only. Everything testable lives in MoodleMCPCore.
do {
    let command = try CommandLineInterface.parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .serve:
        try await MoodleMCPServer.run(configuration: Configuration.load())
    case .selftest(let discover, let category):
        try await CommandLineInterface.selftest(discover: discover, category: category)
    case .login(let account):
        try await CommandLineInterface.login(account: account)
    case .importToken(let account):
        try await CommandLineInterface.importToken(account: account)
    case .help:
        print(CommandLineInterface.usage)
    }
} catch let error as MoodleError {
    // stderr, never stdout: in server mode stdout is the JSON-RPC stream.
    Diagnostics.fatal(error)
    FileHandle.standardError.write(Data((Redaction.scrub(error.message) + "\n").utf8))
    exit(1)
} catch {
    // Exiting 0 would be indistinguishable from a clean shutdown.
    Diagnostics.fatal(error)
    exit(1)
}
