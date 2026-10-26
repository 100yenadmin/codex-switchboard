import CryptoKit
import Darwin
import Foundation

/// One account's Codex token lent to a separate CODEX_HOME. Refresh tokens are single-use, so while a
/// lease is active its home is the only live holder of the account's token chain: switch and auto-swap
/// skip the account, the app does not refresh its token, and every rotation in the home is written
/// back to the stored profile.
public struct CodexLease: Codable, Equatable {
    /// `returning` is still a lease to every reader: the account stays out of switch, auto-swap,
    /// refresh and leasing until the return re-reads the home and the entry is removed.
    /// Every state counts as leased. `leasing` lasts until the home's `auth.json` is durable; a return
    /// of a lease that never left `leasing` has nothing to copy, which `authWritten` remembers through
    /// `returning`.
    public enum State: String, Codable {
        case leasing
        case active
        case returning
    }

    public let leaseID: String
    public let profileKey: String
    public let home: String
    public let holder: String
    public let leasedAt: Date
    public let profileDirectory: String?
    public var state: State
    /// Whether the account's auth was written into the home. A lease that crashed before that write
    /// never lent its chain, so returning it with no `auth.json` in the home loses nothing.
    public var authWritten: Bool

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case profileKey = "profile_key"
        case home
        case holder
        case leasedAt = "leased_at"
        case profileDirectory = "profile_directory"
        case state
        case authWritten = "auth_written"
    }

    public init(
        leaseID: String = UUID().uuidString.lowercased(),
        profileKey: String,
        home: String,
        holder: String,
        leasedAt: Date = Date(),
        profileDirectory: String?,
        state: State = .active,
        authWritten: Bool = true
    ) {
        self.leaseID = leaseID
        self.profileKey = profileKey
        self.home = home
        self.holder = holder
        self.leasedAt = leasedAt
        self.profileDirectory = profileDirectory
        self.state = state
        self.authWritten = authWritten
    }

    /// Entries written before lease ids existed get a stable id and count as written.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileKey = try container.decode(String.self, forKey: .profileKey)
        home = try container.decode(String.self, forKey: .home)
        holder = try container.decode(String.self, forKey: .holder)
        leasedAt = try container.decode(Date.self, forKey: .leasedAt)
        profileDirectory = try container.decodeIfPresent(String.self, forKey: .profileDirectory)
        leaseID = try container.decodeIfPresent(String.self, forKey: .leaseID)
            ?? "legacy-" + CodexAccountHandle.digest(profileKey + "\u{0}" + home)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .active
        authWritten = try container.decodeIfPresent(Bool.self, forKey: .authWritten) ?? true
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
        guard !CodexFileProbe.isMissing(url) else { return [] }
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

    /// Fails when the cross-process lock cannot be taken within `timeout` seconds. The CLI takes
    /// this before any auth write.
    public static func withRequiredLock<T>(
        appSupportURL: URL,
        timeout: TimeInterval = 60,
        _ body: () throws -> T
    ) throws -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.depth == 0 {
            state.descriptor = try acquire(appSupportURL: appSupportURL, timeout: timeout)
        } else if state.descriptor < 0 {
            // Nested in a best-effort hold that never got the file lock.
            throw POSIXError(.ENOLCK)
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

    /// With no timeout it waits as long as the holder needs; every holder keeps it for one bounded
    /// read-modify-write.
    private static func acquire(appSupportURL: URL, timeout: TimeInterval? = nil) throws -> Int32 {
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
        guard let timeout else {
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return descriptor
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            let code = errno
            guard code == EAGAIN || code == EACCES || code == EINTR, Date() < deadline else {
                Darwin.close(descriptor)
                throw POSIXError(code == EAGAIN || code == EACCES ? .EBUSY : POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            usleep(50_000)
        }
        return descriptor
    }
}

/// Files a lease home's holder keeps beside its `auth.json`.
public enum CodexLeaseHome {
    /// A holder that refreshes its own token takes `flock(LOCK_EX)` on this file around each read,
    /// refresh and write-back of `auth.json`.
    public static let lockFileName = "auth.json.lock"
    /// Written by a holder that stopped after a credential refusal or a failed refresh: the home's
    /// token chain may be spent. Only the holder's owner removes it.
    public static let stoppedSentinelName = "auth.json.stopped"
    /// Held by a holder for its whole lifetime; a lane or director home has one once used.
    public static let holderLockFileName = "holder.lock"
    /// Marks the home as a Switchboard lease home: lease id, consumer and time, nothing else.
    public static let markerFileName = "lease.json"

    public static func stoppedSentinelURL(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(stoppedSentinelName)
    }

    public static func isQuarantined(home: String) -> Bool {
        FileManager.default.fileExists(atPath: stoppedSentinelURL(home: home).path)
    }

    /// True for a file that parses as JSON but holds no refresh token and is not a return's tombstone,
    /// such as a store emptied by a holder that moved its sign-in elsewhere.
    public static func holdsNoTokens(authURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: authURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root[CodexLeaseTombstone.key] == nil else {
            return false
        }
        let refreshToken = (root["tokens"] as? [String: Any])?["refresh_token"] as? String
        return refreshToken?.isEmpty ?? true
    }

    public static func quarantinedSince(home: String) -> Date? {
        let path = stoppedSentinelURL(home: home).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

public enum CodexHomeAuthLockError: LocalizedError {
    case busy(home: String)
    case unavailable(home: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .busy(home):
            return "Another process holds a lock in \(home)."
        case let .unavailable(home, code):
            return "Cannot lock a file in \(home): \(String(cString: strerror(code)))."
        }
    }
}

/// `flock` on lock files inside lease homes, shared with the processes that hold those homes. One
/// descriptor per home and file per process, reentrant, released at depth zero. Never `lockf`: a
/// process-owned lock is dropped by any close of that file in the process. Lock files are created
/// once and never deleted.
enum CodexHomeFileLock {
    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var held: [String: (descriptor: Int32, depth: Int)] = [:]
    }

    private static let state = State()

    /// Waits up to `timeout` seconds; zero tries once. A home directory that does not exist has no
    /// holder, so the body runs without the lock. One that cannot be checked, such as a home behind
    /// a directory this process cannot search, fails to lock instead.
    static func withLock<T>(
        home: String,
        fileName: String,
        timeout: TimeInterval,
        _ body: () throws -> T
    ) throws -> T {
        state.lock.lock()
        defer { state.lock.unlock() }
        let homePath = CodexLease.normalizedHome(home)
        let key = homePath + "/" + fileName
        if let entry = state.held[key] {
            state.held[key] = (entry.descriptor, entry.depth + 1)
            defer { release(key) }
            return try body()
        }
        if CodexFileProbe.isMissing(URL(fileURLWithPath: homePath, isDirectory: true)) {
            return try body()
        }
        state.held[key] = (try acquire(home: homePath, path: key, timeout: timeout), 1)
        defer { release(key) }
        return try body()
    }

    private static func release(_ key: String) {
        guard let entry = state.held[key] else { return }
        guard entry.depth <= 1 else {
            state.held[key] = (entry.descriptor, entry.depth - 1)
            return
        }
        _ = flock(entry.descriptor, LOCK_UN)
        Darwin.close(entry.descriptor)
        state.held[key] = nil
    }

    private static func acquire(home: String, path: String, timeout: TimeInterval) throws -> Int32 {
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CodexHomeAuthLockError.unavailable(home: home, code: errno)
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                Darwin.close(descriptor)
                throw CodexHomeAuthLockError.unavailable(home: home, code: code)
            }
            guard Date() < deadline else {
                Darwin.close(descriptor)
                throw CodexHomeAuthLockError.busy(home: home)
            }
            usleep(50_000)
        }
        return descriptor
    }
}

