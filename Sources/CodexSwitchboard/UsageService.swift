import Foundation

/// Fetches best-effort Codex usage data from chatgpt.com.
final class UsageService: @unchecked Sendable {

    typealias TokenUpdater = (
        _ profileKey: String,
        _ email: String,
        _ accountID: String,
        _ accessToken: String,
        _ refreshToken: String,
        _ idToken: String?,
        _ expiresAt: Int
    ) throws -> Void

    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let refreshedAccessTokenKey = "__codex_switchboard_access_token"
    private let session: URLSession
    private let profileLoader: () -> AccountProfileCollection
    private let tokenUpdater: TokenUpdater
    private static let refreshFailedError = "Refresh failed - re-login required"

    init(
        session: URLSession = .shared,
        profileLoader: @escaping () -> AccountProfileCollection = AccountProfileStore.load,
        tokenUpdater: @escaping TokenUpdater = { profileKey, email, accountID,
            accessToken, refreshToken, idToken, expiresAt in
            try AccountProfileStore.updateTokens(
                profileKey: profileKey,
                email: email,
                accountID: accountID,
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                expiresAt: expiresAt
            )
        }
    ) {
        self.session = session
        self.profileLoader = profileLoader
        self.tokenUpdater = tokenUpdater
    }

    private enum RefreshResult {
        case unavailable
        case failed
        case refreshed([String: Any])
    }

