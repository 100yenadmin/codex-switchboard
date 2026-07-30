import XCTest
@testable import CodexSwitchboard

final class AccountListVisibilityTests: XCTestCase {
    @MainActor
    func testErroredAccountsStayVisible() {
        let healthy = makeAccount(id: "ok@example.com|acc-ok", email: "ok@example.com", hasError: false)
        let errored = makeAccount(id: "bad@example.com|acc-bad", email: "bad@example.com", hasError: true)

        let visible = UsageViewModel.visibleAccounts(from: [healthy, errored])

        XCTAssertEqual(visible.map(\.id), [healthy.id, errored.id])
        XCTAssertEqual(UsageViewModel.errorCount(in: visible), 1)
    }

    func testDedupIDFallsBackToProfileKeyWhenAccountIDIsMissing() {
        let first = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:team:same@example.com"
        )
        let second = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:plus:same@example.com"
        )

        XCTAssertNotEqual(first, second)
    }

    func testExpiredOrRevokedAuthError() {
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Expired or revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token invalidated"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Refresh failed - re-login required"))
        XCTAssertFalse(UsageService.isExpiredOrRevokedAuthError("Workspace deactivated"))
    }

    func testRecoverableAuthErrorIsNotARowSwitchAffordance() {
        XCTAssertTrue(UsageService.isRecoverableAuthError("Token expired"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token revoked"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token invalidated"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("HTTP 403"))
    }

    func testWeeklyOnlyQuotaDoesNotInventFiveHourWindow() {
        let windows = UsageService.quotaWindows(from: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0.0,
                    "reset_after_seconds": 500_000.0,
                    "limit_window_seconds": 604_800.0,
                ],
            ],
        ])

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertEqual(windows.first?.freePercent, 100)
    }

    func testMonthlyOnlyQuotaDoesNotInventFiveHourOrWeeklyWindow() {
        let windows = UsageService.quotaWindows(from: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 12.0,
                    "reset_after_seconds": 2_000_000.0,
                    "limit_window_seconds": 2_592_000.0,
                ],
            ],
        ])

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.kind, .monthly)
        XCTAssertEqual(windows.first?.shortLabel, "M")
        XCTAssertEqual(windows.first?.displayLabel, "Monthly")
        XCTAssertEqual(windows.first?.freePercent, 88)
    }

    func testFiveHourAndWeeklyWindowsAreClassifiedByDurationNotPosition() {
        let windows = UsageService.quotaWindows(from: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 25.0,
                    "reset_after_seconds": 1_000.0,
                    "limit_window_seconds": 604_800.0,
                ],
                "secondary_window": [
                    "used_percent": 10.0,
                    "reset_after_seconds": 2_000.0,
                    "limit_window_seconds": 18_000.0,
                ],
            ],
        ])

        XCTAssertEqual(windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(windows.map(\.freePercent), [90, 75])
    }

    func testMissingQuotaWindowIsNotReportedAsFull() {
        let windows = UsageService.quotaWindows(from: [
            "rate_limit": [
                "primary_window": [
                    "reset_after_seconds": 1_000.0,
                    "limit_window_seconds": 18_000.0,
                ],
            ],
        ])

        XCTAssertTrue(windows.isEmpty)
    }

    func testWeeklyOnlyAccountIsUsableWithoutFiveHourQuota() {
        let weekly = QuotaWindow(
            kind: .weekly,
            usedPercent: 20,
            resetSeconds: 500_000,
            durationSeconds: 604_800
        )
        let account = Account(
            id: "weekly@example.com|acc-weekly",
            profileKey: "weekly@example.com",
            email: "weekly@example.com",
            workspace: "pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 500_000,
            quotaWindows: [weekly],
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isUsableForCodex)
        XCTAssertNil(account.leadingQuotaWindow)
        XCTAssertEqual(account.weeklyQuotaWindow, weekly)
        XCTAssertEqual(account.quotaScore, 80)
    }

    func testLegacySnapshotWithoutQuotaWindowsStillDecodes() throws {
        let data = Data("""
        {
          "id": "legacy@example.com|acc",
          "profileKey": "legacy@example.com",
          "email": "legacy@example.com",
          "workspace": "pro",
          "plan": "pro",
          "sessionFree": 80,
          "weeklyFree": 90,
          "sessionResetSeconds": 1000,
          "weeklyResetSeconds": 2000,
          "hasError": false
        }
        """.utf8)

        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertNil(account.quotaWindows)
        XCTAssertEqual(account.effectiveQuotaWindows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertTrue(account.isUsableForCodex)
    }

    func testFreePlanSessionZeroUsesDedicatedResetState() {
        let account = Account(
            id: "free@example.com|acc-free",
            profileKey: "free@example.com",
            email: "free@example.com",
            workspace: "free",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 86_400,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isFreeWaitingForReset)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertEqual(account.freePlanResetSeconds, 86_400)
    }

    func testFreeResetFormatterIncludesReturnContext() {
        let text = ResetFormatter.formatFreeReturn(seconds: 60)

        XCTAssertNotEqual(text, ResetFormatter.timeOnly(seconds: 60))
        XCTAssertTrue(text.contains(" "))
    }

    @MainActor
    func testWaitingForResetSortsPaidBeforeFreeThenSoonestReset() {
        let freeSoon = makeAccount(
            id: "free-soon@example.com|acc",
            email: "free-soon@example.com",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 60
        )
        let plusLater = makeAccount(
            id: "plus-later@example.com|acc",
            email: "plus-later@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 600
        )
        let plusSoon = makeAccount(
            id: "plus-soon@example.com|acc",
            email: "plus-soon@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 120
        )

        let sorted = UsageViewModel.sortedExhaustedAccounts([freeSoon, plusLater, plusSoon])

        XCTAssertEqual(sorted.map(\.email), [
            "plus-soon@example.com",
            "plus-later@example.com",
            "free-soon@example.com"
        ])
    }

    private func makeAccount(id: String, email: String, hasError: Bool) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: hasError ? "?" : "team",
            plan: hasError ? "?" : "team",
            sessionFree: hasError ? 0 : 80,
            weeklyFree: hasError ? 0 : 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: hasError,
            errorMessage: hasError ? "Codex usage unavailable" : nil
        )
    }

    private func makeAccount(
        id: String,
        email: String,
        plan: String,
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double = 0
    ) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: plan,
            plan: plan,
            sessionFree: sessionFree,
            weeklyFree: weeklyFree,
            sessionResetSeconds: sessionResetSeconds,
            weeklyResetSeconds: weeklyResetSeconds,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )
    }
}