/// The short lock around one read-modify-write of a lease home's `auth.json`. A holder that
/// refreshes its own token takes it around each read, refresh and write-back, so Switchboard takes
/// it before it reads the file to keep its tokens, replaces it or tombstones it.
public enum CodexHomeAuthLock {
    public static func withLock<T>(home: String, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        try CodexHomeFileLock.withLock(home: home, fileName: CodexLeaseHome.lockFileName, timeout: timeout, body)
    }
}

/// The long lock a holder keeps for its whole lifetime. Switchboard takes it without waiting, so a
/// busy `holder.lock` means a run is live in the home, and keeps it for the whole operation.
public enum CodexHomeHolderLock {
    public static func withLock<T>(home: String, _ body: () throws -> T) throws -> T {
        try CodexHomeFileLock.withLock(home: home, fileName: CodexLeaseHome.holderLockFileName, timeout: 0, body)
    }

    /// Whether another process holds the home's `holder.lock` right now. Read-only: a home without
    /// the file has never had a holder.
    public static func isHeld(home: String) -> Bool {
        let path = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(CodexLeaseHome.holderLockFileName).path
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK
        }
        _ = flock(descriptor, LOCK_UN)
        return false
    }
}

public enum CodexLeaseSyncError: LocalizedError {
    case storedCopyUnreadable(path: String)

