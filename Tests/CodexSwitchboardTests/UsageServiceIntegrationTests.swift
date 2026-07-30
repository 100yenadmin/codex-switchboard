import Foundation
import XCTest
@testable import CodexSwitchboard

final class UsageServiceIntegrationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testExpiredAccessRefreshesOncePersistsRotationAndRetriesUsage() async throws {
        let recorder = RequestRecorder()
        let tokenUpdate = TokenUpdateRecorder()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            recorder.record(path: path)

            switch path {
            case "/backend-api/wham/usage":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                    return Self.response(
                        request,
                        status: 401,
                        json: ["detail": ["code": "token_expired"]]
                    )
                }
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer new-access"
                )
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "ChatGPT-Account-Id"),
                    "acc-weekly"
                )
                return Self.response(request, json: [
                    "account_id": "acc-weekly",
                    "plan_type": "pro",
                    "rate_limit": [
                        "primary_window": [
                            "used_percent": 20.0,
                            "reset_after_seconds": 500_000.0,
                            "limit_window_seconds": 604_800.0,
                        ],
                    ],
                ])

            case "/oauth/token":
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(json["grant_type"], "refresh_token")
                XCTAssertEqual(json["refresh_token"], "old-refresh")
                return Self.response(request, json: [
                    "access_token": "new-access",
                    "refresh_token": "new-refresh",
                    "expires_in": 3_600,
                ])

            case "/backend-api/accounts/check/v4-2023-04-27":
                return Self.response(request, json: ["accounts": [:]])

            default:
                XCTFail("Unexpected request path: \(path)")
                return Self.response(request, status: 404, json: [:])
            }
        }

        let service = makeService(tokenUpdate: tokenUpdate)
        let accounts = await service.loadAll()

        let account = try XCTUnwrap(accounts.first)
        XCTAssertFalse(account.hasError)
        XCTAssertTrue(account.isUsableForCodex)
        XCTAssertNil(account.leadingQuotaWindow)
        XCTAssertEqual(account.weeklyQuotaWindow?.freePercent, 80)
        XCTAssertEqual(recorder.count(for: "/backend-api/wham/usage"), 2)
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 1)
        XCTAssertEqual(tokenUpdate.count, 1)
        XCTAssertEqual(tokenUpdate.accessToken, "new-access")
        XCTAssertEqual(tokenUpdate.refreshToken, "new-refresh")
    }

    func testInvalidatedAccessSkipsRefreshAndRequiresRelogin() async throws {
        let recorder = RequestRecorder()
        let tokenUpdate = TokenUpdateRecorder()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            recorder.record(path: path)
            return Self.response(
                request,
                status: 401,
                json: ["detail": ["code": "token_invalidated"]]
            )
        }

        let accounts = await makeService(tokenUpdate: tokenUpdate).loadAll()

        let account = try XCTUnwrap(accounts.first)
        XCTAssertTrue(account.hasError)
        XCTAssertEqual(account.errorMessage, "Token invalidated")
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError(account.errorMessage))
        XCTAssertEqual(recorder.count(for: "/backend-api/wham/usage"), 1)
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 0)
        XCTAssertEqual(tokenUpdate.count, 0)
    }

    func testFailedRefreshStopsAfterOneGrantAndRequiresRelogin() async throws {
        let recorder = RequestRecorder()
        let tokenUpdate = TokenUpdateRecorder()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            recorder.record(path: path)
            if path == "/oauth/token" {
                return Self.response(
                    request,
                    status: 400,
                    json: ["error": "invalid_grant"]
                )
            }
            return Self.response(
                request,
                status: 401,
                json: ["detail": ["code": "token_expired"]]
            )
        }

        let accounts = await makeService(tokenUpdate: tokenUpdate).loadAll()

        let account = try XCTUnwrap(accounts.first)
        XCTAssertTrue(account.hasError)
        XCTAssertEqual(account.errorMessage, "Refresh failed - re-login required")
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError(account.errorMessage))
        XCTAssertEqual(recorder.count(for: "/backend-api/wham/usage"), 1)
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 1)
        XCTAssertEqual(tokenUpdate.count, 0)
    }

    private func makeService(tokenUpdate: TokenUpdateRecorder) -> UsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let collection = AccountProfileCollection(
            profiles: [
                "profile-weekly": [
                    "access": "old-access",
                    "refresh": "old-refresh",
                    "email": "weekly@example.invalid",
                    "accountId": "acc-weekly",
                    "plan": "pro",
                ],
            ],
            orderedKeys: ["profile-weekly"]
        )

        return UsageService(
            session: session,
            profileLoader: { collection },
            tokenUpdater: { _, _, _, accessToken, refreshToken, _, expiresAt in
                tokenUpdate.record(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: expiresAt
                )
            }
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        json: [String: Any]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (response, data)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(path: String) {
        lock.lock()
        counts[path, default: 0] += 1
        lock.unlock()
    }

    func count(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path, default: 0]
    }
}

private final class TokenUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var expiresAt: Int?

    func record(accessToken: String, refreshToken: String, expiresAt: Int) {
        lock.lock()
        count += 1
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        lock.unlock()
    }
}
