import XCTest
@testable import CodexSwitchboard

final class AuthRefreshGuardTests: XCTestCase {
    func testExpiredAccessTokenAndBare401AreRefreshable() {
        XCTAssertTrue(UsageService.shouldAttemptTokenRefresh([
            "detail": ["code": "token_expired"],
            "http_status": 401,
        ]))
        XCTAssertTrue(UsageService.shouldAttemptTokenRefresh([
            "http_status": 401,
        ]))
    }

    func testInvalidatedOrRevokedTokensRequireReloginWithoutRefresh() {
        XCTAssertFalse(UsageService.shouldAttemptTokenRefresh([
            "detail": ["code": "token_invalidated"],
            "http_status": 401,
        ]))
        XCTAssertFalse(UsageService.shouldAttemptTokenRefresh([
            "error": ["code": "token_revoked"],
            "http_status": 401,
        ]))
        XCTAssertFalse(UsageService.shouldAttemptTokenRefresh([
            "detail": ["code": "refresh_token_reused"],
            "http_status": 401,
        ]))
    }

    func testNonAuthFailuresDoNotSpendRefreshGrant() {
        XCTAssertFalse(UsageService.shouldAttemptTokenRefresh([
            "http_status": 403,
        ]))
        XCTAssertFalse(UsageService.shouldAttemptTokenRefresh([
            "error": "network unavailable",
        ]))
    }
}
