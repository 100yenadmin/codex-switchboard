import XCTest

/// Runs the codex-logins tool's own tests (a fake Switchboard CLI and a temporary registry), so `swift test`
/// covers the check that decides whether an agent may switch the main CLI.
final class CodexLoginsScriptTests: XCTestCase {
    func testCheckSwitchAndSwapRefuseLeasedReservedAndUnreadableState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", root.appendingPathComponent("scripts/tests/test_codex_logins.py").path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CODEX_HOME")
        environment.removeValue(forKey: "CODEX_SWITCHBOARD_CLI")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertFalse(text.contains("FAIL"), text)
    }
}