    /// No path: profile folders and keys can carry the account's email.
    public var errorDescription: String? {
        switch self {
        case .storedCopyUnreadable:
            return "A stored copy of the leased account cannot be read, so its token cannot be brought up to date."
        }
    }
}

/// An opaque name for an account in leasing output. Profile keys embed the account's email, so lease
/// commands print this instead, and `--profile-key` accepts it.
public enum CodexAccountHandle {
    public static func handle(for profileKey: String) -> String {
        "acct_" + digest(profileKey)
    }

    /// The profile key that `given` names: the key itself, or its handle.
    public static func resolve(_ given: String, among profileKeys: [String]) -> String? {
        if profileKeys.contains(given) {
            return given
        }
        guard given.hasPrefix("acct_") else { return nil }
        let matches = profileKeys.filter { handle(for: $0) == given }
        return matches.count == 1 ? matches[0] : nil
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// `<home>/lease.json`: marks a home as a Switchboard lease home. It holds only the lease id, the
/// consumer and the time; the lease journal maps the id to its account. Written first in a lease, so
/// a crash at any later point leaves a home that `return` recognises.
public struct CodexLeaseMarker: Codable, Equatable {
    public let version: Int
    public let leaseID: String
    public let consumer: String
    public let leasedAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case leaseID = "lease_id"
        case consumer
        case leasedAt = "leased_at"
    }

    public init(lease: CodexLease) {
        version = 1
        leaseID = lease.leaseID
        consumer = lease.holder
        leasedAt = lease.leasedAt
    }

    public static func url(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(CodexLeaseHome.markerFileName)
    }

    /// Nil when the home has no marker; throws when one exists and cannot be read.
    public static func read(home: String) throws -> CodexLeaseMarker? {
        let url = url(home: home)
        guard !CodexFileProbe.isMissing(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let marker = try? decoder.decode(CodexLeaseMarker.self, from: data) else {
            throw CodexLeaseStoreError.unreadable(path: url.path)
        }
        return marker
    }

    public func write(home: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexAtomicFile.write(encoder.encode(self), to: Self.url(home: home))
    }
}

/// What `return` leaves in a home's `auth.json` in place of the tokens: the lease id and the time, no
/// token. A holder that reads it finds no sign-in and stops; a repeated return recognises it.
public enum CodexLeaseTombstone {
    static let key = "switchboard_returned"

    public static func write(leaseID: String, to authURL: URL, at date: Date = Date()) throws {
        try CodexAtomicFile.writeJSON(
            [key: ["lease_id": leaseID, "returned_at": ISO8601DateFormatter().string(from: date)]],
            to: authURL
        )
    }

    /// The lease id of the tombstone at `authURL`, or nil when the file is not one.
    public static func leaseID(at authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[key] as? [String: Any] else {
            return nil
        }
        return entry["lease_id"] as? String
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
    /// The holder left `auth.json.stopped`: the home's chain may be spent. Nothing was written.
    case homeQuarantined = "home_quarantined"
    /// The home holds a return's tombstone, so there is nothing left to copy.
    case homeReturned = "home_returned"
}

/// Writes a lease home's current tokens back into Switchboard's stored copies of the leased account:
/// the captured profile copied at lease time, any other captured profile with the same key, and the
/// account list the app refreshes usage from. Callers hold `CodexAuthStoreLock` and the home's
/// `CodexHomeAuthLock`.
public enum CodexLeaseSync {
    public static func syncHome(_ lease: CodexLease, appSupportURL: URL) throws -> CodexLeaseSyncOutcome {
        guard !CodexLeaseHome.isQuarantined(home: lease.home) else {
            return .homeQuarantined
        }
        guard FileManager.default.fileExists(atPath: lease.authURL.path) else {
            return .homeAuthMissing
        }
        if CodexLeaseTombstone.leaseID(at: lease.authURL) != nil {
            return .homeReturned
        }
        guard let homeAuth = StoredAuth.load(from: lease.authURL), homeAuth.hasCompleteTokens else {
            return .homeAuthUnreadable
        }

        // Every stored copy must be readable, or one of them could keep a spent token after return.
        let stored = try storedProfiles(of: lease, identity: homeAuth.identity, appSupportURL: appSupportURL)
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
              let stored = try? storedProfiles(of: lease, identity: homeAuth.identity, appSupportURL: appSupportURL),
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

    private static func storedProfiles(
        of lease: CodexLease,
        identity: CodexAuthIdentity,
        appSupportURL: URL
    ) throws -> [StoredProfile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: appSupportURL.appendingPathComponent("profiles", isDirectory: true),
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
            let authURL = entry.appendingPathComponent("auth.json")
            let meta = readJSON(metaURL)
            if meta == nil, FileManager.default.fileExists(atPath: metaURL.path) {
                // Unreadable metadata hides whose copy this is. The copy lent from, or one holding
                // this account's auth, must not stay behind with a spent token.
                let holdsAccount = StoredAuth.load(from: authURL).map { identity.matches($0.identity) } ?? false
                if entry.lastPathComponent == lease.profileDirectory || holdsAccount {
                    throw CodexLeaseSyncError.storedCopyUnreadable(path: metaURL.path)
                }
                return nil
            }
            guard (meta?["source_profile_key"] as? String) == lease.profileKey else { return nil }
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
/// lease must not copy that token until the grant's rotation is stored. A reservation holds while
/// the app that made it still runs, and expires after `maxAge` once that app is gone (it died
/// mid-grant). Callers hold `CodexAuthStoreLock`.
public final class CodexRefreshReservations {
    public static let fileName = "refresh-reservations.json"
    public static let maxAge: TimeInterval = 60
    /// No grant takes this long, so a reservation this old belongs to a reused pid, not a live grant.
    static let maxHoldWhileRunning: TimeInterval = 600

    private struct Reservation: Codable {
        let since: TimeInterval
        let pid: Int32
    }

    private let url: URL

    public init(appSupportURL: URL) {
        url = appSupportURL.appendingPathComponent(Self.fileName)
    }

    /// Thrown by `reserve` while another process's grant for the account may still be in flight.
    public struct HeldElsewhere: Error {}

    /// One grant per account at a time: a second app must not send the same token while the first
    /// one's rotation is not stored yet.
    public func reserve(profileKey: String, pid: Int32 = Darwin.getpid(), now: Date = Date()) throws {
        var reservations = load()
        if let existing = reservations[profileKey], existing.pid != pid,
           Self.holds(existing, running: Self.isRunning(existing.pid), now: now) {
            throw HeldElsewhere()
        }
        reservations[profileKey] = Reservation(since: now.timeIntervalSince1970, pid: pid)
        try save(reservations)
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// A grant may still be in flight: the reservation is new, or its app still runs and no grant
    /// could take this long.
    private static func holds(_ reservation: Reservation, running: Bool, now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - reservation.since
        return age < maxAge || (running && age < maxHoldWhileRunning)
    }

    public func release(profileKey: String, pid: Int32 = Darwin.getpid()) throws {
        var reservations = load()
        guard reservations[profileKey]?.pid == pid else { return }
        reservations.removeValue(forKey: profileKey)
        try save(reservations)
    }

    /// `runningAppPIDs` are the Switchboard app processes alive now.
    public func isReserved(profileKey: String, runningAppPIDs: Set<Int32>, now: Date = Date()) -> Bool {
        guard let reservation = load()[profileKey] else { return false }
        return Self.holds(reservation, running: runningAppPIDs.contains(reservation.pid), now: now)
    }

    private func load() -> [String: Reservation] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Reservation].self, from: data)) ?? [:]
    }

    private func save(_ reservations: [String: Reservation]) throws {
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
    /// 2: the app also refuses to sign in to or remove a leased account. An app that records 1
    /// predates that and counts as not lease-aware.
    static let leaseSupport = 2

    public static func record(appSupportURL: URL, pid: Int32 = Darwin.getpid()) throws {
        try CodexAtomicFile.writeJSON(
            [
                "pid": Int(pid),
                "lease_support": leaseSupport,
                "started_at": ISO8601DateFormatter().string(from: Date()),
            ],
            to: appSupportURL.appendingPathComponent(fileName)
        )
    }

    public static func recordedPID(appSupportURL: URL) -> Int32? {
        guard let root = readJSON(appSupportURL.appendingPathComponent(fileName)),
              (root["lease_support"] as? Int ?? 0) >= leaseSupport,
              let pid = root["pid"] as? Int else {
            return nil
        }
        return Int32(pid)
    }

    public static func isReady(runningAppPIDs: [Int32], recordedPID: Int32?) -> Bool {
        runningAppPIDs.allSatisfy { $0 == recordedPID }
    }
}

/// The Application Support folder Switchboard keeps its data in. A side-by-side build names its own,
/// so it never reads or writes the default build's accounts.
public enum CodexStorageNamespace {
    public static let defaultName = "CodexSwitchboard"
    public static let environmentKey = "CODEX_SWITCHBOARD_STORAGE_NAMESPACE"

    /// The trimmed name, or nil when it is empty or is not a single folder name.
    public static func validated(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":") else {
            return nil
        }
        return trimmed
    }
}

public enum CodexFileProbe {
    /// True only when the file is known not to exist. A path that cannot be checked, such as one
    /// behind a directory this process cannot search, is not missing, so callers fail closed.
    public static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
}

/// Codex homes other than ~/.codex that a switch (the CLI's or the app's) or the app's token refresh wrote an
/// account into, so a lease can still see a chain there after the process that set CODEX_HOME is gone. Paths only,
/// no account. Callers hold `CodexAuthStoreLock`.
public enum CodexSwitchHomes {
    public static let fileName = "cli-homes.json"

    public struct Unreadable: Error {}

    /// The recorded homes; nil when the record exists but cannot be read.
    public static func load(appSupportURL: URL) -> [String]? {
        let url = appSupportURL.appendingPathComponent(fileName)
        if CodexFileProbe.isMissing(url) { return [] }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homes = root["homes"] as? [String] else { return nil }
        return homes
    }

    /// Throws `Unreadable`, and never overwrites the record, when it cannot be read, since that would drop the
    /// homes it lists. The default home is never recorded.
    public static func record(_ home: String, appSupportURL: URL, defaultHome: String) throws {
        guard !CodexLease.sameHome(home, defaultHome) else { return }
        guard var homes = load(appSupportURL: appSupportURL) else { throw Unreadable() }
        guard !homes.contains(where: { CodexLease.sameHome($0, home) }) else { return }
        homes.append(CodexLease.normalizedHome(home))
        try CodexAtomicFile.writeJSON(["version": 1, "homes": homes], to: appSupportURL.appendingPathComponent(fileName))
    }
}

public enum CodexAtomicFile {
    public static func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(data, to: url, permissions: permissions)
    }

    /// Writes durably: a new temporary file beside the destination, `F_FULLFSYNC`, a rename over the
    /// destination, then a sync of the folder. A process killed at any point leaves the old file or
    /// the new one; after a power loss the same holds as far as the drive honours the full sync.
    public static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tempPath = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let descriptor = Darwin.open(tempPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(permissions))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var renamed = false
        defer {
            if !renamed { unlink(tempPath) }
        }
        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            _ = fchmod(descriptor, mode_t(permissions))
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
        guard Darwin.rename(tempPath, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        let folder = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if folder >= 0 {
            if fcntl(folder, F_FULLFSYNC) != 0 { _ = fsync(folder) }
            Darwin.close(folder)
        }
    }
}
