import XCTest
@testable import CodexSwitchboardCore

/// Runs the codex-logins tool's own tests (a fake Switchboard CLI and a temporary registry), so `swift test`
/// covers the check that decides whether an agent may switch the main CLI.
final class CodexLoginsScriptTests: XCTestCase {
    func testCheckSwitchAndSwapRefuseLeasedReservedAndUnreadableState() throws {
        try requirePython3()
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

    /// codex-logins register takes `.auth.lock` with Python's `fcntl.lockf`; it must exclude the switch's hold.
    func testPythonLockfOnTheAuthLockWaitsForSwitchboardsHold() throws {
        try requirePython3()
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-logins-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let probe = """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("acquired")
        except OSError:
            print("busy")
        """
        func tryLock() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", "-c", probe, appSupport.appendingPathComponent(CodexAuthStoreLock.fileName).path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let held = try CodexAuthStoreLock.withRequiredLock(appSupportURL: appSupport) { try tryLock() }
        XCTAssertEqual(held, "busy")
        XCTAssertEqual(try tryLock(), "acquired")
    }

    private func requirePython3() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        guard path.split(separator: ":").contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/python3") }) else {
            throw XCTSkip("needs python3 on PATH")
        }
    }
}
