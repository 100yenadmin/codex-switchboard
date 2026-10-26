import Darwin
import Foundation

/// One account's Codex token lent to a separate CODEX_HOME. Refresh tokens are single-use, so while a
/// lease is active its home is the only live holder of the account's token chain: switch and auto-swap
/// skip the account, the app does not refresh its token, and every rotation in the home is written
/// back to the stored profile.
public struct CodexLease: Codable, Equatable {
    public let profileKey: String
    public let home: String
    public let holder: String
    public let leasedAt: Date
    public let profileDirectory: String?

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case home
        case holder
        case leasedAt = "leased_at"
        case profileDirectory = "profile_directory"
    }

    public init(
        profileKey: String,
        home: String,
        holder: String,
        leasedAt: Date = Date(),
        profileDirectory: String?
    ) {
        self.profileKey = profileKey
        self.home = home
        self.holder = holder
        self.leasedAt = leasedAt
        self.profileDirectory = profileDirectory
    }

    public var homeURL: URL {
        URL(fileURLWithPath: home, isDirectory: true)
    }

    public var authURL: URL {
        homeURL.appendingPathComponent("auth.json")
    }

    /// The canonical spelling of a home directory: absolute, no trailing slash, and symlinks resolved
    /// through its deepest existing ancestor, so a home that does not exist yet still resolves.
    public static func normalizedHome(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var existing = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/" {
            if let resolved = Darwin.realpath(existing.path, nil) {
                defer { free(resolved) }
                var url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in missing.reversed() {
                    url.appendPathComponent(component, isDirectory: true)
                }
                return url.path
            }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    /// Every spelling a process might use for this home, such as `/var/...` and `/private/var/...`.
    public static func homeSpellings(_ path: String) -> Set<String> {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        var spellings: Set<String> = [standardized, normalizedHome(path)]
        for spelling in spellings {
            if spelling.hasPrefix("/private/") {
                spellings.insert(String(spelling.dropFirst("/private".count)))
            } else if ["/var/", "/tmp/", "/etc/"].contains(where: { spelling.hasPrefix($0) }) {
                spellings.insert("/private" + spelling)
            }
        }
        return spellings
    }

    public static func sameHome(_ lhs: String, _ rhs: String) -> Bool {
        !homeSpellings(lhs).isDisjoint(with: homeSpellings(rhs))
    }
}

public enum CodexLeaseStoreError: LocalizedError {
    case unreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path):
            return "The lease store at \(path) exists but cannot be read; refusing to guess which accounts are leased."
        }
    }
}

/// Active leases, kept in `leases.json` in Switchboard's app storage. Writers hold `CodexAuthStoreLock`.
public final class CodexLeaseStore {
    public static let fileName = "leases.json"

    private struct Payload: Codable {
        var version: Int
        var leases: [CodexLease]
    }

    public let url: URL

    public convenience init(appSupportURL: URL) {
        self.init(url: appSupportURL.appendingPathComponent(Self.fileName))
    }

    public init(url: URL) {
        self.url = url
    }

    /// A missing file means no leases. A file that exists but does not decode throws, so that callers
    /// fail closed instead of treating a leased account as free.
    public func load() throws -> [CodexLease] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            throw CodexLeaseStoreError.unreadable(path: url.path)
        }
        return payload.leases
    }

    public func save(_ leases: [CodexLease]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexAtomicFile.write(encoder.encode(Payload(version: 1, leases: leases)), to: url)
    }

    public func leasedProfileKeys() throws -> Set<String> {
        Set(try load().map(\.profileKey))
    }

    public func lease(forProfileKey profileKey: String) throws -> CodexLease? {
        try load().first { $0.profileKey == profileKey }
    }
}

/// Serializes auth-store writes between the Switchboard app and the CLI. The recursive lock makes it
/// reentrant within one process; `lockf` on `<app support>/.auth.lock` makes it exclusive across them.
public enum CodexAuthStoreLock {
    public static let fileName = ".auth.lock"

    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var depth = 0
        var descriptor: Int32 = -1
    }

    private static let state = State()

    /// Fails when the cross-process lock cannot be taken. The CLI takes this before any auth write.
    public static func withRequiredLock<T>(appSupportURL: URL, _ body: () throws -> T) throws -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.depth == 0 {
            state.descriptor = try acquire(appSupportURL: appSupportURL)
        }
        state.depth += 1
        defer { release() }
        return try body()
    }

    /// Takes the cross-process lock when it can and otherwise keeps the in-process lock alone, so the
    /// app's non-throwing callers keep working if the lock file cannot be opened.
    public static func withLock<T>(appSupportURL: URL, _ body: () throws -> T) rethrows -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.depth == 0 {
            state.descriptor = (try? acquire(appSupportURL: appSupportURL)) ?? -1
        }
        state.depth += 1
        defer { release() }
        return try body()
    }

    private static func release() {
        state.depth -= 1
        guard state.depth == 0, state.descriptor >= 0 else { return }
        _ = Darwin.lockf(state.descriptor, F_ULOCK, 0)
        Darwin.close(state.descriptor)
        state.descriptor = -1
    }

    private static func acquire(appSupportURL: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = appSupportURL.appendingPathComponent(fileName).path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }
}

