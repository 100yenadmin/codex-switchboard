import Foundation
import XCTest
@testable import CodexSwitchboard
@testable import CodexSwitchboardCore

final class SwitchboardCLIClientTests: XCTestCase {
    func testArgumentsEnvironmentAndTimeout() throws {
        let root = URL(fileURLWithPath: "/fixture/app-support-isolated")
        var calls: [[String]] = []
        let client = SwitchboardCLIClient(executableURL: URL(fileURLWithPath: "/fixture/bin/codex-switchboard"), storageRoot: { root },
                                         environment: ["PATH": "/fixture/bin", "CODEX_SWITCHBOARD_APP_SUPPORT": "/wrong-root"]) { path, args, environment, timeout in
            XCTAssertEqual(path, "/fixture/bin/codex-switchboard")
            XCTAssertEqual(environment["CODEX_SWITCHBOARD_APP_SUPPORT"], root.path)
            XCTAssertEqual(environment["PATH"], "/fixture/bin")
            XCTAssertEqual(timeout, 90)
            calls.append(args)
            let json: String
            switch args.first {
            case "leases": json = "{\"generated_at\":\"2026-10-27T00:00:00Z\",\"leases\":[]}"
            case "status": json = "{\"generated_at\":\"2026-10-27T00:00:00Z\",\"accounts\":[]}"
            default: json = "{\"home\":\"/fixture/lane\"}"
            }
            return .init(status: 0, stdout: json, stderr: "ignored diagnostic")
        }
        _ = try client.leases()
        _ = try client.status()
        let lease = LeaseTestFixtures.lease()
        let target = LeaseTestFixtures.account()
        try client.returnLease(lease)
        try client.swapLease(lease, to: target)
        XCTAssertEqual(calls, [
            ["leases", "--json"], ["status", "--json"],
            ["return", "--profile-key", lease.handle, "--home", lease.home, "--json"],
            ["swap-lease", "--home", lease.home, "--holder", lease.holder, "--profile-key", target.handle, "--json"]
        ])
    }

    func testErrorsAndMissingCLIHideRawOutput() throws {
        for codeKey in ["code", "error"] {
            let client = SwitchboardCLIClient(executableURL: URL(fileURLWithPath: "/fixture/cli"), storageRoot: { URL(fileURLWithPath: "/fixture/storage") }) { _, _, _, _ in
                .init(status: 2, stdout: "{\"\(codeKey)\":\"holder_running\",\"message\":\"The holder is running\"}", stderr: "private diagnostic")
            }
            XCTAssertThrowsError(try client.leases()) { XCTAssertEqual($0.localizedDescription, "The holder is running") }
        }
        for status: Int32 in [0, 7] {
            let client = SwitchboardCLIClient(executableURL: URL(fileURLWithPath: "/fixture/cli"), storageRoot: { URL(fileURLWithPath: "/fixture/storage") }) { _, _, _, _ in
                .init(status: status, stdout: "untrusted private output", stderr: "private diagnostic")
            }
            XCTAssertThrowsError(try client.status()) {
                XCTAssertEqual($0.localizedDescription, "Switchboard CLI returned an unreadable response (exit \(status)).")
                XCTAssertFalse($0.localizedDescription.contains("private"))
            }
        }
        let missing = SwitchboardCLIClient(executableURL: nil, storageRoot: { XCTFail("Must not touch storage"); return URL(fileURLWithPath: "/fixture") }, runner: { _, _, _, _ in
            XCTFail("Must not run a missing CLI"); return .init(status: 0, stdout: "", stderr: "")
        })
        XCTAssertThrowsError(try missing.leases()) { XCTAssertEqual($0.localizedDescription, SwitchboardCLIClient.missingCLIMessage) }
    }

