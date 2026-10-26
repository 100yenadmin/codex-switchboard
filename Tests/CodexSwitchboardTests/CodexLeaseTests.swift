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
        XCTAssertEqual(returned.json["home_auth_removed"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeAuth.path))
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
        XCTAssertFalse(reservations.isReserved(profileKey: "profile-k", runningAppPIDs: [4242]))
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
        XCTAssertEqual(leasable(fixture.run(["status", "--json", "--leasable-only"])), ["profile-b": true])

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
        XCTAssertEqual(swapped.json["returned_profile_key"] as? String, "profile-k")
        XCTAssertEqual(swapped.json["return_sync"] as? String, "rotated")
        XCTAssertEqual(swapped.json["leased_profile_key"] as? String, "profile-b")
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
        let refreshing = fixture.run(["swap-lease", "--home", home.path, "--holder", "bench", "--json"])
        XCTAssertEqual(refreshing.json["error"] as? String, "refresh_in_progress")
        try CodexRefreshReservations(appSupportURL: fixture.appSupport).release(profileKey: "profile-b")

        let malformed = fixture.run(["swap-lease", "--home", home.path, "--exclude-profile-key", "--holder", "bench", "--json"])
        XCTAssertEqual(malformed.exitCode, 64)

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

    func testSwapWaitsForAPythonHolderMidRefreshAndKeepsItsRotation() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("needs /usr/bin/python3")
        }
        let home = fixture.root.appendingPathComponent("lane-home", isDirectory: true)
        XCTAssertEqual(
            fixture.run(["lease", "--profile-key", "profile-k", "--home", home.path, "--holder", "bench", "--json"]).exitCode,
            0
        )

        // A holder like the benchmark director: flock, re-read, refresh, then temp file + fsync + os.replace.
        let holder = Process()
        holder.executableURL = python
        holder.arguments = ["-I", "-c", """
        import fcntl, json, os, sys, time
        home = sys.argv[1]
        lock = open(os.path.join(home, "auth.json.lock"), "a")
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("locked", flush=True)
        time.sleep(1.0)
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
        """, home.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "locked\n")

        let swapped = fixture.run(
            ["swap-lease", "--home", home.path, "--holder", "bench", "--json"],
            environment: ["CODEX_SWITCHBOARD_HOME_LOCK_TIMEOUT_SECONDS": "10"]
        )

        holder.waitUntilExit()
        XCTAssertEqual(swapped.exitCode, 0, swapped.text)
        XCTAssertEqual(swapped.json["return_sync"] as? String, "rotated")
        XCTAssertEqual(fixture.refreshToken(in: fixture.profileAuthURL("k")), "refresh-k-3")
        XCTAssertEqual(fixture.accountListRefreshToken("profile-k"), "refresh-k-3")
        XCTAssertEqual(fixture.refreshToken(in: home.appendingPathComponent("auth.json")), "refresh-b-1")
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

    private static func jwt(_ claims: [String: Any]) -> String {
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