public enum CodexLeaseSyncError: LocalizedError {
    case storedCopyUnreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case let .storedCopyUnreadable(path):
            return "A stored copy of the leased account at \(path) cannot be read, so its token cannot be brought up to date."
        }
    }
}

public enum CodexLeaseSyncOutcome: String, Equatable {
    /// The home held rotated tokens; every stored copy of the account now holds them.
    case rotated
    /// Every stored copy already matched the home.
    case unchanged
    case homeAuthMissing = "home_auth_missing"
    case homeAuthUnreadable = "home_auth_unreadable"
    case storedProfileMissing = "stored_profile_missing"
    /// The home holds a different account. Nothing was written.
    case identityMismatch = "identity_mismatch"
}

/// Writes a lease home's current tokens back into Switchboard's stored copies of the leased account:
/// the captured profile copied at lease time, any other captured profile with the same key, and the
/// account list the app refreshes usage from. Callers hold `CodexAuthStoreLock`.
public enum CodexLeaseSync {
    public static func syncHome(_ lease: CodexLease, appSupportURL: URL) throws -> CodexLeaseSyncOutcome {
        guard FileManager.default.fileExists(atPath: lease.authURL.path) else {
            return .homeAuthMissing
        }
        guard let homeAuth = StoredAuth.load(from: lease.authURL), homeAuth.hasCompleteTokens else {
            return .homeAuthUnreadable
        }

        // Every stored copy must be readable, or one of them could keep a spent token after return.
        let stored = try storedProfiles(
            profileKey: lease.profileKey,
            profilesURL: appSupportURL.appendingPathComponent("profiles", isDirectory: true)
        )
        guard let pinned = stored.first(where: { $0.directoryName == lease.profileDirectory })
            ?? stored.max(by: { $0.modified < $1.modified }) else {
            return .storedProfileMissing
        }
        guard pinned.auth.identity.matches(homeAuth.identity) else {
            return .identityMismatch
        }

        var wrote = false
        for profile in stored where profile.auth.identity.matches(homeAuth.identity) {
            guard !profile.auth.hasSameTokens(as: homeAuth) else { continue }
            var root = homeAuth.root
            if profile.directoryName != pinned.directoryName {
                root = profile.auth.root
                var tokens = root["tokens"] as? [String: Any] ?? [:]
                tokens["id_token"] = homeAuth.idToken
                tokens["access_token"] = homeAuth.accessToken
                tokens["refresh_token"] = homeAuth.refreshToken
                if !homeAuth.accountID.isEmpty {
                    tokens["account_id"] = homeAuth.accountID
                }
                root["tokens"] = tokens
                root["last_refresh"] = homeAuth.root["last_refresh"] ?? root["last_refresh"]
            }
            try CodexAtomicFile.writeJSON(root, to: profile.authURL)
            if let expiresAt = homeAuth.accessExpiresAt {
                var meta = readJSON(profile.metaURL) ?? [:]
                meta["expires_at"] = expiresAt
                try CodexAtomicFile.writeJSON(meta, to: profile.metaURL)
            }
            wrote = true
        }

        if try updateAccountList(
            profileKey: lease.profileKey,
            auth: homeAuth,
            accountsURL: appSupportURL.appendingPathComponent("accounts.json")
        ) {
            wrote = true
        }
        return wrote ? .rotated : .unchanged
    }

    /// True when the home and the profile copied at lease time hold the same token chain head.
    public static func homeMatchesStoredProfile(_ lease: CodexLease, appSupportURL: URL) -> Bool {
        guard let homeAuth = StoredAuth.load(from: lease.authURL),
              let stored = try? storedProfiles(
            profileKey: lease.profileKey,
              profilesURL: appSupportURL.appendingPathComponent("profiles", isDirectory: true)
              ),
              let pinned = stored.first(where: { $0.directoryName == lease.profileDirectory })
                ?? stored.max(by: { $0.modified < $1.modified }) else {
            return false
        }
        return pinned.auth.hasSameTokens(as: homeAuth)
    }

