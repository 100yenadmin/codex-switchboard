import Foundation
import XCTest
@testable import CodexSwitchboard

final class ResetCreditsTests: XCTestCase {
    override func tearDown() {
        ResetMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testUsageCountsAndOldSnapshot() async throws {
        let cases: [(Any?, Int?)] = [(3, 3), (nil, nil), ("3", nil), (-1, 0), (2.0, 2), (true, nil)]
        for (raw, expected) in cases {
            ResetMockURLProtocol.handler = { request in
                guard request.url?.path == "/backend-api/wham/usage" else {
                    return Self.response(request, json: ["accounts": [:]])
                }
                var usage: [String: Any] = ["plan_type": "pro", "rate_limit": ["primary_window": ["used_percent": 50]]]
                if let raw { usage["rate_limit_reset_credits"] = ["available_count": raw] }
                return Self.response(request, json: usage)
            }
            let usage = UsageService(session: session(), profileLoader: Self.profiles,
                                     tokenUpdater: { _, _, _, _, _, _, _, _ in XCTFail("Unexpected token refresh") },
                                     refreshGate: .init(reserve: { _, _ in XCTFail("Unexpected refresh reservation"); return .leased }, release: { _ in }),
                                     cacheLoader: { [:] }, cacheSaver: { _ in })
            let accounts = await usage.loadAll()
            XCTAssertEqual(try XCTUnwrap(accounts.first).resetCreditsAvailable, expected)
        }
        ResetMockURLProtocol.handler = { request in
            Self.response(request, status: 403, json: ["rate_limit_reset_credits": ["available_count": 9]])
        }
        let unusable = UsageService(session: session(), profileLoader: Self.profiles, cacheLoader: { [:] }, cacheSaver: { _ in })
        let failed = await unusable.loadAll()
        XCTAssertNil(failed.first?.resetCreditsAvailable)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ResetTestFixtures.account())) as? [String: Any])
        old.removeValue(forKey: "resetCreditsAvailable")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.resetCreditsAvailable)
    }

    func testListOrderAndMalformedDatesKeepCredits() async throws {
        ResetMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits")
            return Self.response(request, json: ResetTestFixtures.listJSON)
        }
        let list = try await service().list(profileKey: "fixture", isLeased: false)
        XCTAssertEqual(list.available.map(\.id), ["soon", "late", "no-expiry", "bad-date"])
        XCTAssertEqual(list.history.map(\.status), ["mystery", "redeeming", "redeemed"])
        XCTAssertEqual(list.orderedCredits.map(\.id), list.available.map(\.id) + list.history.map(\.id))
        XCTAssertNil(list.credits.first { $0.id == "bad-date" }?.expiresAt)
        XCTAssertEqual(list.available.first?.displayTitle, "Usage limit reset")
        XCTAssertNotNil(list.available.first?.grantedAt)
        XCTAssertEqual(list.totalEarnedCount, 7)
    }

    func testListLoadsWithoutResetTypeOrAvailableCount() async throws {
        ResetMockURLProtocol.handler = { request in
            Self.response(request, json: ["credits": [["id": "untyped", "status": "available"]]])
        }
        let list = try await service().list(profileKey: "fixture", isLeased: false)
        XCTAssertNil(list.availableCount)
        XCTAssertEqual(list.available.map(\.id), ["untyped"])
        XCTAssertEqual(list.available.first?.resetType, "unknown")
    }

    @MainActor
    func testQuotaSummaryShowsOnlyRealWindows() {
        let weekly = ResetTestFixtures.account(quotaWindows: [
            QuotaWindow(kind: .weekly, usedPercent: 73, resetSeconds: 86400, durationSeconds: 604800),
        ])
        XCTAssertEqual(ResetCreditsContent(account: weekly, state: .loading).quotaSummary, "Weekly: 27% free")
        let empty = ResetTestFixtures.account(quotaWindows: [])
        XCTAssertEqual(ResetCreditsContent(account: empty, state: .loading).quotaSummary, "")
    }

    @MainActor
    func testConsumeHeadersBodyRetryAndNewConfirmation() async throws {
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return Self.response(request, json: ResetTestFixtures.listJSON) }
            recorder.append(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits/consume")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), UsageService.requestUserAgent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chatgpt.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://chatgpt.com/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US,en;q=0.9")
            return Self.response(request, status: recorder.requests.count == 1 ? 500 : 200,
                                 json: ["code": "nothing_to_reset", "windows_reset": 0])
        }
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
        await model.load()
        let credit = try XCTUnwrap(ResetTestFixtures.list().available.first)
        model.confirm(credit)
        let firstID = try XCTUnwrap(model.confirmation?.requestID)
        XCTAssertTrue(recorder.requests.isEmpty, "Confirmation must not consume")
        await model.useReset()
        XCTAssertNotNil(model.consumeError)
        XCTAssertEqual(model.confirmation?.requestID, firstID)
        model.tryAgain()
        XCTAssertNil(model.consumeError)
        XCTAssertEqual(recorder.requests.count, 1, "Try again returns to the Use reset button")
        await model.useReset()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.notice, .nothingToReset)
        model.confirm(credit)
        XCTAssertNotEqual(model.confirmation?.requestID, firstID)
        await model.useReset()
        let bodies = try recorder.requests.map { try JSONSerialization.jsonObject(with: Self.body($0)) as! [String: String] }
        XCTAssertEqual(Set(bodies[0].keys), ["redeem_request_id", "credit_id"])
        XCTAssertEqual(bodies[0]["credit_id"], credit.id)
        XCTAssertEqual(bodies[0]["redeem_request_id"], firstID.uuidString.lowercased())
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertNotEqual(bodies[1]["redeem_request_id"], bodies[2]["redeem_request_id"])
    }

    @MainActor
    func testOutcomesAndReloads() async throws {
        for code in ["reset", "already_redeemed", "nothing_to_reset", "no_credit", "unknown"] {
            let recorder = ResetRequestRecorder()
            ResetMockURLProtocol.handler = { request in
                recorder.append(request)
                return Self.response(request, json: request.httpMethod == "POST"
                    ? ["code": code, "windows_reset": 2] : ResetTestFixtures.listJSON)
            }
            var refreshes = 0
            let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: { refreshes += 1 })
            await model.load()
            recorder.clear()
            model.confirm(try XCTUnwrap(ResetTestFixtures.list().available.first))
            await model.useReset()
            if ["reset", "already_redeemed"].contains(code) {
                XCTAssertEqual(model.notice, .reset(2))
                XCTAssertEqual(refreshes, 1)
                XCTAssertEqual(recorder.requests.count, 2)
            } else if code == "no_credit" {
                XCTAssertEqual(model.notice, .noCredit)
                XCTAssertEqual(refreshes, 0)
                XCTAssertEqual(recorder.requests.count, 2)
            } else if code == "nothing_to_reset" {
                XCTAssertEqual(model.notice, .nothingToReset)
                XCTAssertEqual(refreshes, 0)
                XCTAssertEqual(recorder.requests.map(\.httpMethod), ["POST", "GET"], "nothing_to_reset also reloads the list")
            } else {
                XCTAssertNotNil(model.consumeError)
                XCTAssertNil(model.notice)
            }
            if code == "unknown" {
                XCTAssertNotNil(model.confirmation)
                XCTAssertEqual(model.consumeError, "Unknown usage reset response. Try again to check.")
            } else { XCTAssertNil(model.confirmation) }
            XCTAssertFalse(model.isConsuming)
        }
    }

    func testConsumeDefaultsMissingWindowsResetToZero() async throws {
        let cases: [(String, ResetConsumeOutcome)] = [
            ("reset", .reset(0)), ("already_redeemed", .reset(0)),
            ("nothing_to_reset", .nothingToReset), ("no_credit", .noCredit)
        ]
        for (code, expected) in cases {
            ResetMockURLProtocol.handler = { request in Self.response(request, json: ["code": code]) }
            let result = try await service().consume(profileKey: "fixture", isLeased: false, creditID: "soon", requestID: UUID())
            XCTAssertEqual(result, expected, code)
        }
    }

    @MainActor
    func testUnknownCodeRetryRetainsConfirmationAndRequestID() async throws {
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.httpMethod == "GET" { return Self.response(request, json: ResetTestFixtures.listJSON) }
            return Self.response(request, json: ["code": recorder.requests.count == 1 ? "unknown" : "already_redeemed"])
        }
        var refreshes = 0
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: { refreshes += 1 })
        await model.load()
        recorder.clear()
        model.confirm(try XCTUnwrap(ResetTestFixtures.list().available.first))
        let pending = model.confirmation
        await model.useReset()
        XCTAssertEqual(model.confirmation, pending)
        XCTAssertEqual(model.consumeError, "Unknown usage reset response. Try again to check.")
        guard case .loaded = model.state else { return XCTFail("Keep the list and confirmation available for retry") }
        model.tryAgain()
        XCTAssertNil(model.consumeError)
        XCTAssertEqual(model.confirmation, pending)
        XCTAssertEqual(recorder.requests.count, 1)
        await model.useReset()
        let bodies = try recorder.requests.filter { $0.httpMethod == "POST" }.map {
            try JSONSerialization.jsonObject(with: Self.body($0)) as! [String: String]
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[0]["redeem_request_id"], pending?.requestID.uuidString.lowercased())
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.notice, .reset(0))
        XCTAssertEqual(refreshes, 1)
    }

    @MainActor
    func testCancelUnresolvedConsumeReloadsBeforeNewConfirmation() async throws {
        for status in [200, 500] {
            let started = expectation(description: "cancel reload in flight (\(status))")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let recorder = ResetRequestRecorder()
            ResetMockURLProtocol.handler = { request in
                recorder.append(request)
                if request.httpMethod == "POST" {
                    return Self.response(request, status: status, json: ["code": "unknown"])
                }
                if recorder.requests.count == 1 {
                    return Self.response(request, json: ResetTestFixtures.listJSON)
                }
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/backend-api/wham/rate-limit-reset-credits")
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return Self.response(request, json: ["available_count": 1, "credits": [
                    ["id": "soon", "reset_type": "both", "status": "redeemed"],
                    ["id": "remaining", "reset_type": "both", "status": "available"]
                ]])
            }
            let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
            await model.load()
            let credit = try XCTUnwrap(ResetTestFixtures.list().available.first)
            model.confirm(credit)
            await model.useReset()
            XCTAssertNotNil(model.consumeError)
            XCTAssertNotNil(model.confirmation)
            let cancel = Task { await model.cancel() }
            await fulfillment(of: [started], timeout: 5)
            XCTAssertEqual(model.state, .loading)
            XCTAssertNil(model.consumeError)
            XCTAssertNil(model.confirmation)
            model.confirm(credit)
            XCTAssertNil(model.confirmation, "Cannot start another spend while the list is stale")
            XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "POST", "GET"])
            release.signal()
            await cancel.value
            guard case .loaded(let list) = model.state else { return XCTFail("Expected refreshed list") }
            XCTAssertEqual(list.available.map(\.id), ["remaining"])
            XCTAssertEqual(list.history.map(\.id), [credit.id])
            model.confirm(try XCTUnwrap(list.available.first))
            XCTAssertEqual(model.confirmation?.credit.id, "remaining")
        }
    }

    @MainActor
    func testCancelAfterTryAgainStillReloadsUnresolvedSpend() async throws {
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            recorder.append(request)
            if request.httpMethod == "POST" {
                return Self.response(request, json: ["code": "unknown"])
            }
            return Self.response(request, json: ResetTestFixtures.listJSON)
        }
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
        await model.load()
        model.confirm(try XCTUnwrap(ResetTestFixtures.list().available.first))
        await model.useReset()
        XCTAssertNotNil(model.consumeError)
        model.tryAgain()
        XCTAssertNil(model.consumeError)
        await model.cancel()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "POST", "GET"], "The spend is still unresolved, so Cancel reloads")
        await model.cancel()
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "POST", "GET"], "A second Cancel has nothing unresolved")
    }

    @MainActor
    func testCancelWithoutConsumeErrorDoesNotReload() async throws {
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(request, json: ResetTestFixtures.listJSON)
        }
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
        await model.load()
        let loaded = model.state
        model.confirm(try XCTUnwrap(ResetTestFixtures.list().available.first))
        await model.cancel()
        XCTAssertNil(model.confirmation)
        XCTAssertNil(model.consumeError)
        XCTAssertEqual(model.state, loaded)
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET"])
    }

    func testConfirmationNamesCreditAndExpiry() throws {
        let list = try ResetTestFixtures.list()
        let expiring = try XCTUnwrap(list.available.first { $0.id == "late" })
        let noExpiry = try XCTUnwrap(list.available.first { $0.id == "no-expiry" })
        let date = try XCTUnwrap(expiring.expiresAt).formatted(date: .abbreviated, time: .shortened)
        XCTAssertEqual(ResetConfirmation(credit: expiring, requestID: UUID()).message(email: "owner@example.invalid"),
                       "Use “Earned reset” (expires \(date)) on owner@example.invalid? It restores this account's usage limits. The reset is used up.")
        XCTAssertEqual(ResetConfirmation(credit: noExpiry, requestID: UUID()).message(email: "owner@example.invalid"),
                       "Use “Usage limit reset” (no expiry) on owner@example.invalid? It restores this account's usage limits. The reset is used up.")
    }

    func testUnauthorizedAndMissingTokenNeverRefresh() async throws {
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            recorder.append(request)
            return Self.response(request, status: 401, json: [:])
        }
        for leased in [false, true] {
            do { _ = try await service().list(profileKey: "fixture", isLeased: leased); XCTFail("Expected expired sign-in") }
            catch { XCTAssertEqual(error.localizedDescription, ResetCreditsService.signInError(isLeased: leased).message) }
            do { _ = try await service().consume(profileKey: "fixture", isLeased: leased, creditID: "soon", requestID: UUID()); XCTFail("Expected expired sign-in") }
            catch { XCTAssertEqual(error.localizedDescription, ResetCreditsService.signInError(isLeased: leased).message) }
            let missing = ResetCreditsService(session: session(), profileLoader: { .init(profiles: [:], orderedKeys: []) })
            do { _ = try await missing.list(profileKey: "fixture", isLeased: leased); XCTFail("Expected missing token error") }
            catch { XCTAssertEqual(error.localizedDescription, ResetCreditsService.signInError(isLeased: leased).message) }
        }
        XCTAssertEqual(recorder.requests.count, 4)
        XCTAssertFalse(recorder.requests.contains { $0.url?.host == "auth.openai.com" || $0.url?.path == "/oauth/token" })
    }

    @MainActor
    func testTransportRetryAndNoDoubleSubmission() async throws {
        let started = expectation(description: "consume in flight")
        let release = DispatchSemaphore(value: 0)
        let recorder = ResetRequestRecorder()
        ResetMockURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return Self.response(request, json: ResetTestFixtures.listJSON) }
            recorder.append(request)
            if recorder.requests.count == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                throw URLError(.networkConnectionLost)
            }
            return Self.response(request, json: ["code": "nothing_to_reset", "windows_reset": 0])
        }
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
        await model.load()
        let credit = try XCTUnwrap(ResetTestFixtures.list().available.first)
        model.confirm(credit)
        let id = model.confirmation?.requestID
        let first = Task { await model.useReset() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(model.isConsuming)
        await model.useReset()
        model.confirm(credit)
        await model.cancel()
        XCTAssertEqual(model.confirmation?.requestID, id)
        release.signal()
        await first.value
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNotNil(model.consumeError)
        model.tryAgain()
        await model.useReset()
        let ids = try recorder.requests.map { try JSONSerialization.jsonObject(with: Self.body($0)) as! [String: String] }
        XCTAssertEqual(ids[0], ids[1])
    }

    @MainActor
    func testLoadErrorEmptyAndRetry() async throws {
        var succeeds = false
        ResetMockURLProtocol.handler = { request in
            Self.response(request, status: succeeds ? 200 : 500, json: ["credits": [], "available_count": 0])
        }
        let model = ResetCreditsViewModel(account: ResetTestFixtures.account(), isLeased: { false }, service: service(), refreshUsage: {})
        await model.load()
        guard case .error = model.state else { return XCTFail("Expected error") }
        succeeds = true
        await model.load()
        guard case .loaded(let list) = model.state else { return XCTFail("Expected loaded") }
        XCTAssertTrue(list.available.isEmpty)
    }

    private static func profiles() -> AccountProfileCollection {
        .init(profiles: ["fixture": ["access": "fixture-access", "accountId": "fixture-account", "email": "owner@example.invalid"]], orderedKeys: ["fixture"])
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetMockURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func service() -> ResetCreditsService { .init(session: session(), profileLoader: Self.profiles) }
    private static func response(_ request: URLRequest, status: Int = 200, json: [String: Any]) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, try! JSONSerialization.data(withJSONObject: json))
    }
    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ResetMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class ResetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; stored.append(request) }
    func clear() { lock.lock(); defer { lock.unlock() }; stored = [] }
}

