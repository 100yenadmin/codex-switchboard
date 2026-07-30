import XCTest
@testable import CodexSwitchboard

final class CodexAuthMirrorServiceTests: XCTestCase {
    func testSyncCopiesLiveAuthIntoMatchingCapturedProfile() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)

        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-refresh",
            to: profileURL.appendingPathComponent("auth.json")
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(refreshToken(in: profileURL.appendingPathComponent("auth.json")), "fresh-refresh")
    }

    func testSyncSkipsAmbiguousMatchingProfiles() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        for name in ["one", "two"] {
            let profileURL = profilesURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try writeAuth(
                subject: "sub-1",
                email: "person@example.com",
                refreshToken: "\(name)-refresh",
                to: profileURL.appendingPathComponent("auth.json")
            )
            try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        }
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.reason, "ambiguous matching profiles")
        XCTAssertEqual(
            refreshToken(in: profilesURL.appendingPathComponent("one/auth.json")),
            "one-refresh"
        )
        XCTAssertEqual(
            refreshToken(in: profilesURL.appendingPathComponent("two/auth.json")),
            "two-refresh"
        )
    }

    func testRefreshRotationUpdatesOnlyMatchingActiveAuthStores() throws {
        let root = try temporaryDirectory()
        let matchingDefault = root.appendingPathComponent("default-auth.json")
        let matchingCLI = root.appendingPathComponent("cli-auth.json")
        let unrelated = root.appendingPathComponent("unrelated-auth.json")
        for url in [matchingDefault, matchingCLI] {
            try writeAuth(
                subject: "sub-1",
                email: "person@example.com",
                accountID: "acc-1",
                refreshToken: "old-refresh",
                to: url
            )
        }
        try writeAuth(
            subject: "sub-2",
            email: "other@example.com",
            accountID: "acc-2",
            refreshToken: "unrelated-refresh",
            to: unrelated
        )

        try ActiveCodexAuthStore.updateMatching(
            authURLs: [matchingDefault, matchingCLI, unrelated],
            email: "person@example.com",
            accountID: "acc-1",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: nil
        )

        XCTAssertEqual(accessToken(in: matchingDefault), "new-access")
        XCTAssertEqual(refreshToken(in: matchingDefault), "new-refresh")
        XCTAssertEqual(accessToken(in: matchingCLI), "new-access")
        XCTAssertEqual(refreshToken(in: matchingCLI), "new-refresh")
        XCTAssertEqual(refreshToken(in: unrelated), "unrelated-refresh")
    }

    func testDefaultActiveAuthURLsDeduplicateSharedCodexHome() {
        let home = URL(fileURLWithPath: "/tmp/switchboard-home", isDirectory: true)
        let urls = ActiveCodexAuthStore.defaultAuthURLs(
            homeURL: home,
            environment: ["CODEX_HOME": "/tmp/switchboard-home/.codex"]
        )

        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [
            "/tmp/switchboard-home/.codex/auth.json",
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeAuth(
        subject: String,
        email: String,
        accountID: String? = nil,
        refreshToken: String,
        to url: URL
    ) throws {
        try AppStorage.writeJSON(
            [
                "auth_mode": "chatgpt",
                "last_refresh": "2026-05-29T00:00:00Z",
                "tokens": [
                    "access_token": "access-\(refreshToken)",
                    "account_id": accountID ?? subject,
                    "id_token": idToken(subject: subject, email: email),
                    "refresh_token": refreshToken,
                ],
            ],
            to: url
        )
    }

    private func refreshToken(in url: URL) -> String? {
        let auth = AppStorage.readJSON(url)
        let tokens = auth?["tokens"] as? [String: Any]
        return tokens?["refresh_token"] as? String
    }

    private func accessToken(in url: URL) -> String? {
        let auth = AppStorage.readJSON(url)
        let tokens = auth?["tokens"] as? [String: Any]
        return tokens?["access_token"] as? String
    }

    private func idToken(subject: String, email: String) -> String {
        let header = base64URL(["alg": "none"])
        let payload = base64URL([
            "email": email,
            "exp": 1_800_000_000,
            "sub": subject,
        ])
        return "\(header).\(payload).sig"
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
