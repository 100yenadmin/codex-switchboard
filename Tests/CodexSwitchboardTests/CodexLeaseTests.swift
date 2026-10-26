import Foundation
import XCTest
@testable import CodexSwitchboard
@testable import CodexSwitchboardCore

/// Leases, run through the real CLI entry point against a fake home and fake app storage. Every
/// auth file here is generated; nothing reads or writes the machine's own Codex or Switchboard state.
final class CodexLeaseTests: XCTestCase {
    private var fixture: LeaseFixture!

    override func setUpWithError() throws {
        fixture = try LeaseFixture(testCase: self)
    }

    func testLeaseThenReturnRoundTripsRotatedRefreshToken() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.exitCode, 0, lease.text)
        XCTAssertEqual(lease.json["auth_written"] as? Bool, true)
        let homeAuth = home.appendingPathComponent("auth.json")
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-1")
        XCTAssertEqual(fixture.permissions(of: homeAuth), 0o600)
        XCTAssertEqual(fixture.permissions(of: home), 0o700)

        let status = fixture.run(["status", "--json"])
        let leased = try XCTUnwrap(fixture.account("profile-k", in: status.json))
        XCTAssertEqual(leased["leased"] as? Bool, true)
        XCTAssertEqual(leased["lease_holder"] as? String, "bench")
        let usable = fixture.run(["status", "--json", "--usable-only"])
        XCTAssertNil(fixture.account("profile-k", in: usable.json))

        // The lane's Codex refreshes its token: a new access token and a new single-use refresh token.
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(returned.exitCode, 0, returned.text)
        XCTAssertEqual(returned.json["sync"] as? String, "rotated")
        XCTAssertEqual(returned.json["home_auth_tombstoned"] as? Bool, true)
        XCTAssertEqual(returned.json["lease_id"] as? String, lease.json["lease_id"] as? String)
        XCTAssertNil(fixture.refreshToken(in: homeAuth))
        XCTAssertEqual(CodexLeaseTombstone.leaseID(at: homeAuth), lease.json["lease_id"] as? String)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-2")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load(), [])

        let list = fixture.run(["leases", "--json"])
        XCTAssertEqual((list.json["leases"] as? [Any])?.count, 0)
    }

    func testOutputNeverCarriesTokensOrIdentity() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let outputs = [
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]),
            fixture.run(["leases", "--json"]),
            fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"]),
        ]
        for output in outputs {
            XCTAssertEqual(output.exitCode, 0, output.text)
            for secret in ["refresh-k-1", "access-k-1", "k@example.invalid", "acct-k", "sub-k"] {
                XCTAssertFalse(output.text.contains(secret), "\(secret) leaked into lease output")
            }
        }
    }

    func testDoubleLeaseIsRefused() throws {
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", first.path, "--holder", "one", "--json"]).exitCode,
            0
        )

        let again = fixture.run(["lease", "--profile-key", "profile-k", "--home", second.path, "--holder", "two", "--json"])
        XCTAssertEqual(again.exitCode, 2)
        XCTAssertEqual(again.json["error"] as? String, "already_leased")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("auth.json").path))

        let sameHome = fixture.run(["lease", "--profile-key", "profile-b", "--home", first.path, "--holder", "two", "--json"])
        XCTAssertEqual(sameHome.json["error"] as? String, "home_already_leased")
        XCTAssertEqual(fixture.refreshToken(in: first.appendingPathComponent("auth.json")), "refresh-k-1")
    }

    func testLeaseOfActiveCLIAccountIsRefused() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(["lease", "--profile-key", "profile-a", "--home", home.path, "--holder", "bench", "--json"])

        XCTAssertEqual(lease.exitCode, 2)
        XCTAssertEqual(lease.json["error"] as? String, "active_account")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load(), [])
    }

    func testLeaseRefusesFreePlanAndOtherSignIns() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let free = fixture.run(["lease", "--profile-key", "profile-f", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(free.json["error"] as? String, "free_plan")

        // A home with its own sign-in, like a device-code login, is never overwritten.
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "b", generation: 9, to: homeAuth)
        let otherAccount = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(otherAccount.json["error"] as? String, "home_holds_other_account")

        try fixture.writeAuth(account: "k", generation: 9, to: homeAuth)
        let otherLogin = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(otherLogin.json["error"] as? String, "home_holds_other_login")
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-9")

        let surfaceHome = fixture.run([
            "lease", "--profile-key", "profile-k", "--home", fixture.home.appendingPathComponent(".codex").path,
            "--holder", "bench", "--json",
        ])
        XCTAssertEqual(surfaceHome.json["error"] as? String, "home_not_allowed")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load(), [])
    }

    func testSwitchRefusesLeasedAccount() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let liveAuth = fixture.home.appendingPathComponent(".codex/auth.json")
        let before = try Data(contentsOf: liveAuth)

        let switched = fixture.run(["switch", "--profile-key", "profile-k", "--surface", "cli", "--json"])

        XCTAssertEqual(switched.exitCode, 2)
        XCTAssertEqual(switched.json["error"] as? String, "account_leased")
        XCTAssertEqual(try Data(contentsOf: liveAuth), before)
    }

    func testAutoSwapSkipsReservedAccount() throws {
        try AutoSwapPolicyStore(url: fixture.appSupport.appendingPathComponent("auto-swap-policy.json"))
            .save(AutoSwapPolicy(enabledSurfaces: [.cli]))
        let dryRun = ["autoswap", "run-once", "--surface", "cli", "--json", "--dry-run"]
        XCTAssertEqual(fixture.candidate(in: fixture.run(dryRun)), "profile-k")

        try fixture.writeRegistry([["purpose": "bench", "codex_home": "~/bench-home", "profile_key": "profile-k"]])

        XCTAssertEqual(fixture.candidate(in: fixture.run(dryRun)), "profile-b")
    }

    func testAutoSwapSkipsLeasedAccount() throws {
        try AutoSwapPolicyStore(url: fixture.appSupport.appendingPathComponent("auto-swap-policy.json"))
            .save(AutoSwapPolicy(enabledSurfaces: [.cli]))
        let dryRun = ["autoswap", "run-once", "--surface", "cli", "--json", "--dry-run"]
        XCTAssertEqual(fixture.candidate(in: fixture.run(dryRun)), "profile-k")

        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )

        XCTAssertEqual(fixture.candidate(in: fixture.run(dryRun)), "profile-b")
    }

    func testDecisionEngineNeverPicksLeasedCandidate() {
        let decision = AutoSwapDecisionEngine.evaluate(
            policy: AutoSwapPolicy(enabledSurfaces: [.cli]),
            surface: AutoSwapSurface(
                kind: .cli,
                detected: true,
                supportsFileSwitching: true,
                activeProfileKey: "active",
                authStoreMode: "file"
            ),
            accounts: [
                AutoSwapAccount(profileKey: "active", sessionFreePercent: 1, weeklyFreePercent: 50,
                                usableForCodex: true, needsRelogin: false, isFreePlan: false, score: 1),
                AutoSwapAccount(profileKey: "leased", sessionFreePercent: 99, weeklyFreePercent: 99,
                                usableForCodex: true, needsRelogin: false, isFreePlan: false, score: 99,
                                isLeased: true),
            ],
            history: []
        )

        XCTAssertEqual(decision.decision, .blocked)
        XCTAssertEqual(decision.reason, .noCandidate)
    }

    func testReturnRefusesWhileCodexUsesTheHome() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let consumer = try fixture.startFakeCodex(codexHome: home)
        defer { consumer.terminate() }

        let busy = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(busy.exitCode, 2)
        XCTAssertEqual(busy.json["error"] as? String, "home_in_use")
        let details = try XCTUnwrap(busy.json["details"] as? [String])
        XCTAssertTrue(details.contains("\(consumer.processIdentifier) sh"), "\(details)")
        XCTAssertFalse(busy.text.contains("consumer/codex"), "full command lines must not leak")
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().count, 1)

        consumer.terminate()
        consumer.waitUntilExit()
        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(returned.exitCode, 0, returned.text)
        XCTAssertEqual(returned.json["sync"] as? String, "unchanged")
    }

    func testReturnNeverDeletesAnotherAccountsAuth() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "b", generation: 5, to: homeAuth)

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])

        XCTAssertEqual(returned.json["error"] as? String, "home_holds_other_account")
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-b-5")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().count, 1)
    }

    func testMirrorWritesLeaseHomeRotationIntoStoredProfile() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let mirror = CodexAuthMirrorService(
            authURL: fixture.home.appendingPathComponent(".codex/auth.json"),
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        )
        XCTAssertEqual(mirror.syncLeasedHomes().map(\.reason), ["unchanged"])

        try fixture.writeAuth(account: "k", generation: 2, to: home.appendingPathComponent("auth.json"))
        let results = mirror.syncLeasedHomes()

        XCTAssertEqual(results.map(\.status), [.synced])
        XCTAssertEqual(results.map(\.profileKey), ["profile-k"])
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-2")
        let list = fixture.run(["leases", "--json"])
        let entry = try XCTUnwrap((list.json["leases"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["home_matches_stored_profile"] as? Bool, true)
    }

    func testLiveAuthMirrorLeavesLeasedProfileToItsLeaseHome() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let strayLiveAuth = fixture.root.appendingPathComponent("stray-auth.json")
        try fixture.writeAuth(account: "k", generation: 7, to: strayLiveAuth)

        let result = CodexAuthMirrorService(
            authURL: strayLiveAuth,
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.reason, "leased profile")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
    }

    func testUnreadableLeaseStoreFailsClosed() throws {
        try Data("{not json".utf8).write(to: fixture.appSupport.appendingPathComponent("leases.json"))
        let liveAuth = fixture.home.appendingPathComponent(".codex/auth.json")
        let before = try Data(contentsOf: liveAuth)

        let switched = fixture.run(["switch", "--profile-key", "profile-k", "--surface", "cli", "--json"])
        let leased = fixture.run([
            "lease", "--profile-key", "profile-k", "--home", fixture.root.appendingPathComponent("lane").path,
            "--holder", "bench", "--json",
        ])

        XCTAssertEqual(switched.exitCode, 2)
        XCTAssertEqual(switched.json["error"] as? String, "lease_store_unreadable")
        XCTAssertEqual(leased.json["error"] as? String, "lease_store_unreadable")
        XCTAssertEqual(try Data(contentsOf: liveAuth), before)
        let leasable = (fixture.run(["status", "--json"]).json["accounts"] as? [[String: Any]] ?? [])
            .compactMap { $0["leasable"] as? Bool }
        XCTAssertEqual(Set(leasable), [false])
    }

    func testLeaseWaitsForAnInFlightAppRefresh() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let reservations = CodexRefreshReservations(appSupportURL: fixture.appSupport)
        try reservations.reserve(profileKey: "profile-k")

        let busy = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(busy.json["error"] as? String, "refresh_in_progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))

        // A reservation left behind by an app that died mid-grant expires.
        try reservations.reserve(
            profileKey: "profile-k",
            now: Date().addingTimeInterval(-CodexRefreshReservations.maxAge - 1)
        )
        let leased = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(leased.exitCode, 0, leased.text)
    }

    func testRefreshReservationHoldsWhileItsAppRuns() throws {
        let reservations = CodexRefreshReservations(appSupportURL: fixture.appSupport)
        let old = Date().addingTimeInterval(-CodexRefreshReservations.maxAge - 1)
        try reservations.reserve(profileKey: "profile-k", pid: 4242, now: old)

        XCTAssertTrue(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [4242]))
        XCTAssertFalse(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [7]))
        try reservations.release(profileKey: "profile-k")
        XCTAssertTrue(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [4242]), "only its own app releases it")
        try reservations.release(profileKey: "profile-k", pid: 4242)
        XCTAssertFalse(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [4242]))

        // No grant takes this long, so a running pid this old is a reused one.
        let longAgo = Date().addingTimeInterval(-CodexRefreshReservations.maxHoldWhileRunning - 1)
        try reservations.reserve(profileKey: "profile-k", pid: 4242, now: longAgo)
        XCTAssertFalse(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [4242]))
    }

    func testOnlyOneAppHoldsARefreshGrantAtATime() throws {
        let reservations = CodexRefreshReservations(appSupportURL: fixture.appSupport)
        let old = Date().addingTimeInterval(-CodexRefreshReservations.maxAge - 1)
        // Another app still running holds its reservation past maxAge, until no grant could still be in flight.
        let otherApp = Process()
        otherApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        otherApp.arguments = ["30"]
        try otherApp.run()
        defer { otherApp.terminate() }
        try reservations.reserve(profileKey: "profile-k", pid: otherApp.processIdentifier, now: old)
        XCTAssertThrowsError(try reservations.reserve(profileKey: "profile-k")) { error in
            XCTAssertTrue(error is CodexRefreshReservations.HeldElsewhere)
        }
        let longAgo = Date().addingTimeInterval(-CodexRefreshReservations.maxHoldWhileRunning - 1)
        try reservations.reserve(profileKey: "profile-k", pid: otherApp.processIdentifier, now: longAgo)
        XCTAssertNoThrow(try reservations.reserve(profileKey: "profile-k"))

        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        try reservations.reserve(profileKey: "profile-b", pid: exited.processIdentifier)
        XCTAssertThrowsError(try reservations.reserve(profileKey: "profile-b"), "a fresh reservation holds even after its app exits")
        try reservations.reserve(profileKey: "profile-b", pid: exited.processIdentifier, now: old)
        XCTAssertNoThrow(try reservations.reserve(profileKey: "profile-b"))
    }

    func testReturnKeepsHomeAuthWhenTheLentCopysMetadataCannotBeRead() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        // A second copy of the account that would otherwise let the sync look complete.
        let spare = fixture.appSupport.appendingPathComponent("profiles/k-spare", isDirectory: true)
        try fixture.writeAuth(account: "k", generation: 1, to: spare.appendingPathComponent("auth.json"))
        try FileManager.default.copyItem(
            at: fixture.appSupport.appendingPathComponent("profiles/k/meta.json"),
            to: spare.appendingPathComponent("meta.json")
        )
        try Data("{broken".utf8).write(to: fixture.appSupport.appendingPathComponent("profiles/k/meta.json"))

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])

        XCTAssertNotEqual(returned.exitCode, 0)
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-2")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().count, 1)
    }

    func testLeaseRefusesSymlinkIntoAppStorage() throws {
        let link = fixture.root.appendingPathComponent("storage-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.appSupport)

        let lease = fixture.run([
            "lease", "--profile-key", "profile-k", "--home", link.appendingPathComponent("new-home").path,
            "--holder", "bench", "--json",
        ])

        XCTAssertEqual(lease.json["error"] as? String, "home_not_allowed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appSupport.appendingPathComponent("new-home").path))
    }

    func testReturnKeepsHomeAuthWhenAStoredCopyCannotBeRead() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        try Data("{broken".utf8).write(to: fixture.appSupport.appendingPathComponent("accounts.json"))

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])

        XCTAssertNotEqual(returned.exitCode, 0)
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-2")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().count, 1)
    }

    func testSwitchboardAppDetectionCoversBareBuildsButNotTheCLI() {
        XCTAssertTrue(isSwitchboardAppCommand("/Users/x/Applications/CodexSwitchboard.app/Contents/MacOS/CodexSwitchboard"))
        XCTAssertTrue(isSwitchboardAppCommand("/Users/x/src/codex-switchboard/.build/release/CodexSwitchboard"))
        XCTAssertTrue(isSwitchboardAppCommand("/Users/x/.build/debug/CodexSwitchboard --fixture-snapshot-only"))
        XCTAssertFalse(isSwitchboardAppCommand("/Users/x/.build/release/codex-switchboard leases --json"))
        XCTAssertFalse(isSwitchboardAppCommand("/usr/bin/xctest /x/CodexSwitchboardPackageTests.xctest"))
    }

    func testLeaseMirrorMarkerMustMatchEveryRunningApp() {
        XCTAssertTrue(CodexLeaseMirrorMarker.isReady(runningAppPIDs: [], recordedPID: nil))
        XCTAssertTrue(CodexLeaseMirrorMarker.isReady(runningAppPIDs: [42], recordedPID: 42))
        XCTAssertFalse(CodexLeaseMirrorMarker.isReady(runningAppPIDs: [42], recordedPID: nil))
        XCTAssertFalse(CodexLeaseMirrorMarker.isReady(runningAppPIDs: [42, 43], recordedPID: 42))
    }

    func testStatusMarksWhichAccountsAgentsCanLease() throws {
        func leasable(_ output: (exitCode: Int32, text: String, json: [String: Any])) -> [String: Bool] {
            let accounts = output.json["accounts"] as? [[String: Any]] ?? []
            return Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
                (account["profile_key"] as? String).map { ($0, account["leasable"] as? Bool ?? false) }
            })
        }
        XCTAssertEqual(
            leasable(fixture.run(["status", "--json"])),
            ["profile-a": false, "profile-k": true, "profile-b": true, "profile-f": false]
        )

        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let leasableOnly = fixture.run(["status", "--json", "--leasable-only"])
        let free = leasableOnly.json["accounts"] as? [[String: Any]] ?? []
        XCTAssertEqual(free.compactMap { $0["handle"] as? String }, [CodexAccountHandle.handle(for: "profile-b")])
        XCTAssertFalse(leasableOnly.text.contains("profile-"))
        XCTAssertFalse(leasableOnly.text.contains("@example.invalid"))

        let lease = try XCTUnwrap((fixture.run(["leases", "--json"]).json["leases"] as? [[String: Any]])?.first)
        XCTAssertEqual(lease["plan"] as? String, "pro")
        XCTAssertEqual(lease["session_free_percent"] as? Double, 95)
        XCTAssertEqual(lease["weekly_free_percent"] as? Double, 95)
    }

    func testSwapLeaseMovesTheLaneToTheBestFreeAccount() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)

        let swapped = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])

        XCTAssertEqual(swapped.exitCode, 0, swapped.text)
        XCTAssertEqual(swapped.json["returned_handle"] as? String, CodexAccountHandle.handle(for: "profile-k"))
        XCTAssertEqual(swapped.json["return_sync"] as? String, "rotated")
        XCTAssertEqual(swapped.json["leased_handle"] as? String, CodexAccountHandle.handle(for: "profile-b"))
        XCTAssertEqual(swapped.json["holder"] as? String, "bench")
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-b-1")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-b"])

        let none = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--exclude-profile-key", "profile-k", "--json"])
        XCTAssertEqual(none.json["error"] as? String, "no_candidate")
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-b-1")
    }

    func testSwapLeaseRefusalLeavesTheLaneAsItWas() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")

        let free = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--profile-key", "profile-f", "--json"])
        XCTAssertEqual(free.json["error"] as? String, "free_plan")
        let active = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--profile-key", "profile-a", "--json"])
        XCTAssertEqual(active.json["error"] as? String, "active_account")

        try CodexRefreshReservations(appSupportURL: fixture.appSupport).reserve(profileKey: "profile-b")
        let refreshing = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--profile-key", "profile-b", "--json"])
        XCTAssertEqual(refreshing.json["error"] as? String, "refresh_in_progress")
        // Without a choice, the account being refreshed is not a candidate at all.
        let unchosen = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(unchosen.json["error"] as? String, "no_candidate")
        try CodexRefreshReservations(appSupportURL: fixture.appSupport).release(profileKey: "profile-b")

        let malformed = fixture.run(["swap-lease", "--home", home.path, "--exclude-profile-key", "--holder", "bench", "--json"])
        XCTAssertEqual(malformed.exitCode, 64)
        // A flag between an option and a later word does not make that word the option's value.
        let shifted = fixture.run([
            "swap-lease", "--home", home.path, "--holder", "bench", "--exclude-profile-key", "--json", "profile-b",
        ])
        XCTAssertEqual(shifted.exitCode, 64)

        let consumer = try fixture.startFakeCodex(codexHome: home)
        defer { consumer.terminate() }
        let busy = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(busy.json["error"] as? String, "home_in_use")

        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])
    }

    func testOnlyTheLeasesHolderSwapsIt() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )

        let other = fixture.run(["swap-lease", "--home", home.path, "--holder", "autoswap-agent", "--json"])
        XCTAssertEqual(other.json["error"] as? String, "holder_mismatch")
        let anonymous = fixture.run(["swap-lease", "--home", home.path, "--json"])
        XCTAssertEqual(anonymous.exitCode, 64)

        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])
    }

    func testQuarantinedHomeIsNeverReturnedSwappedOrLeasedInto() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        let sentinel = home.appendingPathComponent("auth.json.stopped")
        try Data("credential refused 2026-10-26T00:00:00Z\n".utf8).write(to: sentinel)

        let account = try XCTUnwrap(fixture.account("profile-k", in: fixture.run(["status", "--json"]).json))
        XCTAssertEqual(account["lease_quarantined"] as? Bool, true)
        let entry = try XCTUnwrap((fixture.run(["leases", "--json"]).json["leases"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["quarantined"] as? Bool, true)
        XCTAssertNotNil(entry["quarantined_since"] as? String)

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(returned.json["error"] as? String, "home_quarantined")
        let swapped = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(swapped.json["error"] as? String, "home_quarantined")
        let mirror = CodexAuthMirrorService(
            authURL: fixture.home.appendingPathComponent(".codex/auth.json"),
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        )
        XCTAssertEqual(mirror.syncLeasedHomes().map(\.reason), ["home_quarantined"])

        // Nothing moved: the possibly spent chain stays in the home, the stored copy keeps its own.
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-2")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])

        let stopped = fixture.root.appendingPathComponent("stopped-home", isDirectory: true)
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        try Data("refresh failed\n".utf8).write(to: stopped.appendingPathComponent("auth.json.stopped"))
        let leased = fixture.run(["lease", "--profile-key", "profile-b", "--home", stopped.path, "--holder", "bench", "--json"])
        XCTAssertEqual(leased.json["error"] as? String, "home_quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.appendingPathComponent("auth.json").path))
    }

    func testReservedLoginsAreNeverLeased() throws {
        let registry = fixture.home.appendingPathComponent(".config/codex-logins/registry.json")
        try fixture.writeRegistry([["purpose": "bench-director", "codex_home": "~/bench-home", "profile_key": "profile-b"]])

        let account = try XCTUnwrap(fixture.account("profile-b", in: fixture.run(["status", "--json"]).json))
        XCTAssertEqual(account["reserved"] as? Bool, true)
        XCTAssertEqual(account["leasable"] as? Bool, false)
        let reserved = fixture.run([
            "lease", "--profile-key", "profile-b", "--home", fixture.root.appendingPathComponent("lane").path,
            "--holder", "bench", "--json",
        ])
        XCTAssertEqual(reserved.json["error"] as? String, "reserved_account")
        let benchHome = fixture.home.appendingPathComponent("bench-home", isDirectory: true)
        let intoReservedHome = fixture.run([
            "lease", "--profile-key", "profile-k", "--home", benchHome.path, "--holder", "bench", "--json",
        ])
        XCTAssertEqual(intoReservedHome.json["error"] as? String, "home_reserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: benchHome.path))

        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let automatic = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(automatic.json["error"] as? String, "no_candidate")
        let explicit = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--profile-key", "profile-b", "--json"])
        XCTAssertEqual(explicit.json["error"] as? String, "reserved_account")
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-1")

        // A registry that cannot be checked reserves everything, as codex-logins.py check-switch does.
        try fixture.writeRegistry([["purpose": "unkeyed", "codex_home": "~/other"]])
        let unkeyed = fixture.run([
            "lease", "--profile-key", "profile-b", "--home", fixture.root.appendingPathComponent("lane-2").path,
            "--holder", "bench", "--json",
        ])
        XCTAssertEqual(unkeyed.json["error"] as? String, "reserved_registry_unreadable")
        try Data("{not json".utf8).write(to: registry)
        let leasable = (fixture.run(["status", "--json"]).json["accounts"] as? [[String: Any]] ?? [])
            .compactMap { $0["leasable"] as? Bool }
        XCTAssertEqual(Set(leasable), [false])

        // A registry that cannot even be looked for is not a missing one.
        guard getuid() != 0 else { return }
        try fixture.writeRegistry([["purpose": "bench-director", "codex_home": "~/bench-home", "profile_key": "profile-b"]])
        let directory = registry.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let hidden = fixture.run([
            "lease", "--profile-key", "profile-b", "--home", fixture.root.appendingPathComponent("lane-3").path,
            "--holder", "bench", "--json",
        ])
        XCTAssertEqual(hidden.json["error"] as? String, "reserved_registry_unreadable")
        let hiddenLeasable = (fixture.run(["status", "--json"]).json["accounts"] as? [[String: Any]] ?? [])
            .compactMap { $0["leasable"] as? Bool }
        XCTAssertEqual(Set(hiddenLeasable), [false])
    }

    func testLeaseCommandsWaitForTheHoldersAuthLock() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        let quick = ["CODEX_SWITCHBOARD_HOME_LOCK_TIMEOUT_SECONDS": "0.2"]
        let mirror = CodexAuthMirrorService(
            authURL: fixture.home.appendingPathComponent(".codex/auth.json"),
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        )

        // The holder is mid-refresh: it has flock(LOCK_EX) on auth.json.lock, as the director does.
        let held = try fixture.holdAuthLock(in: home)
        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"], environment: quick)
        XCTAssertEqual(returned.json["error"] as? String, "home_locked")
        let swapped = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"], environment: quick)
        XCTAssertEqual(swapped.json["error"] as? String, "home_locked")
        XCTAssertEqual(mirror.syncLeasedHomes().map(\.reason), ["home_locked"])
        let other = fixture.root.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherHeld = try fixture.holdAuthLock(in: other)
        let leased = fixture.run(
            ["lease", "--profile-key", "profile-b", "--home", other.path, "--holder", "bench", "--json"],
            environment: quick
        )
        XCTAssertEqual(leased.json["error"] as? String, "home_locked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("auth.json").path))
        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-2")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])

        fixture.releaseAuthLock(held)
        fixture.releaseAuthLock(otherHeld)
        XCTAssertEqual(mirror.syncLeasedHomes().map(\.status), [.synced])
        let done = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"], environment: quick)
        XCTAssertEqual(done.exitCode, 0, done.text)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
    }

    func testSwapRefusesARunningPythonHolderAndKeepsItsRotationAfterItExits() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("needs /usr/bin/python3")
        }
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )

        // A holder like the benchmark director: holder.lock for its lifetime; around a refresh,
        // flock on auth.json.lock, re-read, then temp file + fsync + os.replace. It exits on stdin EOF.
        let holder = Process()
        holder.executableURL = python
        holder.arguments = ["-I", "-c", """
        import fcntl, json, os, sys
        home = sys.argv[1]
        held = open(os.path.join(home, "holder.lock"), "a")
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open(os.path.join(home, "auth.json.lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = os.path.join(home, "auth.json")
            auth = json.load(open(path))
            auth["tokens"]["access_token"] = "access-k-3"
            auth["tokens"]["refresh_token"] = "refresh-k-3"
            tmp = path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(auth, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        print("rotated", flush=True)
        sys.stdin.read()
        """, home.path]
        let input = Pipe()
        let output = Pipe()
        holder.standardInput = input
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "rotated\n")

        let busy = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(busy.json["error"] as? String, "home_in_use", busy.text)
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-3")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])

        try input.fileHandleForWriting.close()
        holder.waitUntilExit()
        let swapped = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(swapped.exitCode, 0, swapped.text)
        XCTAssertEqual(swapped.json["return_sync"] as? String, "rotated")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-3")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-3")
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-b-1")
    }

    func testLeaseMarksTheHomeAndNamesTheAccountByHandleOnly() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let handle = CodexAccountHandle.handle(for: "profile-k")
        XCTAssertNotNil(handle.range(of: "^acct_[0-9a-f]{12}$", options: .regularExpression))

        let lease = fixture.run(["lease", "--profile-key", handle, "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.exitCode, 0, lease.text)
        XCTAssertEqual(lease.json["handle"] as? String, handle)
        XCTAssertEqual(lease.json["config_written"] as? Bool, true)
        XCTAssertFalse(lease.text.contains("profile-k"))

        let journal = try XCTUnwrap(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().first)
        XCTAssertEqual(journal.profileKey, "profile-k")
        XCTAssertEqual(journal.state, .active)
        XCTAssertTrue(journal.authWritten)
        XCTAssertEqual(lease.json["lease_id"] as? String, journal.leaseID)

        let marker = try XCTUnwrap(try CodexLeaseMarker.read(home: home.path))
        XCTAssertEqual(marker.leaseID, journal.leaseID)
        XCTAssertEqual(marker.consumer, "bench")
        let markerText = try String(contentsOf: CodexLeaseMarker.url(home: home.path), encoding: .utf8)
        for secret in ["profile-k", "k@example.invalid", "acct-k", "refresh-k"] {
            XCTAssertFalse(markerText.contains(secret), "\(secret) leaked into lease.json")
        }

        let config = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("cli_auth_credentials_store = \"file\""))
        XCTAssertTrue(config.contains("CODEX_HOME = \"/var/empty/"))

        let leases = fixture.run(["leases", "--json"])
        let listed = try XCTUnwrap((leases.json["leases"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["handle"] as? String, handle)
        XCTAssertEqual(listed["state"] as? String, "active")
        XCTAssertEqual(listed["holder_running"] as? Bool, false)
        XCTAssertFalse(leases.text.contains("profile-k"))

        let returned = fixture.run(["return", "--profile-key", handle, "--home", home.path, "--json"])
        XCTAssertEqual(returned.exitCode, 0, returned.text)
        XCTAssertEqual(returned.json["handle"] as? String, handle)
    }

    func testLeaseKeepsAnExistingConfigAndReleasesIntoATombstonedHome() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent("config.toml")
        try "model = \"owner-choice\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        let unsafe = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(unsafe.json["error"] as? String, "home_config_unsafe", unsafe.text)
        XCTAssertTrue(CodexFileProbe.isMissing(home.appendingPathComponent("auth.json")))

        let owned = """
        model = "owner-choice"
        cli_auth_credentials_store = "file"

        [shell_environment_policy]
        set = { CODEX_HOME = "/var/empty/owner-chosen" }

        """
        try owned.write(to: configURL, atomically: true, encoding: .utf8)
        let first = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(first.exitCode, 0, first.text)
        XCTAssertEqual(first.json["config_written"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), owned)
        XCTAssertEqual(fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"]).exitCode, 0)

        let second = fixture.run(["lease", "--profile-key", "profile-b", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(second.exitCode, 0, second.text)
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-b-1")
        XCTAssertNotEqual(second.json["lease_id"] as? String, first.json["lease_id"] as? String)
        XCTAssertEqual(try CodexLeaseMarker.read(home: home.path)?.leaseID, second.json["lease_id"] as? String)
    }

    func testABusyHolderLockRefusesLeaseReturnAndSwap() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let held = try fixture.holdLock(in: home, fileName: CodexLeaseHome.holderLockFileName)
        defer { fixture.releaseAuthLock(held) }
        let other = fixture.root.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherHeld = try fixture.holdLock(in: other, fileName: CodexLeaseHome.holderLockFileName)
        defer { fixture.releaseAuthLock(otherHeld) }

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(returned.json["error"] as? String, "home_in_use", returned.text)
        let swapped = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(swapped.json["error"] as? String, "home_in_use", swapped.text)
        let leased = fixture.run(["lease", "--profile-key", "profile-b", "--home", other.path, "--holder", "bench", "--json"])
        XCTAssertEqual(leased.json["error"] as? String, "home_in_use", leased.text)
        XCTAssertTrue(CodexFileProbe.isMissing(other.appendingPathComponent("auth.json")))
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])
    }

    func testReturnRefusesAMarkerFromAnotherLease() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let markerURL = CodexLeaseMarker.url(home: home.path)
        let original = try Data(contentsOf: markerURL)
        let foreign = try XCTUnwrap(String(data: original, encoding: .utf8))
            .replacingOccurrences(
                of: try XCTUnwrap(try CodexLeaseMarker.read(home: home.path)).leaseID,
                with: "lease-from-elsewhere"
            )
        try foreign.write(to: markerURL, atomically: true, encoding: .utf8)
        let mismatch = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(mismatch.json["error"] as? String, "lease_id_mismatch", mismatch.text)

        try "{not json".write(to: markerURL, atomically: true, encoding: .utf8)
        let unreadable = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(unreadable.json["error"] as? String, "lease_marker_unreadable", unreadable.text)

        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])
        try original.write(to: markerURL)
        XCTAssertEqual(fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"]).exitCode, 0)
    }

    func testReturnRefusesWhenTheLentAuthIsGone() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        try FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))

        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])

        XCTAssertEqual(returned.json["error"] as? String, "home_auth_missing", returned.text)
        let kept = try CodexLeaseStore(appSupportURL: fixture.appSupport).load()
        XCTAssertEqual(kept.map(\.profileKey), ["profile-k"])
        XCTAssertEqual(kept.first?.state, .returning)
        let status = fixture.run(["status", "--json"])
        XCTAssertEqual(fixture.account("profile-k", in: status.json)?["leasable"] as? Bool, false)

        // A store emptied of its tokens, for example by a holder that moved to a keychain store, is no better.
        try CodexAtomicFile.writeJSON(["auth_mode": "chatgpt", "tokens": [String: Any]()], to: home.appendingPathComponent("auth.json"))
        let emptied = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(emptied.json["error"] as? String, "home_auth_missing", emptied.text)
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().first?.state, .returning)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
    }

    func testReturnOfALeaseThatStoppedWhileLeasing() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let homeAuth = home.appendingPathComponent("auth.json")
        let store = CodexLeaseStore(appSupportURL: fixture.appSupport)
        func killedWhileLeasing() throws {
            try store.save(try store.load().map { lease in
                var lease = lease
                lease.state = .leasing
                lease.authWritten = false
                return lease
            })
        }

        // Killed after the journal entry, before auth.json: the chain was never lent.
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        try killedWhileLeasing()
        try FileManager.default.removeItem(at: homeAuth)
        XCTAssertEqual(fixture.run(["leases", "--json"]).json["leases"].flatMap { ($0 as? [[String: Any]])?.first?["state"] } as? String, "leasing")
        let status = fixture.run(["status", "--json"])
        XCTAssertEqual(fixture.account("profile-k", in: status.json)?["leased"] as? Bool, true)
        XCTAssertEqual(fixture.account("profile-k", in: status.json)?["leasable"] as? Bool, false)
        let nothingLent = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(nothingLent.exitCode, 0, nothingLent.text)
        XCTAssertEqual(nothingLent.json["sync"] as? String, "home_auth_missing")
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")

        // Killed after auth.json, before the flip to active: the home holds the chain, so return copies it.
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        try killedWhileLeasing()
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        let copied = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(copied.exitCode, 0, copied.text)
        XCTAssertEqual(copied.json["sync"] as? String, "rotated")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-2")
    }

    func testReturnAfterACrashMidReturnFinishesFromTheHome() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let homeAuth = home.appendingPathComponent("auth.json")
        let store = CodexLeaseStore(appSupportURL: fixture.appSupport)
        func markReturning() throws {
            try store.save(try store.load().map { lease in
                var lease = lease
                lease.state = .returning
                return lease
            })
        }

        // Killed after marking the lease returning, before the sync: the home still holds the chain.
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        try fixture.writeAuth(account: "k", generation: 2, to: homeAuth)
        try markReturning()
        XCTAssertEqual(fixture.run(["leases", "--json"]).json["leases"].flatMap { ($0 as? [[String: Any]])?.first?["state"] } as? String, "returning")
        let blocked = fixture.run(["lease", "--profile-key", "profile-k", "--home", fixture.root.appendingPathComponent("elsewhere").path, "--holder", "bench", "--json"])
        XCTAssertEqual(blocked.json["error"] as? String, "already_leased", blocked.text)
        let first = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(first.exitCode, 0, first.text)
        XCTAssertEqual(first.json["sync"] as? String, "rotated")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")

        // Killed after the tombstone, before the journal entry was removed.
        let again = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(again.exitCode, 0, again.text)
        try fixture.writeAuth(account: "k", generation: 3, to: homeAuth)
        try markReturning()
        _ = try CodexLeaseSync.syncHome(try XCTUnwrap(try store.load().first), appSupportURL: fixture.appSupport)
        try CodexLeaseTombstone.write(leaseID: try XCTUnwrap(again.json["lease_id"] as? String), to: homeAuth)
        let second = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(second.exitCode, 0, second.text)
        XCTAssertEqual(second.json["sync"] as? String, "home_returned")
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-3")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-3")
    }

    func testAStaleReservationMakesNothingLeasable() throws {
        try fixture.writeRegistry([
            ["purpose": "bench", "codex_home": "~/bench-home", "profile_key": "profile-renamed-since"],
        ])

        let status = fixture.run(["status", "--json"])
        let accounts = status.json["accounts"] as? [[String: Any]] ?? []
        XCTAssertFalse(accounts.isEmpty)
        XCTAssertFalse(accounts.contains { $0["leasable"] as? Bool == true })
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let lease = fixture.run(["lease", "--profile-key", "profile-b", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.json["error"] as? String, "reserved_registry_stale", lease.text)
        XCTAssertFalse(lease.text.contains("profile-renamed-since"))
        XCTAssertTrue(CodexFileProbe.isMissing(home.appendingPathComponent("auth.json")))
    }

    func testLeaseRefusesWhenTheStoredCopiesDisagree() throws {
        let accountsURL = fixture.appSupport.appendingPathComponent("accounts.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: accountsURL)) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        var entry = try XCTUnwrap(profiles["profile-b"] as? [String: Any])
        entry["refresh"] = "refresh-b-2"
        profiles["profile-b"] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(["lease", "--profile-key", "profile-b", "--home", home.path, "--holder", "bench", "--json"])

        XCTAssertEqual(lease.json["error"] as? String, "stored_copies_disagree", lease.text)
        XCTAssertTrue(CodexFileProbe.isMissing(home.appendingPathComponent("auth.json")))
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load(), [])
    }

    func testLeaseGivesUpOnAStoreLockHeldByAnotherProcess() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("needs /usr/bin/python3")
        }
        let holder = Process()
        holder.executableURL = python
        holder.arguments = ["-I", "-c", """
        import fcntl, os, sys
        lock = open(os.path.join(sys.argv[1], ".auth.lock"), "a")
        fcntl.lockf(lock, fcntl.LOCK_EX)
        print("locked", flush=True)
        sys.stdin.read()
        """, fixture.appSupport.path]
        let input = Pipe()
        let output = Pipe()
        holder.standardInput = input
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "locked\n")
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(
            ["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"],
            environment: ["CODEX_SWITCHBOARD_STORE_LOCK_TIMEOUT_SECONDS": "0.5"]
        )

        XCTAssertEqual(lease.json["error"] as? String, "auth_store_locked", lease.text)
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load(), [])
        try input.fileHandleForWriting.close()
        holder.waitUntilExit()
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
    }

    func testSwitchRefusesALaneHomeOrAReservedHomeAsItsDestination() throws {
        let lane = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true)
        try Data().write(to: lane.appendingPathComponent(CodexLeaseHome.holderLockFileName))
        try fixture.writeAuth(account: "a", generation: 1, to: lane.appendingPathComponent("auth.json"))
        let laneBefore = try Data(contentsOf: lane.appendingPathComponent("auth.json"))

        let intoLane = fixture.run(
            ["switch", "--profile-key", "profile-b", "--surface", "cli", "--json"],
            environment: ["CODEX_HOME": lane.path]
        )
        XCTAssertEqual(intoLane.json["error"] as? String, "surface_is_lane_home", intoLane.text)
        XCTAssertEqual(try Data(contentsOf: lane.appendingPathComponent("auth.json")), laneBefore)

        let reserved = fixture.home.appendingPathComponent("bench-home", isDirectory: true)
        try fixture.writeAuth(account: "a", generation: 1, to: reserved.appendingPathComponent("auth.json"))
        try fixture.writeRegistry([["purpose": "bench", "codex_home": "~/bench-home", "profile_key": "profile-f"]])
        let intoReserved = fixture.run(
            ["switch", "--profile-key", "profile-b", "--surface", "cli", "--json"],
            environment: ["CODEX_HOME": reserved.path]
        )
        XCTAssertEqual(intoReserved.json["error"] as? String, "surface_is_reserved_home", intoReserved.text)
        XCTAssertEqual(fixture.refreshToken(in: reserved.appendingPathComponent("auth.json")), "refresh-a-1")
    }

    func testAppRefusesToSignInOrRemoveALeasedAccount() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let root = fixture.appSupport

        XCTAssertThrowsError(try LeasedAccountGuard.rejectIfLeased(
            profileKeys: ["profile-k"], email: "k@example.invalid", accountID: "acct-k", storageRootURL: root
        )) { error in
            guard case LeasedAccountError.leased(holder: "bench") = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        // A new sign-in under another key for the same seat would drop the leased key as a duplicate.
        XCTAssertThrowsError(try LeasedAccountGuard.rejectIfLeased(
            profileKeys: ["profile-k-new"], email: "K@example.invalid", accountID: "acct-k", storageRootURL: root
        ))
        XCTAssertNoThrow(try LeasedAccountGuard.rejectIfLeased(
            profileKeys: ["profile-b"], email: "b@example.invalid", accountID: "acct-b", storageRootURL: root
        ))

        try Data("{not json".utf8).write(to: root.appendingPathComponent(CodexLeaseStore.fileName))
        XCTAssertThrowsError(try LeasedAccountGuard.rejectIfLeased(
            profileKeys: ["profile-b"], email: "b@example.invalid", accountID: "acct-b", storageRootURL: root
        )) { error in
            guard case LeasedAccountError.leaseStoreUnreadable = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testMirrorRetriesAHomeWhoseSyncFailed() {
        func result(_ reason: String?, _ status: CodexAuthMirrorResult.Status = .skipped) -> CodexAuthMirrorResult {
            CodexAuthMirrorResult(status: status, profileKey: "profile-k", reason: reason)
        }
        XCTAssertTrue(CodexAuthMirrorService.needsRetry([result("home_locked")]))
        XCTAssertTrue(CodexAuthMirrorService.needsRetry([result("home_auth_unreadable")]))
        XCTAssertTrue(CodexAuthMirrorService.needsRetry([result("The file could not be written.")]))
        XCTAssertFalse(CodexAuthMirrorService.needsRetry([result(nil, .synced)]))
        XCTAssertFalse(CodexAuthMirrorService.needsRetry([result("unchanged"), result("home_quarantined"), result("home_returned")]))
    }

    func testLeaseRefusesASeatListedUnderTwoKeys() throws {
        let accountsURL = fixture.appSupport.appendingPathComponent("accounts.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: accountsURL)) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        profiles["profile-k-again"] = profiles["profile-k"]
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])

        XCTAssertEqual(lease.json["error"] as? String, "duplicate_account_keys", lease.text)
        XCTAssertFalse(lease.text.contains("profile-k"))
        XCTAssertTrue(CodexFileProbe.isMissing(home.appendingPathComponent("auth.json")))
    }

    func testSwapChecksTheTargetLikeLeaseBeforeReturningAnything() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let homeAuth = home.appendingPathComponent("auth.json")
        let accountsURL = fixture.appSupport.appendingPathComponent("accounts.json")
        let accounts = try Data(contentsOf: accountsURL)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: accounts) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        var entry = try XCTUnwrap(profiles["profile-b"] as? [String: Any])
        entry["refresh"] = "refresh-b-2"
        profiles["profile-b"] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)

        let disagree = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--profile-key", "profile-b", "--json"])
        XCTAssertEqual(disagree.json["error"] as? String, "stored_copies_disagree", disagree.text)
        try accounts.write(to: accountsURL)

        let registryURL = fixture.home.appendingPathComponent(".config/codex-logins/registry.json")
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: registryURL)
        let registry = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(registry.json["error"] as? String, "reserved_registry_unreadable", registry.text)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(".config/codex-logins/registry.json"))

        try "model = \"owner-choice\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let config = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(config.json["error"] as? String, "home_config_unsafe", config.text)

        XCTAssertEqual(fixture.refreshToken(in: homeAuth), "refresh-k-1")
        XCTAssertEqual(try CodexLeaseStore(appSupportURL: fixture.appSupport).load().map(\.profileKey), ["profile-k"])
    }

    func testSwitchRefusesEveryKeyOfALeasedOrReservedSeat() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let liveAuth = fixture.home.appendingPathComponent(".codex/auth.json")
        let before = try Data(contentsOf: liveAuth)

        // A later sign-in lists the leased seat under a second key.
        try fixture.addKey("profile-k2", sameSeatAs: "profile-k")
        let leased = fixture.run(["switch", "--profile-key", "profile-k2", "--surface", "cli", "--json"])
        XCTAssertEqual(leased.json["error"] as? String, "account_leased", leased.text)

        try fixture.writeRegistry([["purpose": "bench", "profile_key": "profile-b", "codex_home": "~/bench-home"]])
        try fixture.addKey("profile-b2", sameSeatAs: "profile-b")
        for key in ["profile-b", "profile-b2"] {
            let reserved = fixture.run(["switch", "--profile-key", key, "--surface", "cli", "--json"])
            XCTAssertEqual(reserved.json["error"] as? String, "reserved_account", "\(key): \(reserved.text)")
            XCTAssertFalse(reserved.text.contains("example.invalid"), reserved.text)
        }

        // A reservation whose key Switchboard no longer lists could be any seat, so no switch goes ahead.
        try fixture.writeRegistry([["purpose": "bench", "profile_key": "profile-gone", "codex_home": "~/bench-home"]])
        let stale = fixture.run(["switch", "--profile-key", "profile-b", "--surface", "cli", "--json"])
        XCTAssertEqual(stale.json["error"] as? String, "reserved_registry_stale", stale.text)

        // An unreadable registry stops a switch into ~/.codex as well.
        try Data("{not json".utf8).write(to: fixture.home.appendingPathComponent(".config/codex-logins/registry.json"))
        let unreadable = fixture.run(["switch", "--profile-key", "profile-b", "--surface", "cli", "--json"])
        XCTAssertEqual(unreadable.json["error"] as? String, "reserved_registry_unreadable", unreadable.text)

        XCTAssertEqual(try Data(contentsOf: liveAuth), before)
    }

    func testATornLiveAuthMakesNothingLeasable() throws {
        // Codex rewrites ~/.codex/auth.json in place; mid-write it names no account, and that could be any one.
        let liveAuth = fixture.home.appendingPathComponent(".codex/auth.json")
        let before = try Data(contentsOf: liveAuth)
        try Data("{\"tokens\": {\"id_tok".utf8).write(to: liveAuth)
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)

        let lease = fixture.run(["lease", "--profile-key", "profile-a", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.json["error"] as? String, "surface_identity_unknown", lease.text)
        let status = fixture.run(["status", "--json", "--leasable-only"])
        XCTAssertEqual((status.json["accounts"] as? [[String: Any]])?.count, 0, status.text)

        try before.write(to: liveAuth)
        XCTAssertEqual(fixture.run(["lease", "--profile-key", "profile-a", "--home", home.path, "--holder", "bench", "--json"])
            .json["error"] as? String, "active_account")
    }

    func testAKeychainSurfaceMakesNothingLeasable() throws {
        // A CLI that keeps its sign-in in a keychain could be on any account, so status lists none as leasable.
        try "cli_auth_credentials_store = \"keychain\"\n"
            .write(to: fixture.home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let status = fixture.run(["status", "--json", "--leasable-only"])
        XCTAssertEqual((status.json["accounts"] as? [[String: Any]])?.count, 0, status.text)
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let lease = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.json["error"] as? String, "surface_identity_unknown", lease.text)
    }

    func testLeaseSeesAChainASwitchWroteIntoAnotherCodexHome() throws {
        // A switch run with CODEX_HOME=other records that home, then writes profile-b's chain there. A real switch
        // refuses consumers_running while any Codex app runs on the test machine, so the test does both steps.
        let other = fixture.root.appendingPathComponent("other-codex-home", isDirectory: true)
        let defaultHome = fixture.home.appendingPathComponent(".codex").path
        try CodexSwitchHomes.record(other.path, appSupportURL: fixture.appSupport, defaultHome: defaultHome)
        try CodexSwitchHomes.record(other.path, appSupportURL: fixture.appSupport, defaultHome: defaultHome)
        try CodexSwitchHomes.record(defaultHome, appSupportURL: fixture.appSupport, defaultHome: defaultHome)
        XCTAssertEqual(CodexSwitchHomes.load(appSupportURL: fixture.appSupport)?.count, 1)
        try fixture.writeAuth(account: "b", generation: 1, to: other.appendingPathComponent("auth.json"))

        // Later, from a shell without CODEX_HOME, profile-b looks idle unless the switch was recorded.
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        let lease = fixture.run(["lease", "--profile-key", "profile-b", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.json["error"] as? String, "active_account", lease.text)
        let status = fixture.run(["status", "--json"])
        XCTAssertEqual(fixture.account("profile-b", in: status.json)?["leasable"] as? Bool, false)

        // A record that cannot be read is never overwritten, and leases wait until it is fixed.
        let record = fixture.appSupport.appendingPathComponent(CodexSwitchHomes.fileName)
        try Data("{not json".utf8).write(to: record)
        XCTAssertThrowsError(try CodexSwitchHomes.record(
            fixture.root.appendingPathComponent("third-home").path, appSupportURL: fixture.appSupport, defaultHome: defaultHome
        ))
        XCTAssertEqual(try Data(contentsOf: record), Data("{not json".utf8))
        XCTAssertEqual(fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
            .json["error"] as? String, "surface_identity_unknown")
        let blocked = fixture.run(["status", "--json"])
        XCTAssertEqual(fixture.account("profile-k", in: blocked.json)?["leasable"] as? Bool, false)
    }

    func testSwitchIntoAnotherHomeNeedsAReadableRegistry() throws {
        let other = fixture.root.appendingPathComponent("other-codex-home", isDirectory: true)
        try fixture.writeAuth(account: "a", generation: 1, to: other.appendingPathComponent("auth.json"))
        let registryURL = fixture.home.appendingPathComponent(".config/codex-logins/registry.json")
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: registryURL)

        let switched = fixture.run(
            ["switch", "--profile-key", "profile-b", "--surface", "cli", "--json"],
            environment: ["CODEX_HOME": other.path]
        )

        XCTAssertEqual(switched.json["error"] as? String, "reserved_registry_unreadable", switched.text)
        XCTAssertEqual(fixture.refreshToken(in: other.appendingPathComponent("auth.json")), "refresh-a-1")
    }

    func testRefusalsNeverEchoAKeyThatOnlyLooksLikeAHandle() {
        let given = "acct_k@example.invalid"
        let returned = fixture.run(["return", "--profile-key", given, "--home", fixture.root.appendingPathComponent("x").path, "--json"])
        XCTAssertEqual(returned.exitCode, 2, returned.text)
        XCTAssertFalse(returned.text.contains("example.invalid"))
        let swapped = fixture.run([
            "swap-lease", "--home", fixture.root.path, "--holder", "bench",
            "--profile-key", given, "--exclude-profile-key", given, "--json",
        ])
        XCTAssertEqual(swapped.exitCode, 64, swapped.text)
        XCTAssertFalse(swapped.text.contains("example.invalid"), swapped.text)
    }

    func testLiveAuthMirrorNeverImportsAnOlderLinkOfTheChain() throws {
        // The app stored generation 2 but could not pass it on: live auth still holds generation 1.
        try fixture.writeAuth(account: "a", generation: 2, to: fixture.profileAuthURL("a"))
        let liveAuth = fixture.home.appendingPathComponent(".codex/auth.json")
        let mirror = CodexAuthMirrorService(
            authURL: liveAuth,
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        )

        let older = mirror.syncActiveAuth()
        XCTAssertEqual(older.reason, "live auth is older than the stored copy")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("a")), "refresh-a-2")

        try fixture.writeAuth(account: "a", generation: 3, to: liveAuth)
        XCTAssertEqual(mirror.syncActiveAuth().status, .synced)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("a")), "refresh-a-3")

        // The app stored generation 4 in the account list only: live auth and the captured copy both
        // still hold generation 3, and neither may overwrite the list.
        let accountsURL = fixture.appSupport.appendingPathComponent("accounts.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: accountsURL)) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        var entry = try XCTUnwrap(profiles["profile-a"] as? [String: Any])
        entry["refresh"] = "refresh-a-4"
        entry["expires"] = (1_800_000_000 + 4) * 1000
        profiles["profile-a"] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        XCTAssertEqual(mirror.syncActiveAuth().reason, "live auth is older than the stored copy")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-a"), "refresh-a-4")

        // A list entry whose expiry is unknown cannot be ordered, so live auth is not taken over it.
        entry.removeValue(forKey: "expires")
        profiles["profile-a"] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        XCTAssertEqual(mirror.syncActiveAuth().reason, "live auth cannot be ordered against the stored copy")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-a"), "refresh-a-4")

        // The entry's own access token gives its expiry, measured the same way as live auth's.
        entry["access"] = LeaseFixture.jwt(["exp": 1_800_000_000 + 5])
        profiles["profile-a"] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        XCTAssertEqual(mirror.syncActiveAuth().reason, "live auth is older than the stored copy")
        try fixture.writeAuth(account: "a", generation: 6, to: liveAuth)
        XCTAssertEqual(mirror.syncActiveAuth().status, .synced)
        XCTAssertEqual(fixture.accountListRefreshToken("profile-a"), "refresh-a-6")
    }

    func testMirrorRetriesAHomeOnceItsQuarantineClears() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        let mirror = CodexAuthMirrorService(
            authURL: fixture.home.appendingPathComponent(".codex/auth.json"),
            profileStoreURL: fixture.appSupport.appendingPathComponent("profiles"),
            storageRootURL: fixture.appSupport,
            interval: 30
        )
        mirror.syncLeasedHomesIfChanged()

        // The holder writes its rotation while its refresh sentinel still exists.
        let sentinel = CodexLeaseHome.stoppedSentinelURL(home: home.path)
        try "refresh_in_flight\n".write(to: sentinel, atomically: true, encoding: .utf8)
        try fixture.writeAuth(account: "k", generation: 2, to: home.appendingPathComponent("auth.json"))
        mirror.syncLeasedHomesIfChanged()
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")

        try FileManager.default.removeItem(at: sentinel)
        mirror.syncLeasedHomesIfChanged()
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
    }

    func testAHomeThatCannotBeSearchedIsNeverReturnedUnlocked() throws {
        let parent = fixture.root.appendingPathComponent("closed", isDirectory: true)
        let home = parent.appendingPathComponent("lane-home", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )
        try fixture.writeAuth(account: "k", generation: 2, to: home.appendingPathComponent("auth.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }

        let refused = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertNotEqual(refused.exitCode, 0, refused.text)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-1")
        let listed = fixture.run(["leases", "--json"])
        XCTAssertEqual((listed.json["leases"] as? [[String: Any]])?.count, 1, "the lease is still held")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        let returned = fixture.run(["return", "--profile-key", "profile-k", "--home", home.path, "--json"])
        XCTAssertEqual(returned.exitCode, 0, returned.text)
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-2")
    }

    func testLeaseChecksTheNestedCodexHomeValue() throws {
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent("config.toml")
        for unsafe in [
            "set = { CODEX_HOME_OTHER = \"/var/empty/x\" }",
            "set = { CODEX_HOME = \"\(home.path)\" }",
            "set = { CODEX_HOME = \"\(fixture.root.path)\" }",
            // TOML decodes this to a different path than the one written.
            "set = { CODEX_HOME = \"/var/empty/\\u006eested\" }",
        ] {
            try "cli_auth_credentials_store = \"file\"\n\n[shell_environment_policy]\n\(unsafe)\n"
                .write(to: configURL, atomically: true, encoding: .utf8)
            let lease = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
            XCTAssertEqual(lease.json["error"] as? String, "home_config_unsafe", unsafe)
        }
        try "cli_auth_credentials_store = \"file\"\n\n[shell_environment_policy.set]\nCODEX_HOME = \"/var/empty/nested\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        let lease = fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(lease.exitCode, 0, lease.text)
    }

    func testCLIRefusesAnUnusableStorageNamespace() {
        // Without an app-support override the namespace names the storage folder. An unusable one must
        // not fall back to the default storage, so the command stops before reading anything.
        for unusable in ["a/b", "", "  "] {
            let output = CodexSwitchboardCommand.execute(
                arguments: ["status", "--json"],
                environment: ["CODEX_SWITCHBOARD_STORAGE_NAMESPACE": unusable, "PATH": "/usr/bin:/bin"],
                homeURL: fixture.home
            )
            let text = output.stdout ?? output.stderr ?? ""
            XCTAssertNotEqual(output.exitCode, 0, "\"\(unusable)\"")
            XCTAssertTrue(text.contains("storage_namespace_invalid"), text)
        }
    }

    func testHelpListsLeaseCommands() {
        let help = fixture.run(["--help"])
        XCTAssertTrue(help.text.contains("lease --profile-key <key> --home <dir> --holder <name> --json"))
        XCTAssertTrue(help.text.contains("return --profile-key <key> --home <dir> --json"))
        XCTAssertTrue(help.text.contains("leases --json"))
        XCTAssertTrue(help.text.contains("swap-lease --home <dir> --holder <name> [--profile-key <key>]"))
    }
}

/// A fake machine: a home whose `.codex` is signed in to account A, Switchboard storage holding
/// accounts A, K and B (paid) and F (free), and a fake `codex` on PATH so the CLI surface is detected.
private struct LeaseFixture {
    let root: URL
    let home: URL
    let appSupport: URL
    let bin: URL

    init(testCase: XCTestCase) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchboard-lease-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        let root = root
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        for directory in [home, appSupport, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        var accountList: [String: Any] = [:]
        for account in ["a", "k", "b", "f"] {
            let profile = appSupport.appendingPathComponent("profiles/\(account)", isDirectory: true)
            try writeAuth(account: account, generation: 1, to: profile.appendingPathComponent("auth.json"))
            try CodexAtomicFile.writeJSON(
                [
                    "source_profile_key": "profile-\(account)",
                    "email": "\(account)@example.invalid",
                    "account_id": "acct-\(account)",
                ],
                to: profile.appendingPathComponent("meta.json")
            )
            accountList["profile-\(account)"] = [
                "access": "access-\(account)-1",
                "refresh": "refresh-\(account)-1",
                "expires": (1_800_000_000 + 1) * 1000,
                "email": "\(account)@example.invalid",
                "accountId": "acct-\(account)",
            ]
        }
        try CodexAtomicFile.writeJSON(
            ["version": 1, "profiles": accountList, "order": ["default": ["profile-a", "profile-k", "profile-b", "profile-f"]]],
            to: appSupport.appendingPathComponent("accounts.json")
        )
        func snapshot(_ account: String, plan: String, session: Double, weekly: Double) -> [String: Any] {
            [
                "profileKey": "profile-\(account)",
                "email": "\(account)@example.invalid",
                "workspace": "Personal",
                "plan": plan,
                "sessionFree": session,
                "weeklyFree": weekly,
                "sessionResetSeconds": 3_600,
                "weeklyResetSeconds": 86_400,
                "hasError": false,
            ]
        }
        try CodexAtomicFile.writeJSON(
            [
                "lastRefreshEpoch": Date().timeIntervalSince1970,
                "accounts": [
                    snapshot("a", plan: "pro", session: 2, weekly: 50),
                    snapshot("k", plan: "pro", session: 95, weekly: 95),
                    snapshot("b", plan: "plus", session: 70, weekly: 70),
                    snapshot("f", plan: "free", session: 100, weekly: 100),
                ],
            ],
            to: appSupport.appendingPathComponent("accounts-snapshot.json")
        )

        let liveAuth = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: liveAuth.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: profileAuthURL("a"), to: liveAuth)
    }

    func run(
        _ arguments: [String],
        environment extra: [String: String] = [:]
    ) -> (exitCode: Int32, text: String, json: [String: Any]) {
        let output = CodexSwitchboardCommand.execute(
            arguments: arguments,
            environment: [
                "CODEX_SWITCHBOARD_APP_SUPPORT": appSupport.path,
                "PATH": "\(bin.path):/usr/bin:/bin",
            ].merging(extra) { _, new in new },
            homeURL: home
        )
        let text = output.stdout ?? output.stderr ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (output.exitCode, text, json)
    }

    func account(_ profileKey: String, in status: [String: Any]) -> [String: Any]? {
        (status["accounts"] as? [[String: Any]])?.first { $0["profile_key"] as? String == profileKey }
    }

    func candidate(in output: (exitCode: Int32, text: String, json: [String: Any])) -> String? {
        let decisions = output.json["decisions"] as? [[String: Any]]
        return decisions?.first?["candidate_profile_key"] as? String
    }

    func profileAuthURL(_ account: String) -> URL {
        appSupport.appendingPathComponent("profiles/\(account)/auth.json")
    }

    func writeAuth(account: String, generation: Int, to url: URL) throws {
        let claims: [String: Any] = [
            "sub": "sub-\(account)",
            "email": "\(account)@example.invalid",
            "exp": 1_800_000_000 + generation,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(account)"],
        ]
        try CodexAtomicFile.writeJSON(
            [
                "auth_mode": "chatgpt",
                "last_refresh": "2026-10-26T00:00:0\(generation % 10)Z",
                "tokens": [
                    "id_token": Self.jwt(claims),
                    "access_token": "access-\(account)-\(generation)",
                    "refresh_token": "refresh-\(account)-\(generation)",
                    "account_id": "acct-\(account)",
                ],
            ],
            to: url
        )
    }

    func refreshToken(in url: URL) -> String? {
        let auth = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        return (auth?["tokens"] as? [String: Any])?["refresh_token"] as? String
    }

    func accountListRefreshToken(_ profileKey: String) -> String? {
        let data = try? Data(contentsOf: appSupport.appendingPathComponent("accounts.json"))
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return ((root?["profiles"] as? [String: Any])?[profileKey] as? [String: Any])?["refresh"] as? String
    }

    func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Lists `existing`'s seat (same email and account id) under one more key in the account list.
    func addKey(_ key: String, sameSeatAs existing: String) throws {
        let accountsURL = appSupport.appendingPathComponent("accounts.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: accountsURL)) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        profiles[key] = profiles[existing]
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
    }

    func writeRegistry(_ logins: [[String: Any]]) throws {
        try CodexAtomicFile.writeJSON(
            ["version": 1, "logins": logins],
            to: home.appendingPathComponent(".config/codex-logins/registry.json")
        )
    }

    /// Holds `flock(LOCK_EX)` on the home's `auth.json.lock` on a descriptor of its own, the way a
    /// holder process does while it refreshes.
    func holdAuthLock(in home: URL) throws -> Int32 {
        let descriptor = open(home.appendingPathComponent("auth.json.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(.EBUSY)
        }
        return descriptor
    }

    /// The same, on any lock file in the home, such as `holder.lock`.
    func holdLock(in home: URL, fileName: String) throws -> Int32 {
        let descriptor = open(home.appendingPathComponent(fileName).path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(.EBUSY)
        }
        return descriptor
    }

    func releaseAuthLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// A shell script named `codex` that, like Codex, keeps a SQLite state file open in its home.
    func startFakeCodex(codexHome: URL) throws -> Process {
        let script = root.appendingPathComponent("consumer/codex")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "exec 3>>\"$CODEX_HOME/state_5.sqlite\"\nsleep 30\ntrue\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["CODEX_HOME": codexHome.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
        return process
    }

    static func jwt(_ claims: [String: Any]) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "none"])).\(encode(claims)).sig"
    }
}