    private struct RefreshedTokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
        }
    }

    private struct AccountMetadata: Sendable {
        let workspaceName: String?
        let planRenewalDate: Date?
    }

    // MARK: - Public

    func loadAll() async -> [Account] {
        let collection = profileLoader()
        var profiles = collection.profiles
        let validKeys = collection.orderedKeys.filter { profiles[$0] != nil }

        // Fetch usage concurrently
        var usages: [String: [String: Any]] = await withTaskGroup(
            of: (String, [String: Any]).self
        ) { group in
            for key in validKeys {
                if let profile = profiles[key] {
                    group.addTask { (key, await self.fetchUsage(profileKey: key, profile: profile)) }
                }
            }
            var map: [String: [String: Any]] = [:]
            for await (k, v) in group { map[k] = v }
            return map
        }

        // Refresh only profiles whose usage request proves the access token is stale.
        // This loop is intentionally serial so each atomic profile-store write starts
        // from the preceding write instead of racing another account refresh.
        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key],
                  Self.shouldAttemptTokenRefresh(usage) else {
                continue
            }

            switch await refreshProfile(profileKey: key, profile: profile) {
            case .unavailable:
                break
            case .failed:
                usages[key] = ["error": Self.refreshFailedError]
            case .refreshed(let refreshedProfile):
                profiles[key] = refreshedProfile
                usages[key] = await fetchUsage(profileKey: key, profile: refreshedProfile)
            }
        }

        var teamNames = TeamNameCacheStore.load()
        let workspaceNamedAccountIDs = workspaceNamedAccountIDs(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let metadataTokens = accountMetadataTokens(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let tokenAccountMetadata = await fetchAccountMetadata(for: metadataTokens)
        let accountMetadataByID = mergedAccountMetadata(from: tokenAccountMetadata)

        if !tokenAccountMetadata.isEmpty {
            var resolvedNames: [String: String] = [:]
            for tokenMap in tokenAccountMetadata.values {
                for (aid, metadata) in tokenMap
                where workspaceNamedAccountIDs.contains(aid)
                    && !aid.isEmpty
                    && metadata.workspaceName?.isEmpty == false
                    && metadata.workspaceName?.isGenericWorkspaceName == false {
                    guard let name = metadata.workspaceName else { continue }
                    if teamNames[aid] == nil || teamNames[aid]?.isGenericWorkspaceName == true {
                        teamNames[aid] = name
                    }
                    resolvedNames[aid] = name
                }
            }
            TeamNameCacheStore.save(resolvedNames)
        }

        // Build Account list
        var accounts: [Account] = []
        var seenEmails = Set<String>()

        for key in validKeys {
            guard let p = profiles[key] else { continue }
            let usage = usages[key] ?? [:]

            let email = (p["email"]     as? String)
                     ?? (usage["email"] as? String)
                     ?? (p["accountId"] as? String)
                     ?? key.components(separatedBy: ":").last ?? key

            let aid = (usage["account_id"] as? String) ?? (p["accountId"] as? String) ?? ""
            let dedup = Self.dedupID(email: email, accountID: aid, profileKey: key)
            guard !seenEmails.contains(dedup) else { continue }
            seenEmails.insert(dedup)

            let usageError = usageErrorMessage(from: usage)
            let rl  = usage["rate_limit"]       as? [String: Any]
            let hasUsage = usageError == nil && rl != nil
            let quotaWindows = hasUsage ? Self.quotaWindows(from: usage) : []
            let sessionWindow = quotaWindows.first { $0.kind == .fiveHour }
            let weeklyWindow = quotaWindows.first { $0.kind == .weekly }

            let planType = resolvedPlanType(profile: p, usage: usage)
            let usesWorkspaceName = workspaceNamedAccountIDs.contains(aid)
            var ws = usesWorkspaceName ? teamNames[aid] : nil
            var planRenewalDate: Date?

            // Retry with the current account token when the real workspace name is unavailable.
            if let tok = accessToken(for: key, profile: p, usages: usages),
               !tok.isEmpty {
                let metadata = tokenAccountMetadata[tok]?[aid] ?? accountMetadataByID[aid]
                if let metadata {
                    planRenewalDate = metadata.planRenewalDate

                    if usesWorkspaceName,
                       (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true),
                       let resolved = metadata.workspaceName,
                       !resolved.isEmpty {
                        ws = resolved
                        teamNames[aid] = resolved
                    } else if usesWorkspaceName,
                              (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true) {
                        // Last fallback: use any non-generic workspace name returned by this token.
                        if let tokenMap = tokenAccountMetadata[tok],
                           let anyRealName = tokenMap.values.compactMap(\.workspaceName).first(where: { !$0.isEmpty && !$0.isGenericWorkspaceName }) {
                            ws = anyRealName
                        }
                    }
                }
            }

            let workspaceName = ws
                ?? planType
                ?? "?"

            accounts.append(Account(
                id: dedup,
                profileKey: key,
                email: email,
                workspace: workspaceName,
                plan: planType ?? "?",
                sessionFree: sessionWindow?.freePercent ?? 100,
                weeklyFree: weeklyWindow?.freePercent ?? 100,
                sessionResetSeconds: sessionWindow?.resetSeconds ?? 0,
                weeklyResetSeconds: weeklyWindow?.resetSeconds ?? 0,
                quotaWindows: quotaWindows,
                planRenewalDate: planRenewalDate,
                hasError: !hasUsage || quotaWindows.isEmpty,
                errorMessage: usageError
                    ?? (rl == nil ? "Codex usage unavailable" : nil)
                    ?? (quotaWindows.isEmpty ? "No quota windows reported" : nil)
            ))
        }
        applyWorkspacePlanDates(to: &accounts)
        return accounts
    }

    // MARK: - Private Helpers

    static func dedupID(email: String, accountID: String, profileKey: String) -> String {
        "\(email.lowercased())|\(accountID.isEmpty ? profileKey : accountID)"
    }

    static func quotaWindows(from data: [String: Any]) -> [QuotaWindow] {
        guard let rateLimit = data["rate_limit"] as? [String: Any] else { return [] }

        let rawWindows: [(String, [String: Any])] = [
            ("primary", rateLimit["primary_window"] as? [String: Any]),
            ("secondary", rateLimit["secondary_window"] as? [String: Any]),
        ].compactMap { name, value in
            guard let value else { return nil }
            return (name, value)
        }

        return rawWindows.compactMap { position, raw in
            guard let usedPercent = number(raw["used_percent"]) else { return nil }
            let duration = number(raw["limit_window_seconds"])
            let fallbackKind: QuotaWindow.Kind = position == "secondary" ? .weekly : .fiveHour
            return QuotaWindow(
                kind: quotaKind(durationSeconds: duration, fallback: fallbackKind),
                usedPercent: max(0, min(100, usedPercent)),
                resetSeconds: max(0, number(raw["reset_after_seconds"]) ?? 0),
                durationSeconds: duration
            )
        }
        .sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0)
        }
    }

    static func shouldAttemptTokenRefresh(_ data: [String: Any]) -> Bool {
        if let code = normalizedErrorCode(from: data) {
            if ["token_invalidated", "token_revoked", "refresh_token_expired",
                "refresh_token_reused", "refresh_token_invalidated"].contains(code) {
                return false
            }
            if code == "token_expired" { return true }
        }
        return number(data["http_status"]) == 401
    }

    private static func quotaKind(
        durationSeconds: Double?,
        fallback: QuotaWindow.Kind
    ) -> QuotaWindow.Kind {
        guard let durationSeconds, durationSeconds > 0 else { return fallback }
        switch durationSeconds {
        case 14_400...21_600: return .fiveHour
        case 75_600...97_200: return .daily
        case 518_400...691_200: return .weekly
        case 2_332_800...2_851_200: return .monthly
        default: return .other
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func normalizedErrorCode(from data: [String: Any]) -> String? {
        let candidates: [Any?] = [
            (data["detail"] as? [String: Any])?["code"],
            (data["error"] as? [String: Any])?["code"],
            data["code"],
        ]
        for candidate in candidates {
            if let value = candidate as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty { return normalized }
            }
        }
        return nil
    }

    private func fetchUsage(profileKey: String, profile: [String: Any]) async -> [String: Any] {
        guard let accessToken = profile["access"] as? String,
              !accessToken.isEmpty else {
            return ["error": "missing access token"]
        }

        let accountID = profile["accountId"] as? String
        return usage(
            await apiGet(
                "/backend-api/wham/usage",
                token: accessToken,
                accountID: accountID
            ),
            accessToken: accessToken
        )
    }

    private func refreshProfile(
        profileKey: String,
        profile: [String: Any]
    ) async -> RefreshResult {
        guard let refreshToken = profile["refresh"] as? String,
              !refreshToken.isEmpty else {
            return .unavailable
        }
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            return .failed
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": oauthClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            let (data, urlResponse) = try await session.data(for: request)
            let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else { return .failed }

            let response = try JSONDecoder().decode(RefreshedTokenResponse.self, from: data)
            guard let accessToken = response.accessToken, !accessToken.isEmpty else {
                return .failed
            }

            let nextRefreshToken = response.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
                ?? refreshToken
            let expiresAt = tokenExpirationMilliseconds(
                accessToken: accessToken,
                expiresIn: response.expiresIn
            )
            let email = profile["email"] as? String ?? ""
            let accountID = profile["accountId"] as? String ?? ""
            try tokenUpdater(
                profileKey,
                email,
                accountID,
                accessToken,
                nextRefreshToken,
                response.idToken,
                expiresAt
            )

            var refreshedProfile = profile
            refreshedProfile["access"] = accessToken
            refreshedProfile["refresh"] = nextRefreshToken
            refreshedProfile["expires"] = expiresAt
            return .refreshed(refreshedProfile)
        } catch {
            return .failed
        }
    }

    private func tokenExpirationMilliseconds(
        accessToken: String,
        expiresIn: Double?
    ) -> Int {
        if let expiresIn, expiresIn > 0 {
            return Int((Date().timeIntervalSince1970 + expiresIn) * 1_000)
        }

        let parts = accessToken.split(separator: ".")
        if parts.count >= 2 {
            var encoded = String(parts[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while encoded.count % 4 != 0 { encoded += "=" }
            if let payloadData = Data(base64Encoded: encoded),
               let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let expiration = Self.number(payload["exp"]) {
                return Int(expiration * 1_000)
            }
        }

        return Int((Date().timeIntervalSince1970 + 3_600) * 1_000)
    }

    private func fetchAccountMetadata(token: String) async -> [String: AccountMetadata] {
        let data = await apiGet("/backend-api/accounts/check/v4-2023-04-27", token: token, timeout: 4)
        var result: [String: AccountMetadata] = [:]
        if let accts = data["accounts"] as? [String: [String: Any]] {
            for (aid, info) in accts {
                let account = info["account"] as? [String: Any]
                let entitlement = info["entitlement"] as? [String: Any]
                result[aid] = AccountMetadata(
                    workspaceName: account?["name"] as? String,
                    planRenewalDate: planRenewalDate(from: entitlement)
                )
            }
        }
        return result
    }

    private func fetchAccountMetadata(for tokens: Set<String>) async -> [String: [String: AccountMetadata]] {
        guard !tokens.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, [String: AccountMetadata]).self) { group in
            for token in tokens {
                group.addTask { (token, await self.fetchAccountMetadata(token: token)) }
            }

            var result: [String: [String: AccountMetadata]] = [:]
            for await (token, names) in group {
                result[token] = names
            }
            return result
        }
    }

    private func mergedAccountMetadata(
        from tokenAccountMetadata: [String: [String: AccountMetadata]]
    ) -> [String: AccountMetadata] {
        var result: [String: AccountMetadata] = [:]

        for metadataMap in tokenAccountMetadata.values {
            for (accountID, metadata) in metadataMap {
                guard !accountID.isEmpty else { continue }

                if let existing = result[accountID] {
                    result[accountID] = AccountMetadata(
                        workspaceName: existing.workspaceName ?? metadata.workspaceName,
                        planRenewalDate: existing.planRenewalDate ?? metadata.planRenewalDate
                    )
                } else {
                    result[accountID] = metadata
                }
            }
        }

        return result
    }

    private func applyWorkspacePlanDates(to accounts: inout [Account]) {
        var datesByWorkspace: [String: Date] = [:]

        for account in accounts {
            guard let date = account.planRenewalDate,
                  !account.workspace.isGenericWorkspaceName else { continue }
            datesByWorkspace[account.workspace] = date
        }

        guard !datesByWorkspace.isEmpty else { return }

        for index in accounts.indices where accounts[index].planRenewalDate == nil {
            let workspace = accounts[index].workspace
            guard !workspace.isGenericWorkspaceName,
                  let date = datesByWorkspace[workspace] else { continue }
            accounts[index].planRenewalDate = date
        }
    }

    private func apiGet(
        _ endpoint: String,
        token: String,
        accountID: String? = nil,
        timeout: TimeInterval = 10
    ) async -> [String: Any] {
        guard let url = URL(string: "https://chatgpt.com\(endpoint)") else {
            return ["error": "bad URL"]
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.setValue(ua,                  forHTTPHeaderField: "User-Agent")
        req.setValue("application/json",  forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com",  forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9",   forHTTPHeaderField: "Accept-Language")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await session.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj["http_status"] = statusCode
                if !(200...299).contains(statusCode), obj["error"] == nil {
                    obj["error"] = readableAPIError(from: obj) ?? "HTTP \(statusCode)"
                }
                return obj
            }
        } catch {
            return ["error": error.localizedDescription]
        }
        return ["error": "parse error"]
    }

    private func usage(_ usage: [String: Any], accessToken: String) -> [String: Any] {
        var usage = usage
        usage[refreshedAccessTokenKey] = accessToken
        return usage
    }

    private func usageErrorMessage(from data: [String: Any]) -> String? {
        if let error = data["error"] as? String, error == Self.refreshFailedError {
            return error
        }

        if let code = Self.normalizedErrorCode(from: data) {
            return Self.displayMessage(forErrorCode: code)
        }

        if let status = data["http_status"] as? Int, status == 401 {
            return "Expired or revoked"
        }

        if let error = data["error"] as? String, !error.isEmpty {
            return error.replacingOccurrences(of: "_", with: " ")
        }

        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }

        if let status = data["http_status"] as? Int, !(200...299).contains(status) {
            return "HTTP \(status)"
        }

        return nil
    }

    static func isExpiredOrRevokedAuthError(_ message: String?) -> Bool {
        isRecoverableAuthError(message) || requiresRelogin(message)
    }

    static func isRecoverableAuthError(_ message: String?) -> Bool {
        normalizedAuthMessage(message) == "token expired"
    }

    static func requiresRelogin(_ message: String?) -> Bool {
        guard let message = normalizedAuthMessage(message) else { return false }
        return message == "expired or revoked"
            || message == "token invalidated"
            || message == "token revoked"
            || message == "missing access token"
            || message == refreshFailedError.lowercased()
            || message == "http 401"
            || message == "http 403"
    }

    private static func normalizedAuthMessage(_ message: String?) -> String? {
        message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayMessage(forErrorCode code: String) -> String {
        switch code {
        case "deactivated_workspace":
            return "Workspace deactivated"
        case "token_expired":
            return "Token expired"
        case "token_invalidated":
            return "Token invalidated"
        case "token_revoked":
            return "Token revoked"
        default:
            let human = code.replacingOccurrences(of: "_", with: " ")
            return human.prefix(1).uppercased() + human.dropFirst()
        }
    }

    private func readableAPIError(from data: [String: Any]) -> String? {
        if let detail = data["detail"] as? [String: Any],
           let code = detail["code"] as? String,
           !code.isEmpty {
            return code
        }
        if let detail = data["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = data["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
        }
        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private func accountMetadataTokens(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var tokens = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            if usage["error"] == nil,
               let token = accessToken(for: key, profile: profile, usages: usages),
               !token.isEmpty {
                tokens.insert(token)
            }
        }

        return tokens
    }

    private func workspaceNamedAccountIDs(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var accountIDs = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            let accountID = (usage["account_id"] as? String) ?? (profile["accountId"] as? String) ?? ""
            guard !accountID.isEmpty else { continue }

            let planType = resolvedPlanType(profile: profile, usage: usage)
            if shouldUseWorkspaceName(planType: planType, accountID: accountID) {
                accountIDs.insert(accountID)
            }
        }

        return accountIDs
    }

    private func resolvedPlanType(
        profile: [String: Any],
        usage: [String: Any]
    ) -> String? {
        let planType = (usage["plan_type"] as? String) ?? (profile["plan"] as? String)
        let trimmed = planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private func accessToken(
        for key: String,
        profile: [String: Any],
        usages: [String: [String: Any]]
    ) -> String? {
        (usages[key]?[refreshedAccessTokenKey] as? String) ?? (profile["access"] as? String)
    }

    private func shouldUseWorkspaceName(planType: String?, accountID: String) -> Bool {
        if accountID.isLikelyPersonalAccountID {
            return false
        }

        guard let planType else {
            return true
        }

        if planType.isUnknownPlanType {
            return true
        }

        return !planType.isPersonalPlanType
    }

    private func planRenewalDate(from entitlement: [String: Any]?) -> Date? {
        guard let entitlement else { return nil }
        return dateValue(entitlement["renews_at"])
            ?? dateValue(entitlement["expires_at"])
            ?? dateValue((entitlement["discount"] as? [String: Any])?["discount_expires_at"])
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            return Self.isoDateWithFractionalSeconds.date(from: string)
                ?? Self.isoDate.date(from: string)
        }

        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }

        if let number = value as? Int {
            let double = Double(number)
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }

        return nil
    }

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoDateWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
