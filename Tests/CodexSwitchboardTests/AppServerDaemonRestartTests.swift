import Darwin
import Foundation
import XCTest
@testable import CodexSwitchboard

final class AppServerDaemonRestartTests: XCTestCase {
    private func makeTempCodexHome() throws -> URL {
        // Short suffix on purpose: the socket tests need the full
        // `<home>/app-server-control/app-server-control.sock` path to fit in sockaddr_un (104 bytes).
        let suffix = String(UUID().uuidString.prefix(6))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-\(suffix)", isDirectory: true)
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

    func testControlSocketPathMatchesCodexLayout() throws {
        let home = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let socketURL = CodexAppServerDaemon.controlSocketURL(codexHome: home)
        XCTAssertEqual(socketURL.lastPathComponent, "app-server-control.sock")
        XCTAssertEqual(socketURL.deletingLastPathComponent().lastPathComponent, "app-server-control")
    }

    func testStaleSocketFileWithoutListenerIsNotConsideredRunning() throws {
        let home = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let socketURL = CodexAppServerDaemon.controlSocketURL(codexHome: home)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Crash leftovers: a plain file at the socket path, then a real socket nobody listens on.
        FileManager.default.createFile(atPath: socketURL.path, contents: nil)
        XCTAssertFalse(CodexAppServerDaemon.isLikelyRunning(codexHome: home))

        try FileManager.default.removeItem(at: socketURL)
        let listener = try makeListeningSocket(at: socketURL.path)
        close(listener)  // socket file stays, listener is gone
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(CodexAppServerDaemon.isLikelyRunning(codexHome: home))
    }

    func testLiveListenerOnControlSocketIsConsideredRunning() throws {
        let home = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let socketURL = CodexAppServerDaemon.controlSocketURL(codexHome: home)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let listener = try makeListeningSocket(at: socketURL.path)
        defer { close(listener) }

        XCTAssertTrue(CodexAppServerDaemon.isLikelyRunning(codexHome: home))
    }

    /// Binds a listening AF_UNIX socket at `path`, skipping the test when the path is too long for
    /// `sockaddr_un` (a limitation of the temp dir, not of the code under test).
    private func makeListeningSocket(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        if bytes.count >= capacity {
            throw XCTSkip("temp socket path too long for sockaddr_un (\(bytes.count) >= \(capacity))")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(listen(fd, 4), 0)
        return fd
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

    func testTimedProcessRunnerEscalatesToSIGKILLWhenChildIgnoresSIGTERM() {
        let started = Date()
        XCTAssertThrowsError(try TimedProcessRunner.run(
            "/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.5
        )) { error in
            guard case TimedProcessRunnerError.timedOut = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        // 0.5s timeout + 2s SIGTERM grace, then SIGKILL; must not wait for the 30s sleep.
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testTimedProcessRunnerReturnsWhenAGrandchildKeepsThePipeOpen() {
        // The killed shell's background child inherits stdout and keeps the pipe open; the drain
        // thread stays blocked, and the runner must neither wait for it nor touch the handle.
        let started = Date()
        XCTAssertThrowsError(try TimedProcessRunner.run(
            "/bin/sh", ["-c", "sleep 30 & sleep 30"], timeout: 0.5
        )) { error in
            guard case TimedProcessRunnerError.timedOut = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testTimedProcessRunnerDrainsChattyOutputWithoutDeadlock() throws {
        // 1 MiB of output is well past the 64 KiB pipe buffer; an in-line waitUntilExit would hang.
        let output = try TimedProcessRunner.run(
            "/bin/sh", ["-c", "head -c 1048576 /dev/zero | tr '\\0' 'x'"], timeout: 10
        )
        XCTAssertEqual(output.count, 1_048_576)
    }

    func testDaemonCommandTimeoutIsBoundedWellBelowTheObservedHang() {
        // Each hung daemon subcommand polled for ~60s against a zombie pid; the switch must never
        // wait anywhere near that long for a best-effort restart.
        XCTAssertLessThanOrEqual(CodexAppServerDaemon.commandTimeout, 20)
    }
}
