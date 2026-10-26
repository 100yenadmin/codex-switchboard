import CodexSwitchboardCore
import Foundation

struct CodexAuthMirrorResult: Equatable {
    enum Status: Equatable {
        case synced
        case skipped
    }

    let status: Status
    let profileKey: String?
    let reason: String?
}

/// Mirrors rotated Codex tokens back into the stored profiles: the live `~/.codex` auth, and the
/// auth in every lease home, each written only into the profile of the account it holds.
final class CodexAuthMirrorService: @unchecked Sendable {
    /// The skip reason when a lease home's holder has its auth file locked.
    static let homeLockedReason = "home_locked"

    private let fileManager: FileManager
    private let authURL: URL
    private let profileStoreURL: URL
    private let storageRootURL: URL
    private let queue = DispatchQueue(label: "CodexSwitchboard.CodexAuthMirror")
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastSignature: FileSignature?
    private var leaseSignatures: [String: [FileSignature?]] = [:]

    init(
        fileManager: FileManager = .default,
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        profileStoreURL: URL = AppStorage.profilesURL,
        storageRootURL: URL = AppStorage.rootURL,
        interval: TimeInterval = 3
    ) {
        self.fileManager = fileManager
        self.authURL = authURL
        self.profileStoreURL = profileStoreURL
        self.storageRootURL = storageRootURL
        self.interval = interval
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }

