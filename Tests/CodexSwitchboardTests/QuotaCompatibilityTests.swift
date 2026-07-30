import XCTest
@testable import CodexSwitchboard
@testable import CodexSwitchboardCore

final class QuotaCompatibilityTests: XCTestCase {
    func testWeeklyOnlyWindowFeedsBothLegacyAutoSwapThresholds() throws {
        let account = makeAccount(windows: [
            QuotaWindow(
                kind: .weekly,
                usedPercent: 25,
                resetSeconds: 10,
                durationSeconds: 604_800
            ),
        ])

        let adapted = try XCTUnwrap(account.autoSwapAccount(needsRelogin: false))

        XCTAssertEqual(adapted.sessionFreePercent, 75)
        XCTAssertEqual(adapted.weeklyFreePercent, 75)
    }

    func testMonthlyOnlyWindowFeedsBothLegacyAutoSwapThresholds() throws {
        let account = makeAccount(windows: [
            QuotaWindow(
                kind: .monthly,
                usedPercent: 40,
                resetSeconds: 20,
                durationSeconds: 2_592_000
            ),
        ])

        let adapted = try XCTUnwrap(account.autoSwapAccount(needsRelogin: false))

        XCTAssertEqual(adapted.sessionFreePercent, 60)
        XCTAssertEqual(adapted.weeklyFreePercent, 60)
    }

    func testShortAndWeeklyWindowsKeepSeparateAutoSwapThresholds() throws {
        let account = makeAccount(windows: [
            QuotaWindow(
                kind: .fiveHour,
                usedPercent: 10,
                resetSeconds: 5,
                durationSeconds: 18_000
            ),
            QuotaWindow(
                kind: .weekly,
                usedPercent: 30,
                resetSeconds: 10,
                durationSeconds: 604_800
            ),
        ])

        let adapted = try XCTUnwrap(account.autoSwapAccount(needsRelogin: false))

        XCTAssertEqual(adapted.sessionFreePercent, 90)
        XCTAssertEqual(adapted.weeklyFreePercent, 70)
    }

    func testCLIPresentEmptyWindowsScoreZeroInsteadOfUsingLegacyFallback() {
        let values = SnapshotQuotaCompatibility.values(
            windows: [],
            legacySessionFree: 100,
            legacyWeeklyFree: 100
        )

        XCTAssertEqual(values.sessionFree, 100)
        XCTAssertEqual(values.weeklyFree, 100)
        XCTAssertEqual(values.score, 0)
    }

    func testCLIWeeklyOnlyWindowFeedsBothLegacyThresholds() {
        let values = SnapshotQuotaCompatibility.values(
            windows: [("weekly", 82)],
            legacySessionFree: 0,
            legacyWeeklyFree: 0
        )

        XCTAssertEqual(values.sessionFree, 82)
        XCTAssertEqual(values.weeklyFree, 82)
        XCTAssertEqual(values.score, 82)
    }

    private func makeAccount(windows: [QuotaWindow]) -> Account {
        Account(
            id: "person@example.com|acc-1",
            profileKey: "profile-1",
            email: "person@example.com",
            workspace: "Pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 100,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            quotaWindows: windows,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )
    }
}
