import Foundation

struct ResetCredit: Decodable, Identifiable, Equatable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?
    let redeemedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status, title, description
        case resetType = "reset_type", grantedAt = "granted_at", expiresAt = "expires_at", redeemedAt = "redeemed_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        resetType = try c.decodeIfPresent(String.self, forKey: .resetType) ?? "unknown"
        status = try c.decode(String.self, forKey: .status)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        func date(_ key: CodingKeys) -> Date? {
            guard let text = try? c.decode(String.self, forKey: key) else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        grantedAt = date(.grantedAt)
        expiresAt = date(.expiresAt)
        redeemedAt = date(.redeemedAt)
    }

    var displayTitle: String { title?.isEmpty == false ? title! : "Usage limit reset" }
}

struct ResetCreditsList: Decodable, Equatable {
    let credits: [ResetCredit]
    let availableCount: Int?
    let totalEarnedCount: Int?

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count", totalEarnedCount = "total_earned_count"
    }

    var available: [ResetCredit] {
        credits.filter { $0.status == "available" }.sorted {
            let a = $0.expiresAt ?? .distantFuture, b = $1.expiresAt ?? .distantFuture
            return a < b
        }
    }
    var history: [ResetCredit] { credits.filter { $0.status != "available" } }
    var orderedCredits: [ResetCredit] { available + history }
}

enum ResetConsumeOutcome: Equatable {
    case reset(Int), nothingToReset, noCredit

    var message: String {
        switch self {
        case .reset(let count): return "Usage reset (\(count) limits restored)."
        case .nothingToReset: return "This account's usage doesn't need a reset right now. The reset was not used."
        case .noCredit: return "That reset is no longer available."
        }
    }
}

struct ResetCreditsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Uses the stored access token only. This service never owns or spends a refresh token.
final class ResetCreditsService: @unchecked Sendable {
    private let session: URLSession
    private let profileLoader: () -> AccountProfileCollection

    init(session: URLSession = .shared, profileLoader: @escaping () -> AccountProfileCollection = AccountProfileStore.load) {
        self.session = session
        self.profileLoader = profileLoader
    }

    static func signInError(isLeased: Bool) -> ResetCreditsError {
        ResetCreditsError(message: isLeased
            ? "Leased — its holder refreshes the sign-in; try after the next usage refresh"
            : "Sign-in expired — refresh usage, then try again")
    }

    func list(profileKey: String, isLeased: Bool) async throws -> ResetCreditsList {
        let data = try await request(profileKey: profileKey, isLeased: isLeased, suffix: "", body: nil)
        do { return try JSONDecoder().decode(ResetCreditsList.self, from: data) }
        catch { throw ResetCreditsError(message: "Could not read usage limit resets.") }
    }

    func consume(profileKey: String, isLeased: Bool, creditID: String, requestID: UUID) async throws -> ResetConsumeOutcome {
        let body = try JSONSerialization.data(withJSONObject: ["redeem_request_id": requestID.uuidString.lowercased(), "credit_id": creditID])
        let data = try await request(profileKey: profileKey, isLeased: isLeased, suffix: "/consume", body: body)
        struct Response: Decodable { let code: String; let windows_reset: Int? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ResetCreditsError(message: "Could not read the reset response.")
        }
        switch response.code {
        case "reset", "already_redeemed": return .reset(response.windows_reset ?? 0)
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: throw ResetCreditsError(message: "Unknown usage reset response. Try again to check.")
        }
    }

    private func request(profileKey: String, isLeased: Bool, suffix: String, body: Data?) async throws -> Data {
        let profile = profileLoader().profiles[profileKey]
        guard let token = profile?["access"] as? String, !token.isEmpty else { throw Self.signInError(isLeased: isLeased) }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits\(suffix)")!, timeoutInterval: 15)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UsageService.requestUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let accountID = profile?["accountId"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Self.signInError(isLeased: isLeased) }
        guard (200...299).contains(status) else { throw ResetCreditsError(message: "Usage limit resets request failed (HTTP \(status)).") }
        return data
    }
}