            // Tells the CLI that this app mirrors lease homes and leaves leased tokens alone.
            try? CodexLeaseMirrorMarker.record(appSupportURL: self.storageRootURL)
            self.lastSignature = self.fileSignature()
            _ = self.syncActiveAuth()
            self.leaseSignatures = self.leaseHomeSignatures()
            if Self.needsRetry(self.syncLeasedHomes()) {
                self.leaseSignatures = [:]
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in
                self?.syncIfChanged()
                self?.syncLeasedHomesIfChanged()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    @discardableResult
    func syncActiveAuth() -> CodexAuthMirrorResult {
        CodexAuthFileLock.withLock(storageRootURL: storageRootURL) {
            syncActiveAuthWithoutLock()
        }
    }

    /// Writes each lease home's current tokens into the stored copies of its account. The lease
    /// home is the account's only live holder, so its rotations are the ones to keep.
    @discardableResult
    func syncLeasedHomes() -> [CodexAuthMirrorResult] {
        CodexAuthFileLock.withLock(storageRootURL: storageRootURL) {
            let leases: [CodexLease]
            do {
                leases = try CodexLeaseStore(appSupportURL: storageRootURL).load()
            } catch {
                return [CodexAuthMirrorResult(status: .skipped, profileKey: nil, reason: error.localizedDescription)]
            }
            return leases.map { lease in
                do {
                    // Never wait on the holder here: a busy home is synced on a later tick.
                    let outcome = try CodexHomeAuthLock.withLock(home: lease.home, timeout: 0) {
                        try CodexLeaseSync.syncHome(lease, appSupportURL: storageRootURL)
                    }
                    return CodexAuthMirrorResult(
                        status: outcome == .rotated ? .synced : .skipped,
                        profileKey: lease.profileKey,
                        reason: outcome == .rotated ? nil : outcome.rawValue
                    )
                } catch CodexHomeAuthLockError.busy {
                    return CodexAuthMirrorResult(
                        status: .skipped,
                        profileKey: lease.profileKey,
                        reason: Self.homeLockedReason
                    )
                } catch {
                    return CodexAuthMirrorResult(
                        status: .skipped,
                        profileKey: lease.profileKey,
                        reason: error.localizedDescription
                    )
                }
            }
        }
    }

    private func syncActiveAuthWithoutLock() -> CodexAuthMirrorResult {
        guard let liveAuth = StoredCodexAuth.load(from: authURL) else {
            return CodexAuthMirrorResult(status: .skipped, profileKey: nil, reason: "missing live auth")
        }

        let matches = capturedProfiles().filter { $0.matches(liveAuth) }
        guard matches.count == 1, let match = matches.first else {
            return CodexAuthMirrorResult(
                status: .skipped,
                profileKey: nil,
                reason: matches.isEmpty ? "no matching profile" : "ambiguous matching profiles"
            )
        }
        // A leased profile is written only from its lease home.
        guard let leasedKeys = try? CodexLeaseStore(appSupportURL: storageRootURL).leasedProfileKeys() else {
            return CodexAuthMirrorResult(status: .skipped, profileKey: match.sourceProfileKey, reason: "lease store unreadable")
        }
        if let profileKey = match.sourceProfileKey, leasedKeys.contains(profileKey) {
            return CodexAuthMirrorResult(status: .skipped, profileKey: profileKey, reason: "leased profile")
        }
        // Live auth that differs from a stored copy is taken only when it is a later link: a refresh, or a
        // new sign-in, always moves the access token's expiry forward. The account list is checked too,
        // since the app stores a rotation there first; after it stored one and could not pass it on,
        // live auth and the captured copy can both still hold the spent predecessor. Expiries come from
        // the tokens themselves where they can, so both sides are measured the same way, and a copy
        // whose expiry is unknown cannot be ordered, so live auth is not taken over it.
        var storedCopies = [(refreshToken: match.auth.refreshToken, expiresAt: match.auth.accessExpiresAt)]
        if let profileKey = match.sourceProfileKey,
           let entry = (AppStorage.readJSON(storageRootURL.appendingPathComponent("accounts.json"))?["profiles"]
               as? [String: Any])?[profileKey] as? [String: Any],
           let listed = entry["refresh"] as? String {
            let expiresAt = (entry["access"] as? String).flatMap(StoredCodexAuth.tokenExpiry)
                ?? (entry["expires"] as? NSNumber)?.intValue ?? 0
            storedCopies.append((listed, expiresAt))
        }
        let differing = storedCopies.filter { $0.refreshToken != liveAuth.refreshToken }
        if !differing.isEmpty {
            if liveAuth.accessExpiresAt <= 0 || differing.contains(where: { $0.expiresAt <= 0 }) {
                return CodexAuthMirrorResult(status: .skipped, profileKey: match.sourceProfileKey, reason: "live auth cannot be ordered against the stored copy")
            }
            if differing.contains(where: { liveAuth.accessExpiresAt <= $0.expiresAt }) {
                return CodexAuthMirrorResult(status: .skipped, profileKey: match.sourceProfileKey, reason: "live auth is older than the stored copy")
            }
        }

        do {
            try copyAuth(liveAuth.root, to: match.authURL)
            try updateMeta(match, with: liveAuth)
            if let profileKey = match.sourceProfileKey, !profileKey.isEmpty {
                try AccountProfileStore.updateTokens(
                    profileKey: profileKey,
                    email: liveAuth.email,
                    accountID: liveAuth.accountID,
                    accessToken: liveAuth.accessToken,
                    refreshToken: liveAuth.refreshToken,
                    idToken: liveAuth.idToken,
                    expiresAt: liveAuth.accessExpiresAt,
                    storageRootURL: storageRootURL
                )
            }
            return CodexAuthMirrorResult(status: .synced, profileKey: match.sourceProfileKey, reason: nil)
        } catch {
            return CodexAuthMirrorResult(status: .skipped, profileKey: match.sourceProfileKey, reason: error.localizedDescription)
        }
    }

    private func syncIfChanged() {
        let signature = fileSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        _ = syncActiveAuth()
    }

    func syncLeasedHomesIfChanged() {
        let signatures = leaseHomeSignatures()
        guard signatures != leaseSignatures else { return }
        leaseSignatures = signatures
        if Self.needsRetry(syncLeasedHomes()) {
            leaseSignatures = [:]
        }
    }

    /// A busy home, a torn read (Codex writes `auth.json` in place) or a failed write leaves the
    /// home's rotation uncopied, so the next tick tries again instead of waiting for a new rotation.
    static func needsRetry(_ results: [CodexAuthMirrorResult]) -> Bool {
        results.contains { result in
            guard result.status == .skipped, let reason = result.reason else { return false }
            if reason == homeLockedReason { return true }
            guard let outcome = CodexLeaseSyncOutcome(rawValue: reason) else { return true }
            return outcome == .homeAuthUnreadable
        }
    }

    /// A home's quarantine sentinel counts too: a rotation written while it existed was skipped, and its
    /// removal must bring the sync back.
    private func leaseHomeSignatures() -> [String: [FileSignature?]] {
        let leases = (try? CodexLeaseStore(appSupportURL: storageRootURL).load()) ?? []
        return Dictionary(
            leases.map { lease in
                (
                    lease.profileKey + "\u{0}" + lease.home,
                    [fileSignature(at: lease.authURL), fileSignature(at: CodexLeaseHome.stoppedSentinelURL(home: lease.home))]
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func fileSignature() -> FileSignature? {
        fileSignature(at: authURL)
    }

    private func fileSignature(at authURL: URL) -> FileSignature? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: authURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        // A holder that replaces the file gives it a new inode even when size and time match.
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return FileSignature(modified: modified, size: size.int64Value, inode: inode)
    }

    private func capturedProfiles() -> [MirrorableCapturedProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileStoreURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entryURL in
            guard (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let authURL = entryURL.appendingPathComponent("auth.json")
            guard let auth = StoredCodexAuth.load(from: authURL) else { return nil }

            let metaURL = entryURL.appendingPathComponent("meta.json")
            let meta = AppStorage.readJSON(metaURL) ?? [:]
            return MirrorableCapturedProfile(
                authURL: authURL,
                metaURL: metaURL,
                auth: auth,
                sourceProfileKey: meta["source_profile_key"] as? String
            )
        }
    }

    private func copyAuth(_ object: [String: Any], to url: URL) throws {
        var updated = object
        updated["last_refresh"] = ISO8601DateFormatter.codexSwitchboard.string(from: Date())
        try AppStorage.writeJSON(updated, to: url, permissions: 0o600)
    }

    private func updateMeta(_ profile: MirrorableCapturedProfile, with auth: StoredCodexAuth) throws {
        var meta = AppStorage.readJSON(profile.metaURL) ?? [:]
        meta["email"] = auth.email
        if !auth.accountID.isEmpty {
            meta["account_id"] = auth.accountID
        }
        meta["expires_at"] = auth.accessExpiresAt
        try AppStorage.writeJSON(meta, to: profile.metaURL, permissions: 0o600)
    }
}

/// The app side of `CodexAuthStoreLock`, so app writes and the CLI's lease, return and switch
/// writes never interleave.
enum CodexAuthFileLock {
    static func withLock<T>(
        storageRootURL: URL = AppStorage.rootURL,
        _ body: () throws -> T
    ) rethrows -> T {
        try CodexAuthStoreLock.withLock(appSupportURL: storageRootURL, body)
    }

    /// For writes that must not overlap a CLI lease, return or switch: fails instead of running
    /// with the in-process lock alone.
    static func withRequiredLock<T>(
        storageRootURL: URL = AppStorage.rootURL,
        _ body: () throws -> T
    ) throws -> T {
        try CodexAuthStoreLock.withRequiredLock(appSupportURL: storageRootURL, body)
    }
}

enum ActiveCodexAuthStore {
    static func defaultAuthURLs(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls = [
            homeURL.appendingPathComponent(".codex/auth.json"),
        ]
        if let codexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            urls.append(
                URL(fileURLWithPath: codexHome, isDirectory: true)
                    .appendingPathComponent("auth.json")
            )
        }

        var seen = Set<String>()
        return urls.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    /// The auth files a refresh may write. A home other than ~/.codex is kept only once it is in the switch
    /// record, so a lease taken after the app quits still sees the chain written there; one that cannot be
    /// recorded is skipped.
    static func recordingSwitchHomes(_ authURLs: [URL], appSupportURL: URL, defaultHome: String) -> [URL] {
        authURLs.filter { authURL in
            let home = authURL.deletingLastPathComponent().path
            guard !CodexLease.sameHome(home, defaultHome) else { return true }
            return (try? CodexSwitchHomes.record(home, appSupportURL: appSupportURL, defaultHome: defaultHome)) != nil
        }
    }

    static func updateMatching(
        authURLs: [URL] = defaultAuthURLs(),
        email: String,
        accountID: String,
        accessToken: String,
        refreshToken: String,
        idToken: String?
    ) throws {
        let refreshedIdentity = CodexAuthIdentity(
            subject: "",
            accountID: accountID,
            email: email
        )

        for authURL in authURLs {
            guard let liveAuth = StoredCodexAuth.load(from: authURL) else { continue }
            let liveIdentity = CodexAuthIdentity(
                subject: liveAuth.subject,
                accountID: liveAuth.accountID,
                email: liveAuth.email
            )
            guard refreshedIdentity.matches(liveIdentity) else { continue }
            // Every seat of a Team workspace shares its account id, so the seat is the email.
            if !refreshedIdentity.email.isEmpty, !liveIdentity.email.isEmpty,
               refreshedIdentity.email != liveIdentity.email {
                continue
            }

            var root = liveAuth.root
            var tokens = root["tokens"] as? [String: Any] ?? [:]
            tokens["access_token"] = accessToken
            tokens["refresh_token"] = refreshToken
            if let idToken, !idToken.isEmpty {
                tokens["id_token"] = idToken
            }
            if !accountID.isEmpty {
                tokens["account_id"] = accountID
            }
            root["tokens"] = tokens
            root["last_refresh"] = ISO8601DateFormatter.codexSwitchboard.string(from: Date())
            try AppStorage.writeJSON(root, to: authURL, permissions: 0o600)
        }
    }
}

private struct FileSignature: Equatable {
    let modified: Date
    let size: Int64
    let inode: UInt64
}

private struct MirrorableCapturedProfile {
    let authURL: URL
    let metaURL: URL
    let auth: StoredCodexAuth
    let sourceProfileKey: String?

    func matches(_ live: StoredCodexAuth) -> Bool {
        guard !auth.subject.isEmpty,
              auth.subject == live.subject else {
            return false
        }

        if !auth.accountID.isEmpty,
           !live.accountID.isEmpty,
           auth.accountID != live.accountID {
            return false
        }

        return true
    }
}

struct StoredCodexAuth {
    let root: [String: Any]
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let email: String
    let subject: String
    let accessExpiresAt: Int
    let idExpiresAt: Int

    static func load(from url: URL) -> StoredCodexAuth? {
        guard let root = AppStorage.readJSON(url),
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String,
              let idPayload = decodePayload(idToken) else {
            return nil
        }

        let accessPayload = decodePayload(accessToken)
        let accessExp = (accessPayload?["exp"] as? Double) ?? (idPayload["exp"] as? Double)
        let idExp = idPayload["exp"] as? Double
        return StoredCodexAuth(
            root: root,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: (tokens["account_id"] as? String) ?? "",
            email: ((idPayload["email"] as? String) ?? "").lowercased(),
            subject: (idPayload["sub"] as? String) ?? "",
            accessExpiresAt: accessExp.map { Int($0 * 1000) } ?? 0,
            idExpiresAt: idExp.map { Int($0 * 1000) } ?? 0
        )
    }

    /// A JWT's `exp` in milliseconds, or nil when the token carries none.
    static func tokenExpiry(_ token: String) -> Int? {
        guard let exp = decodePayload(token)?["exp"] as? Double, exp > 0 else { return nil }
        return Int(exp * 1000)
    }

    private static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(codexBase64URLString: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload
    }
}

private extension Data {
    init?(codexBase64URLString: String) {
        var normalized = codexBase64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
