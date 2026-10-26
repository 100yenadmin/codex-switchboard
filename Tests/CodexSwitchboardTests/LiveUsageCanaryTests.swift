import XCTest
@testable import CodexSwitchboard

final class LiveUsageCanaryTests: XCTestCase {
    func testFirstOrderedProfileLoadsOnLiveService() async throws {
        guard ProcessInfo.processInfo.environment[
            "RUN_LIVE_USAGE_REFRESH_CANARY"
        ] == "1" else {
            throw XCTSkip("Set RUN_LIVE_USAGE_REFRESH_CANARY=1 for the state-changing live canary.")
        }

        let collection = AccountProfileStore.load()
        let profileKey = try XCTUnwrap(collection.orderedKeys.first)
        let profile = try XCTUnwrap(collection.profiles[profileKey])
        let previousAccessToken = try XCTUnwrap(profile["access"] as? String)

        let service = UsageService(profileLoader: {
            AccountProfileCollection(
                profiles: [profileKey: profile],
                orderedKeys: [profileKey]
            )
        })
        let accounts = await service.loadAll()

        let account = try XCTUnwrap(accounts.first)
        XCTAssertFalse(
            account.hasError,
            "Live canary failed: \(account.errorMessage ?? "unknown usage error")"
        )
        XCTAssertFalse(account.effectiveQuotaWindows.isEmpty)

        let persisted = AccountProfileStore.load().profiles[profileKey]
        let nextAccessToken = try XCTUnwrap(persisted?["access"] as? String)
        if ProcessInfo.processInfo.environment[
            "EXPECT_LIVE_USAGE_TOKEN_REFRESH"
        ] == "1" {
            XCTAssertNotEqual(
                nextAccessToken,
                previousAccessToken,
                "The selected profile did not exercise token refresh."
            )
        }
        XCTAssertFalse((persisted?["refresh"] as? String ?? "").isEmpty)
    }
}
