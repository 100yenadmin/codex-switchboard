import Foundation
import XCTest
@testable import CodexSwitchboard

final class AppServerDaemonRestartTests: XCTestCase {
    private func makeTempCodexHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDaemonIsNotConsideredRunningWithoutControlSocket() throws {
        let home = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // A stale pid file alone (the state left behind by a zombie app-server) must not count.
        let daemonDir = home.appendingPathComponent("app-server-daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try #"{"pid":81096,"processStartTime":"Sat Sep  5 02:06:31 2026"}"#
            .write(to: daemonDir.appendingPathComponent("app-server.pid"), atomically: true, encoding: .utf8)

        XCTAssertFalse(CodexAppServerDaemon.isLikelyRunning(codexHome: home))
    }

    func testDaemonIsConsideredRunningWhenControlSocketPathExists() throws {
        let home = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let socketURL = CodexAppServerDaemon.controlSocketURL(codexHome: home)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(socketURL.lastPathComponent, "app-server-control.sock")
        XCTAssertEqual(socketURL.deletingLastPathComponent().lastPathComponent, "app-server-control")
        FileManager.default.createFile(atPath: socketURL.path, contents: nil)

        XCTAssertTrue(CodexAppServerDaemon.isLikelyRunning(codexHome: home))
    }

    func testTimedProcessRunnerReturnsOutputOfFinishedCommand() throws {
        let output = try TimedProcessRunner.run("/bin/echo", ["switchboard"], timeout: 5)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "switchboard")
    }

    func testTimedProcessRunnerThrowsOnNonZeroExit() {
        XCTAssertThrowsError(try TimedProcessRunner.run("/usr/bin/false", [], timeout: 5)) { error in
            guard case TimedProcessRunnerError.failed(_, let status, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertNotEqual(status, 0)
        }
    }

    func testTimedProcessRunnerKillsHungCommandInsteadOfBlocking() {
        let started = Date()
        XCTAssertThrowsError(try TimedProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)) { error in
            guard case TimedProcessRunnerError.timedOut = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "timeout must be enforced, not advisory")
    }

    func testDaemonCommandTimeoutIsBoundedWellBelowTheObservedHang() {
        // Each hung daemon subcommand polled for ~60s against a zombie pid; the switch must never
        // wait anywhere near that long for a best-effort restart.
        XCTAssertLessThanOrEqual(CodexAppServerDaemon.commandTimeout, 20)
    }
}
