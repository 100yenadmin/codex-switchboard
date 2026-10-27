import Foundation

struct AppLease: Decodable, Identifiable, Equatable {
    let handle: String
    let email: String
    let leaseID: String
    let state: String
    let plan: String?
    let sessionFreePercent: Double?
    let weeklyFreePercent: Double?
    let usableForCodex: Bool
    let needsRelogin: Bool
    let score: Double?
    let home: String
    let holder: String
    let leasedAt: Date
    let homeAuthPresent: Bool
    let homeMatchesStoredProfile: Bool
    let holderRunning: Bool
    let activeOnSurface: Bool
    let quarantined: Bool
    let quarantinedSince: Date?

    var id: String { leaseID }
    var displayName: String { email.isEmpty ? handle : email }

    enum CodingKeys: String, CodingKey {
        case handle, email, state, plan, score, home, holder, quarantined
        case leaseID = "lease_id", leasedAt = "leased_at", holderRunning = "holder_running"
        case sessionFreePercent = "session_free_percent", weeklyFreePercent = "weekly_free_percent"
        case usableForCodex = "usable_for_codex", needsRelogin = "needs_relogin"
        case homeAuthPresent = "home_auth_present", homeMatchesStoredProfile = "home_matches_stored_profile"
        case activeOnSurface = "active_on_surface", quarantinedSince = "quarantined_since"
    }
}

struct AppLeasesPayload: Decodable {
    let generatedAt: Date
    let leases: [AppLease]
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", leases }
}

struct AppLeaseAccount: Decodable, Identifiable, Equatable {
    let profileKey: String
    let handle: String
    let email: String
    let sessionFreePercent: Double
    let weeklyFreePercent: Double
    let quotaWindows: [AppLeaseQuotaWindow]?
    let leased: Bool
    let leaseHolder: String?
    let reserved: Bool
    let leasable: Bool

    var id: String { profileKey }
    var displayName: String { email.isEmpty ? handle : email }
    var swapMenuLabel: String {
        let windows = (quotaWindows ?? []).map {
            "\($0.window.displayLabel) \(String(format: "%.0f", $0.freePercent))% free"
        }
        return windows.isEmpty ? displayName : displayName + " · " + windows.joined(separator: " / ")
    }
    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key", handle, email, leased, reserved, leasable
        case sessionFreePercent = "session_free_percent", weeklyFreePercent = "weekly_free_percent"
        case leaseHolder = "lease_holder"
        case quotaWindows = "quota_windows"
    }
}

struct AppLeaseQuotaWindow: Decodable, Equatable {
    let kind: QuotaWindow.Kind
    let freePercent: Double
    let resetSeconds: Double
    let durationSeconds: Double?

    var window: QuotaWindow {
        QuotaWindow(kind: kind, usedPercent: 100 - freePercent, resetSeconds: resetSeconds, durationSeconds: durationSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case freePercent = "free_percent", resetSeconds = "reset_seconds", durationSeconds = "duration_seconds"
    }
}

struct AppLeaseStatusPayload: Decodable {
    let generatedAt: Date
    let accounts: [AppLeaseAccount]
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", accounts }
}

struct SwitchboardCLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All CLI entry points run in a separate process, keeping its recursive locks out of the app.
struct SwitchboardCLIClient: @unchecked Sendable {
    typealias Runner = (String, [String], [String: String], TimeInterval) throws -> TimedProcessRunner.Result
    static let missingCLIMessage = "Switchboard CLI not found in the app bundle"
    let executableURL: URL?
    private let storageRoot: () -> URL
    private let environment: [String: String]
    private let runner: Runner

    init(
        executableURL: URL? = SwitchboardCLIClient.findExecutable(),
        storageRoot: @escaping () -> URL = { AppStorage.rootURL },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping Runner = { path, args, env, timeout in
            try TimedProcessRunner.runResult(path, args, environment: env, timeout: timeout)
        }
    ) {
        self.executableURL = executableURL
        self.storageRoot = storageRoot
        self.environment = environment
        self.runner = runner
    }

    static func findExecutable(bundle: Bundle = .main, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> URL? {
        let bundled = bundle.url(forAuxiliaryExecutable: "codex-switchboard")
        if let bundled, isExecutable(bundled.path) { return bundled }
        let sibling = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("codex-switchboard")
        if let sibling, isExecutable(sibling.path) { return sibling }
        return nil
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }

    func leases() throws -> AppLeasesPayload { try read(AppLeasesPayload.self, arguments: ["leases", "--json"]) }
    func status() throws -> AppLeaseStatusPayload { try read(AppLeaseStatusPayload.self, arguments: ["status", "--json"]) }
    func returnLease(_ lease: AppLease) throws {
        let _: ActionReceipt = try read(ActionReceipt.self, arguments: ["return", "--profile-key", lease.handle, "--home", lease.home, "--expect-lease-id", lease.leaseID, "--json"])
    }
    func swapLease(_ lease: AppLease, to account: AppLeaseAccount) throws {
        let _: ActionReceipt = try read(ActionReceipt.self, arguments: ["swap-lease", "--home", lease.home, "--holder", lease.holder, "--profile-key", account.handle, "--expect-lease-id", lease.leaseID, "--json"])
    }

    private struct ActionReceipt: Decodable { let home: String }
    private struct ErrorReceipt: Decodable {
        let code: String?
        let error: String? // The current CLI encodes its error code under `error`.
        let message: String
    }
    private func read<T: Decodable>(_ type: T.Type, arguments: [String]) throws -> T {
        guard let executableURL else { throw SwitchboardCLIError(message: Self.missingCLIMessage) }
        var env = environment
        env["CODEX_SWITCHBOARD_APP_SUPPORT"] = storageRoot().path
        let result = try runner(executableURL.path, arguments, env, 90)
        if result.status != 0, let error = try? Self.decode(ErrorReceipt.self, from: result.stdout) {
            throw SwitchboardCLIError(message: error.message)
        }
        guard result.status == 0, let decoded = try? Self.decode(type, from: result.stdout) else {
            throw SwitchboardCLIError(message: "Switchboard CLI returned an unreadable response (exit \(result.status)).")
        }
        return decoded
    }
}