enum ResetTestFixtures {
    static func account(resets: Int? = 2, email: String = "owner@example.invalid", quotaWindows: [QuotaWindow]? = nil) -> Account {
        Account(id: email + "|fixture-account", profileKey: "fixture", email: email, workspace: "Personal", plan: "pro", sessionFree: 0, weeklyFree: 15, sessionResetSeconds: 3600, weeklyResetSeconds: 86400, quotaWindows: quotaWindows, planRenewalDate: nil, hasError: false, errorMessage: nil, resetCreditsAvailable: resets)
    }
    static let listJSON: [String: Any] = ["available_count": 4, "total_earned_count": 7, "credits": [
        ["id": "unknown", "reset_type": "both", "status": "mystery", "granted_at": "bad-date"],
        ["id": "late", "reset_type": "both", "status": "available", "granted_at": "2026-10-01T12:00:00Z", "expires_at": "2026-12-01T12:00:00Z", "title": "Earned reset", "description": "Restores usage limits."],
        ["id": "no-expiry", "reset_type": "both", "status": "available", "granted_at": "2026-10-01T12:00:00Z", "expires_at": NSNull()],
        ["id": "soon", "reset_type": "both", "status": "available", "granted_at": "2026-10-01T12:00:00.123Z", "expires_at": "2026-11-01T12:00:00Z"],
        ["id": "bad-date", "reset_type": "both", "status": "available", "granted_at": "bad", "expires_at": "bad"],
        ["id": "redeeming", "reset_type": "both", "status": "redeeming", "granted_at": "2026-10-01T12:00:00Z"],
        ["id": "redeemed", "reset_type": "both", "status": "redeemed", "granted_at": "2026-10-01T12:00:00Z", "redeemed_at": "2026-10-02T12:00:00Z"]
    ]]
    static func list() throws -> ResetCreditsList {
        try JSONDecoder().decode(ResetCreditsList.self, from: JSONSerialization.data(withJSONObject: listJSON))
    }
}