    private struct StoredProfile {
        let directoryName: String
        let authURL: URL
        let metaURL: URL
        let auth: StoredAuth
        let modified: Date
    }

    private static func storedProfiles(profileKey: String, profilesURL: URL) throws -> [StoredProfile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try entries.compactMap { entry in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let metaURL = entry.appendingPathComponent("meta.json")
            guard (readJSON(metaURL)?["source_profile_key"] as? String) == profileKey else { return nil }
            let authURL = entry.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: authURL.path) else { return nil }
            guard let auth = StoredAuth.load(from: authURL) else {
                throw CodexLeaseSyncError.storedCopyUnreadable(path: authURL.path)
            }
            return StoredProfile(
                directoryName: entry.lastPathComponent,
                authURL: authURL,
                metaURL: metaURL,
                auth: auth,
                modified: (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
            )
        }
    }

    private static func updateAccountList(profileKey: String, auth: StoredAuth, accountsURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: accountsURL.path) else { return false }
        guard var root = readJSON(accountsURL) else {
            throw CodexLeaseSyncError.storedCopyUnreadable(path: accountsURL.path)
        }
        guard var profiles = root["profiles"] as? [String: Any],
              var entry = profiles[profileKey] as? [String: Any] else {
            return false
        }
        guard entry["access"] as? String != auth.accessToken
            || entry["refresh"] as? String != auth.refreshToken else {
            return false
        }
        entry["access"] = auth.accessToken
        entry["refresh"] = auth.refreshToken
        if let expiresAt = auth.accessExpiresAt {
            entry["expires"] = expiresAt
        }
        profiles[profileKey] = entry
        root["profiles"] = profiles
        try CodexAtomicFile.writeJSON(root, to: accountsURL)
        return true
    }
}

/// The app's in-flight refresh grants. A grant spends the account's current refresh token, so a
/// lease must not copy that token until the grant's rotation is stored. A reservation older than
/// `maxAge` is stale (the app died mid-grant). Callers hold `CodexAuthStoreLock`.
public final class CodexRefreshReservations {
    public static let fileName = "refresh-reservations.json"
    public static let maxAge: TimeInterval = 60

    private let url: URL

    public init(appSupportURL: URL) {
        url = appSupportURL.appendingPathComponent(Self.fileName)
    }

    public func reserve(profileKey: String, now: Date = Date()) throws {
        var reservations = load()
        reservations[profileKey] = now.timeIntervalSince1970
        try save(reservations)
    }

    public func release(profileKey: String) throws {
        var reservations = load()
        guard reservations.removeValue(forKey: profileKey) != nil else { return }
        try save(reservations)
    }

    public func isReserved(profileKey: String, now: Date = Date()) -> Bool {
        guard let since = load()[profileKey] else { return false }
        return now.timeIntervalSince1970 - since < Self.maxAge
    }

    private func load() -> [String: TimeInterval] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: TimeInterval].self, from: data)) ?? [:]
    }

    private func save(_ reservations: [String: TimeInterval]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try CodexAtomicFile.write(encoder.encode(reservations), to: url)
    }
}

/// Written by a lease-aware Switchboard app when its auth mirror starts. A running app without this
/// marker predates leases: it would neither mirror a lease home nor stop refreshing a leased token,
/// so the CLI refuses to lease while one runs.
public enum CodexLeaseMirrorMarker {
    public static let fileName = "lease-mirror.json"

    public static func record(appSupportURL: URL, pid: Int32 = Darwin.getpid()) throws {
        try CodexAtomicFile.writeJSON(
            [
                "pid": Int(pid),
                "lease_support": 1,
                "started_at": ISO8601DateFormatter().string(from: Date()),
            ],
            to: appSupportURL.appendingPathComponent(fileName)
        )
    }

    public static func recordedPID(appSupportURL: URL) -> Int32? {
        guard let root = readJSON(appSupportURL.appendingPathComponent(fileName)),
              (root["lease_support"] as? Int ?? 0) >= 1,
              let pid = root["pid"] as? Int else {
            return nil
        }
        return Int32(pid)
    }

    public static func isReady(runningAppPIDs: [Int32], recordedPID: Int32?) -> Bool {
        runningAppPIDs.allSatisfy { $0 == recordedPID }
    }
}

enum CodexAtomicFile {
    static func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(data, to: url, permissions: permissions)
    }

    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
