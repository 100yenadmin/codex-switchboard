import Darwin
import Foundation
import XCTest
@testable import CodexSwitchboard
@testable import CodexSwitchboardCore

final class CodexProcessHomeTests: XCTestCase {
    func testParseUnset() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["PATH=/bin"])), .unset)
    }

    func testParseOneValue() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["CODEX_HOME=/tmp/lease"])), .path("/tmp/lease"))
    }

    func testParseDuplicateSameValue() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["CODEX_HOME=/tmp/lease", "CODEX_HOME=/tmp/lease"])), .path("/tmp/lease"))
    }

    func testParseAmbiguousValues() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["CODEX_HOME=/tmp/a", "CODEX_HOME=/tmp/b"])), .unreadable)
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["CODEX_HOME=", "CODEX_HOME=/tmp/b"])), .unreadable)
    }

    func testParseEmptyValue() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["CODEX_HOME="])), .unset)
    }

    func testParseTruncatedArgv() {
        var argc: Int32 = 2
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/bin/codex\0\0codex\0exec".utf8)
        XCTAssertEqual(CodexProcessHome.parseProcArgs(bytes), .unreadable)
        XCTAssertEqual(CodexProcessHome.parseProcArgs([0, 1]), .unreadable)
    }

    func testParseIgnoresArgvAssignment() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(argv: ["codex", "exec", "CODEX_HOME=/tmp/a"])), .unset)
    }

    func testParseRequiresExactEnvironmentName() {
        XCTAssertEqual(CodexProcessHome.parseProcArgs(buffer(environment: ["XCODEX_HOME=/tmp/a"])), .unset)
    }

    func testParseEnvironmentAtEndOfBuffer() {
        var bytes = buffer(environment: ["CODEX_HOME=/tmp/lease"])
        bytes.removeLast(2)
        XCTAssertEqual(CodexProcessHome.parseProcArgs(bytes), .path("/tmp/lease"))
    }

    func testUsesOtherHomeResolvesHomesAndFailsClosed() throws {
        let root = try temporaryDirectory()
        let main = try directory("main", in: root)
        let lease = try directory("lease", in: root)
        let link = root.appendingPathComponent("main-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: main)
        XCTAssertTrue(CodexProcessHome.usesOtherHome(.path(lease.path), surfaceHomes: [main.path]))
        for reading: CodexHomeReading in [
            .path(main.path), .path(main.path + "/"), .path(link.path),
            .path("relative/home"), .path("~/lease"), .path(root.appendingPathComponent("missing").path),
            .unset, .unreadable,
        ] {
            XCTAssertFalse(CodexProcessHome.usesOtherHome(reading, surfaceHomes: [main.path]), "\(reading)")
        }
        XCTAssertFalse(CodexProcessHome.usesOtherHome(.path(lease.path), surfaceHomes: []))
        XCTAssertFalse(CodexProcessHome.usesOtherHome(.path(lease.path), surfaceHomes: [main.path, lease.path]))
        XCTAssertFalse(CodexProcessHome.usesOtherHome(.path(main.path), surfaceHomes: [CodexLease.normalizedHome(main.path)]))
    }

    func testUsesOtherHomeMatchesAFirmlinkedSpellingOfTheSameDirectory() throws {
        let root = try temporaryDirectory()
        let main = try directory("main", in: root)
        let firmlinked = "/System/Volumes/Data" + CodexLease.normalizedHome(main.path)
        guard FileManager.default.fileExists(atPath: firmlinked) else {
            throw XCTSkip("No /System/Volumes/Data firmlink for the temporary directory")
        }
        XCTAssertFalse(CodexProcessHome.usesOtherHome(.path(firmlinked), surfaceHomes: [main.path]))
        XCTAssertFalse(CodexProcessHome.usesOtherHome(.path(main.path), surfaceHomes: [firmlinked]))
    }

    func testCoreConsumerFilterKeepsFailClosedAndDesktopConsumers() throws {
        let root = try temporaryDirectory()
        let main = try directory("main", in: root)
        let lease = try directory("lease", in: root)
        var reads = [Int32]()
        let source = CodexConsumerProcesses(
            listing: { self.processes },
            homeReading: { pid in
                reads.append(pid)
                return self.homeReading(pid, main: main.path, lease: lease.path)
            },
            isDesktop: { $0 == self.desktopCommand }
        )
        XCTAssertEqual(source.consumers(surfaceHomes: [main.path]).map(\.pid), [102, 103, 104, 105])
        XCTAssertEqual(reads, [101, 102, 103, 104])
        reads = []
        XCTAssertEqual(source.consumers(surfaceHomes: [main.path], includeDesktop: false).map(\.pid), [102, 103, 104])
        XCTAssertEqual(reads, [101, 102, 103, 104])
    }

    func testCLISwitchExcludesOtherHomesAndBlocksMainOrUnknownHomes() throws {
        let fixture = try LeaseFixture(testCase: self)
        let lease = try directory("lane", in: fixture.root)
        let main = fixture.home.appendingPathComponent(".codex").path
        for reading: CodexHomeReading in [.path(lease.path), .unset, .path(main), .unreadable] {
            let result = fixture.run(
                ["switch", "--profile-key", "profile-k", "--surface", "cli", "--json"],
                processes: CodexConsumerProcesses(
                    listing: { [(101, "codex exec task")] },
                    homeReading: { _ in reading },
                    isDesktop: { _ in false }
                )
            )
            if reading == .path(lease.path) {
                XCTAssertEqual(result.exitCode, 0, result.text)
            } else {
                XCTAssertEqual(result.json["error"] as? String, "consumers_running", result.text)
            }
        }

    }

    func testAppSwitchConsumerFilterKeepsFailClosedAndDesktopConsumers() throws {
        let root = try temporaryDirectory()
        let main = try directory("main", in: root)
        let lease = try directory("lease", in: root)
        var reads = [Int32]()
        let result = CodexAccountSwitchService.codexProcessDescriptions(
            cliHome: main.path, desktopHome: main.path, includeDesktopConsumers: true,
            processListing: { self.processes.map { "\($0.pid) \($0.command)" }.joined(separator: "\n") },
            homeReading: { pid in
                reads.append(pid)
                return self.homeReading(pid, main: main.path, lease: lease.path)
            },
            isDesktop: { $0 == self.desktopCommand }
        )
        XCTAssertEqual(result.map { String($0.prefix(3)) }, ["102", "103", "104", "105"])
        XCTAssertEqual(reads, [101, 102, 103, 104])
        let partner = CodexAccountSwitchService.codexProcessDescriptions(
            cliHome: main.path, desktopHome: lease.path, includeDesktopConsumers: true,
            processListing: { "101 codex exec task" }, homeReading: { _ in .path(lease.path) },
            isDesktop: { _ in false }
        )
        XCTAssertEqual(partner.count, 1)
        let isolated = CodexAccountSwitchService.codexProcessDescriptions(
            cliHome: main.path, desktopHome: lease.path, includeDesktopConsumers: false,
            processListing: { "101 codex exec task\n105 \(self.desktopCommand)" },
            homeReading: { _ in .path(lease.path) }, isDesktop: { $0 == self.desktopCommand }
        )
        XCTAssertTrue(isolated.isEmpty)
    }

    func testAppCLIRunningUsesReportedHomeAndOnlyReadsMatches() throws {
        let root = try temporaryDirectory()
        let main = try directory("main", in: root)
        let lease = try directory("lease", in: root)
        for reading: CodexHomeReading in [.path(lease.path), .unset, .path(main.path), .unreadable] {
            let running = CodexSurfaceService.isCLIRunning(
                in: main.path, processListing: { ["100 /bin/sleep 30", "101 codex exec task"] },
                homeReading: { pid in XCTAssertEqual(pid, 101); return reading },
                isDesktop: { _ in false }
            )
            XCTAssertEqual(running, reading != .path(lease.path))
        }
    }

    func testLiveReaderForSpawnedChild() throws {
        let root = try temporaryDirectory()
        let lease = try directory("lease", in: root)
        let executable = root.appendingPathComponent("codex")
        // macOS hides the environment of Apple platform binaries, so the child is an ad-hoc re-signed copy of sleep.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", executable.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        child.environment = ["CODEX_HOME": lease.path]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        // posix_spawn may return before the child has finished setting up its argument snapshot.
        let deadline = Date().addingTimeInterval(1)
        var reading = CodexProcessHome.reading(pid: child.processIdentifier)
        while reading != .path(lease.path), Date() < deadline {
            if case .path = reading { break }
            Thread.sleep(forTimeInterval: 0.01)
            reading = CodexProcessHome.reading(pid: child.processIdentifier)
        }
        guard case let .path(home) = reading else {
            return XCTFail("Could not read spawned child's CODEX_HOME: \(reading)")
        }
        XCTAssertTrue(CodexLease.sameHome(home, lease.path))
    }

    private let desktopCommand = "/applications/codex.app/contents/macos/codex-desktop"
    private var processes: [(pid: Int32, command: String)] {
        [(101, "codex exec lease"), (102, "codex exec default"), (103, "codex exec main"),
         (104, "codex exec unreadable"), (105, desktopCommand), (106, "/bin/sleep 30")]
    }

    private func homeReading(_ pid: Int32, main: String, lease: String) -> CodexHomeReading {
        switch pid {
        case 101, 105: return .path(lease)
        case 102: return .unset
        case 103: return .path(main)
        default: return .unreadable
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("consumer-homes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func directory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func buffer(argv: [String] = ["codex", "exec"], environment: [String] = []) -> [UInt8] {
        var argc = Int32(argv.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/bin/codex\0\0\0".utf8)
        for arg in argv { bytes += Array(arg.utf8) + [0] }
        for entry in environment { bytes += Array(entry.utf8) + [0] }
        bytes += [0]
        return bytes
    }
}