    func testRealCommandJSONContractUsesFixtureStorageOnly() throws {
        let fixture = try LeaseFixture(testCase: self)
        let home = fixture.root.appendingPathComponent("app-lane", isDirectory: true)
        let leased = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "app-fixture", "--json"])
        XCTAssertEqual(leased.exitCode, 0, leased.text)
        // The fixture's helper invokes execute in-process with its generated app support and home.
        let list = fixture.run(["leases", "--json"])
        XCTAssertEqual(list.exitCode, 0, list.text)
        let payload = try SwitchboardCLIClient.decode(AppLeasesPayload.self, from: list.text)
        let lease = try XCTUnwrap(payload.leases.first)
        XCTAssertTrue(CodexLease.sameHome(lease.home, home.path))
        XCTAssertEqual(lease.holder, "app-fixture")
        XCTAssertEqual(lease.email, "k@example.invalid")
        XCTAssertEqual(lease.handle, CodexAccountHandle.handle(for: "profile-k"))
        XCTAssertFalse(lease.holderRunning)
        XCTAssertFalse(lease.quarantined)
        XCTAssertTrue(lease.homeAuthPresent)
        let status = fixture.run(["status", "--json"])
        XCTAssertEqual(status.exitCode, 0, status.text)
        let accounts = try SwitchboardCLIClient.decode(AppLeaseStatusPayload.self, from: status.text).accounts
        let account = try XCTUnwrap(accounts.first { $0.profileKey == "profile-k" })
        XCTAssertTrue(account.leased)
        XCTAssertFalse(account.leasable)
        XCTAssertEqual(account.leaseHolder, "app-fixture")
        XCTAssertTrue(accounts.contains { $0.profileKey == "profile-b" && $0.leasable })
        try fixture.writeRegistry([["purpose": "bench", "profile_key": "profile-b", "codex_home": "~/reserved-home"]])
        let reserved = try SwitchboardCLIClient.decode(AppLeaseStatusPayload.self, from: fixture.run(["status", "--json"]).text)
        XCTAssertTrue(try XCTUnwrap(reserved.accounts.first { $0.profileKey == "profile-b" }).reserved)
    }

    @MainActor
    func testRefreshAndActionsOffMainThreadReloadAfterRefusal() async throws {
        let calls = CLIRequestRecorder()
        let lease = LeaseTestFixtures.lease()
        let client = SwitchboardCLIClient(executableURL: URL(fileURLWithPath: "/fixture/cli"), storageRoot: { URL(fileURLWithPath: "/fixture/storage") }) { _, args, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            calls.append(args)
            switch args.first {
            case "leases": return .init(status: 0, stdout: LeaseTestFixtures.leasesJSON, stderr: "")
            case "status": return .init(status: 0, stdout: LeaseTestFixtures.statusJSON, stderr: "")
            default: return .init(status: 2, stdout: "{\"error\":\"holder_running\",\"message\":\"The holder is running\"}", stderr: "")
            }
        }
        let model = LeasesViewModel(client: client)
        await model.refresh()
        XCTAssertEqual(model.leases.count, 1)
        XCTAssertEqual(model.accounts.count, 1)
        await model.perform(.init(lease: lease, target: nil))
        XCTAssertEqual(model.error, "The holder is running")
        XCTAssertEqual(calls.calls.map { $0[0] }, ["leases", "status", "return", "leases", "status"])
        XCTAssertFalse(model.isBusy)
        calls.clear()
        await model.perform(.init(lease: lease, target: LeaseTestFixtures.account()))
        XCTAssertEqual(calls.calls.map { $0[0] }, ["swap-lease", "leases", "status"])
    }

    @MainActor
    func testBothReadsAttemptedAndEligibilityClearedAfterReadFailure() async {
        let calls = CLIRequestRecorder()
        let client = SwitchboardCLIClient(executableURL: URL(fileURLWithPath: "/fixture/cli"), storageRoot: { URL(fileURLWithPath: "/fixture/storage") }) { _, args, _, _ in
            calls.append(args)
            return .init(status: 2, stdout: "garbage", stderr: "")
        }
        let model = LeasesViewModel(client: client)
        await model.refresh()
        XCTAssertEqual(calls.calls, [["leases", "--json"], ["status", "--json"]])
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNotNil(model.error)
    }
}

private final class CLIRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ arguments: [String]) { lock.lock(); defer { lock.unlock() }; stored.append(arguments) }
    func clear() { lock.lock(); defer { lock.unlock() }; stored = [] }
}

enum LeaseTestFixtures {
    static let leasesJSON = """
    {"generated_at":"2026-10-27T00:00:00Z","leases":[{
    "handle":"handle-old","email":"leased@example.invalid","lease_id":"lease-fixture","state":"leased","plan":"pro",
    "session_free_percent":20,"weekly_free_percent":50,"usable_for_codex":true,"needs_relogin":false,"score":20,
    "home":"/fixture/lane","holder":"bench-fixture","leased_at":"2026-10-27T00:00:00Z",
    "home_auth_present":true,"home_matches_stored_profile":true,"holder_running":false,"active_on_surface":false,
    "quarantined":false,"quarantined_since":null}]}
    """
    static let statusJSON = """
    {"generated_at":"2026-10-27T00:00:00Z","accounts":[{
    "profile_key":"fixture","handle":"handle-new","email":"target@example.invalid",
    "session_free_percent":75,"weekly_free_percent":90,"leased":false,"reserved":false,"leasable":true}]}
    """
    static func lease(running: Bool = false, quarantined: Bool = false, index: Int = 0) -> AppLease {
        var json = try! JSONSerialization.jsonObject(with: Data(leasesJSON.utf8)) as! [String: Any]
        var lease = (json["leases"] as! [[String: Any]])[0]
        lease["holder_running"] = running
        lease["quarantined"] = quarantined
        lease["lease_id"] = "lease-\(index)"
        lease["email"] = "leased\(index)@example.invalid"
        json["leases"] = [lease]
        return try! SwitchboardCLIClient.decode(AppLeasesPayload.self, from: String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8)!).leases[0]
    }
    static func account(leased: Bool = false, reserved: Bool = false) -> AppLeaseAccount {
        AppLeaseAccount(profileKey: "fixture", handle: "handle-new", email: "target@example.invalid", sessionFreePercent: 75, weeklyFreePercent: 90,
                        leased: leased, leaseHolder: leased ? "bench-fixture" : nil, reserved: reserved, leasable: !leased && !reserved)
    }
}
