import Darwin
import Foundation

public enum CodexSwitchboardCommand {
    public static func run(arguments: [String]) -> Int32 {
        let output = execute(arguments: arguments)
        if let stdout = output.stdout {
            print(stdout)
        }
        if let stderr = output.stderr {
            fputs("\(stderr)\n", Darwin.stderr)
        }
        return output.exitCode
    }

    /// Runs one command against the given environment and home without printing, for tests.
    static func execute(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CommandOutput {
        do {
            let runner = CommandRunner(arguments: arguments, environment: environment, homeURL: homeURL)
            let result = try runner.run()
            return Output.render(result.payload, json: result.json, exitCode: result.exitCode)
        } catch let error as CLIError {
            return Output.renderError(error, json: error.jsonPreferred)
        } catch let error as CodexLeaseStoreError {
            let refusal = CLIError.refused(
                code: "lease_store_unreadable",
                message: error.localizedDescription,
                details: nil
            )
            return Output.renderError(refusal, json: true)
        } catch {
            return Output.renderError(.failure(message: error.localizedDescription, jsonPreferred: true), json: true)
        }
    }
}

struct CommandOutput {
    let exitCode: Int32
    let stdout: String?
    let stderr: String?
}

private struct CommandResult {
    let payload: EncodablePayload
    let json: Bool
    let exitCode: Int32
}

private final class CommandRunner {
    private let arguments: [String]
    private let paths: SwitchboardPaths
    private let surfaceService: CLISurfaceService
    private let accountStore: CLIAccountStore
    private let switchService: CLISwitchService
    private let autoSwapPolicyStore: AutoSwapPolicyStore
    private let autoSwapAuditStore: AutoSwapAuditStore
    private let leaseService: CLILeaseService

    init(arguments: [String], environment: [String: String], homeURL: URL) {
        self.arguments = arguments
        paths = SwitchboardPaths(homeURL: homeURL, environment: environment)
        surfaceService = CLISurfaceService(paths: paths)
        accountStore = CLIAccountStore(paths: paths)
        switchService = CLISwitchService(paths: paths, surfaceService: surfaceService)
        autoSwapPolicyStore = AutoSwapPolicyStore(url: paths.autoSwapPolicyURL)
        autoSwapAuditStore = AutoSwapAuditStore(url: paths.autoSwapAuditURL)
        leaseService = CLILeaseService(paths: paths, surfaceService: surfaceService, accountStore: accountStore)
    }

    func run() throws -> CommandResult {
        guard let command = arguments.first else {
            throw CLIError.usage("Missing command. Use status, switch, lease, return, leases, or doctor.", jsonPreferred: false)
        }

        switch command {
        case "status":
            return try status(Array(arguments.dropFirst()))
        case "switch":
            return try switchProfile(Array(arguments.dropFirst()))
        case "lease":
            return try lease(Array(arguments.dropFirst()))
        case "return":
            return try returnLease(Array(arguments.dropFirst()))
        case "leases":
            return try leases(Array(arguments.dropFirst()))
        case "swap-lease":
            return try swapLease(Array(arguments.dropFirst()))
        case "doctor":
            return try doctor(Array(arguments.dropFirst()))
        case "autoswap":
            return try autoswap(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            return CommandResult(payload: .text(Self.helpText), json: false, exitCode: 0)
        default:
            throw CLIError.usage("Unknown command: \(command)", jsonPreferred: false)
        }
    }

    private func status(_ args: [String]) throws -> CommandResult {
        let options = try StatusOptions.parse(args)
        let surfaces = surfaceService.statuses(scope: options.surface)
        let accounts = leaseService.annotateLeasable(accountStore.accounts())
            .filter { !options.paidOnly || !$0.isFreePlan }
            .filter { !options.usableOnly || ($0.usableForCodex && !$0.leased) }
            .filter { !options.leasableOnly || $0.leasable }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.profileKey < rhs.profileKey
                }
                return lhs.score > rhs.score
            }
        let payload = StatusPayload(
            generatedAt: Date(),
            surfaces: surfaces,
            accounts: accounts
        )
        return CommandResult(payload: .status(payload), json: options.json, exitCode: 0)
    }

    private func switchProfile(_ args: [String]) throws -> CommandResult {
        let options = try SwitchOptions.parse(args)
        let outcome = try switchService.switchProfile(
            profileKey: options.profileKey,
            scope: options.surface,
            stopConsumers: options.stopConsumers
        )
        return CommandResult(payload: .switchOutcome(outcome), json: options.json, exitCode: 0)
    }

    private func lease(_ args: [String]) throws -> CommandResult {
        let options = try LeaseOptions.parse(args)
        let outcome = try leaseService.lease(
            profileKey: options.profileKey,
            home: options.home,
            holder: options.holder
        )
        return CommandResult(payload: .lease(outcome), json: options.json, exitCode: 0)
    }

    private func returnLease(_ args: [String]) throws -> CommandResult {
        let options = try ReturnOptions.parse(args)
        let outcome = try leaseService.returnLease(profileKey: options.profileKey, home: options.home)
        return CommandResult(payload: .leaseReturn(outcome), json: options.json, exitCode: 0)
    }

    private func swapLease(_ args: [String]) throws -> CommandResult {
        let options = try SwapLeaseOptions.parse(args)
        let outcome = try leaseService.swapLease(
            home: options.home,
            to: options.profileKey,
            excluding: options.excludedProfileKeys,
            holder: options.holder
        )
        return CommandResult(payload: .leaseSwap(outcome), json: options.json, exitCode: 0)
    }

    private func leases(_ args: [String]) throws -> CommandResult {
        let options = try DoctorOptions.parse(args)
        return CommandResult(payload: .leases(try leaseService.list()), json: options.json, exitCode: 0)
    }

    private func doctor(_ args: [String]) throws -> CommandResult {
        let options = try DoctorOptions.parse(args)
        let surfaces = surfaceService.statuses(scope: .all)
        let consumerProcesses = switchService.consumerProcesses()
        let unsupported = surfaces.filter { $0.detected && !$0.supportsFileSwitching }
        let payload = DoctorPayload(
            generatedAt: Date(),
            appSupportPath: paths.appSupportURL.path,
            profilesPath: paths.profilesURL.path,
            consumersRunning: !consumerProcesses.isEmpty,
            consumerCount: consumerProcesses.count,
            unsupportedSurfaces: unsupported.map(\.kind),
            surfaces: surfaces
        )
        return CommandResult(payload: .doctor(payload), json: options.json, exitCode: 0)
    }

    private func autoswap(_ args: [String]) throws -> CommandResult {
        guard let subcommand = args.first else {
            throw CLIError.usage("Missing autoswap command. Use status, enable, disable, or run-once.", jsonPreferred: false)
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "status":
            return try autoswapStatus(rest)
        case "enable":
            return try autoswapSetEnabled(rest, enabled: true)
        case "disable":
            return try autoswapSetEnabled(rest, enabled: false)
        case "run-once":
            return try autoswapRunOnce(rest)
        default:
            throw CLIError.usage("Unknown autoswap command: \(subcommand)", jsonPreferred: false)
        }
    }

    private func autoswapStatus(_ args: [String]) throws -> CommandResult {
        let options = try AutoSwapStatusOptions.parse(args)
        let policy = autoSwapPolicyStore.load()
        let decisions = autoswapDecisions(policy: policy, scope: options.surface)
        let payload = AutoSwapStatusPayload(
            generatedAt: Date(),
            policy: policy,
            recentEvents: Array(autoSwapAuditStore.load().suffix(10)),
            decisions: decisions
        )
        return CommandResult(payload: .autoSwapStatus(payload), json: options.json, exitCode: 0)
    }

    private func autoswapSetEnabled(_ args: [String], enabled: Bool) throws -> CommandResult {
        let options = try AutoSwapToggleOptions.parse(args)
        var policy = autoSwapPolicyStore.load()
        for surface in options.surface.surfaceKinds {
            policy.setEnabled(enabled, for: surface.autoSwapKind)
        }
        options.apply(to: &policy)
        try autoSwapPolicyStore.save(policy)
        let decisions = autoswapDecisions(policy: policy, scope: options.surface)
        let payload = AutoSwapStatusPayload(
            generatedAt: Date(),
            policy: policy,
            recentEvents: Array(autoSwapAuditStore.load().suffix(10)),
            decisions: decisions
        )
        return CommandResult(payload: .autoSwapStatus(payload), json: options.json, exitCode: 0)
    }

    private func autoswapRunOnce(_ args: [String]) throws -> CommandResult {
        let options = try AutoSwapRunOptions.parse(args)
        let policy = autoSwapPolicyStore.load()
        let surfaces = surfaceService.statuses(scope: options.surface)
        let accounts = accountStore.accounts()
        let history = autoSwapAuditStore.load()
        let allConsumers = switchService.consumerProcesses()
        let stopConsumers = options.stopConsumers
        var decisions: [AutoSwapDecision] = []
        var switches: [AutoSwapSwitchPayload] = []
        var switchedAuthStores = Set<String>()

        for surface in surfaces {
            let planned = AutoSwapDecisionEngine.evaluate(
                policy: policy,
                surface: surface.autoSwapSurface,
                accounts: accounts.map(\.autoSwapAccount),
                history: history
            )
            guard planned.decision == .wouldSwitch,
                  let candidate = planned.candidateProfileKey else {
                decisions.append(planned)
                continue
            }
            guard options.dryRun == false else {
                decisions.append(planned)
                continue
            }
            let consumers = switchService.consumerProcesses(for: [surface])
            if !consumers.isEmpty && !stopConsumers {
                let blocked = AutoSwapDecision(
                    generatedAt: Date(),
                    surface: planned.surface,
                    decision: .blocked,
                    reason: .consumersRunning,
                    activeProfileKey: planned.activeProfileKey,
                    candidateProfileKey: planned.candidateProfileKey,
                    triggerSessionFreePercent: planned.triggerSessionFreePercent,
                    triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
                    targetMinSessionFreePercent: planned.targetMinSessionFreePercent
                )
                decisions.append(blocked)
                continue
            }
            let authStoreKey = surface.authStorePath.isEmpty ? surface.kind.rawValue : surface.authStorePath
            if switchedAuthStores.contains(authStoreKey) {
                let switched = switchedDecision(from: planned)
                try recordSwitch(switched)
                decisions.append(switched)
                continue
            }
            let outcome = try switchService.switchProfile(
                profileKey: candidate,
                surfaces: [surface],
                stopConsumers: stopConsumers
            )
            switchedAuthStores.insert(authStoreKey)
            switches.append(AutoSwapSwitchPayload(outcome: outcome))
            let switched = switchedDecision(from: planned)
            try recordSwitch(switched)
            decisions.append(switched)
        }

        let payload = AutoSwapRunPayload(
            generatedAt: Date(),
            policy: policy,
            dryRun: options.dryRun,
            consumerCount: allConsumers.count,
            decisions: decisions,
            switches: switches
        )
        return CommandResult(payload: .autoSwapRun(payload), json: options.json, exitCode: 0)
    }

    private func switchedDecision(from planned: AutoSwapDecision) -> AutoSwapDecision {
        AutoSwapDecision(
            generatedAt: Date(),
            surface: planned.surface,
            decision: .switched,
            reason: .switched,
            activeProfileKey: planned.activeProfileKey,
            candidateProfileKey: planned.candidateProfileKey,
            triggerSessionFreePercent: planned.triggerSessionFreePercent,
            triggerWeeklyFreePercent: planned.triggerWeeklyFreePercent,
            targetMinSessionFreePercent: planned.targetMinSessionFreePercent
        )
    }

    private func recordSwitch(_ switched: AutoSwapDecision) throws {
        try autoSwapAuditStore.record(AutoSwapAuditEvent(
            generatedAt: switched.generatedAt,
            surface: switched.surface,
            decision: switched.decision,
            reason: .thresholdReached,
            fromProfileKey: switched.activeProfileKey,
            toProfileKey: switched.candidateProfileKey
        ))
    }

    private func autoswapDecisions(policy: AutoSwapPolicy, scope: SurfaceScope) -> [AutoSwapDecision] {
        let accounts = accountStore.accounts().map(\.autoSwapAccount)
        let history = autoSwapAuditStore.load()
        return surfaceService.statuses(scope: scope).map { surface in
            AutoSwapDecisionEngine.evaluate(
                policy: policy,
                surface: surface.autoSwapSurface,
                accounts: accounts,
                history: history
            )
        }
    }

    private static let helpText = """
    codex-switchboard status --json [--surface all|desktop|cli] [--paid-only] [--usable-only] [--leasable-only]
    codex-switchboard switch --profile-key <key> --surface desktop|cli|both --json [--stop-consumers]
    codex-switchboard lease --profile-key <key> --home <dir> --holder <name> --json
    codex-switchboard return --profile-key <key> --home <dir> --json
    codex-switchboard leases --json
    codex-switchboard swap-lease --home <dir> [--profile-key <key>] [--exclude-profile-key <key>]... [--holder <name>] --json
    codex-switchboard autoswap status --json [--surface all|desktop|cli]
    codex-switchboard autoswap enable --surface cli|desktop|both --json [--trigger-session-free <percent>] [--target-min-session-free <percent>]
    codex-switchboard autoswap disable --surface cli|desktop|both --json
    codex-switchboard autoswap run-once --surface cli|desktop|both --json [--dry-run] [--stop-consumers]
    codex-switchboard doctor --json
    """
}

private enum SurfaceScope: String, Codable {
    case all
    case desktop
    case cli
    case both

    var surfaceKinds: [SurfaceKind] {
        switch self {
        case .all: return [.desktop, .cli]
        case .both: return [.desktop, .cli]
        case .desktop: return [.desktop]
        case .cli: return [.cli]
        }
    }

    init(_ surface: SurfaceKind) {
        switch surface {
        case .desktop:
            self = .desktop
        case .cli:
            self = .cli
        }
    }
}

private enum SurfaceKind: String, Codable, Hashable {
    case desktop
    case cli

    var displayName: String {
        switch self {
        case .desktop: return "Codex Desktop"
        case .cli: return "Codex CLI"
        }
    }

    var autoSwapKind: AutoSwapSurfaceKind {
        switch self {
        case .desktop: return .desktop
        case .cli: return .cli
        }
    }
}

private struct StatusOptions {
    let json: Bool
    let surface: SurfaceScope
    let paidOnly: Bool
    let usableOnly: Bool
    let leasableOnly: Bool

    static func parse(_ args: [String]) throws -> StatusOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let paidOnly = parser.takeFlag("--paid-only")
        let usableOnly = parser.takeFlag("--usable-only")
        let leasableOnly = parser.takeFlag("--leasable-only")
        let surface = try parser.takeSurface(default: .all, allowed: [.all, .desktop, .cli])
        try parser.finish()
        return StatusOptions(
            json: json,
            surface: surface,
            paidOnly: paidOnly,
            usableOnly: usableOnly,
            leasableOnly: leasableOnly
        )
    }
}

private struct SwapLeaseOptions {
    let json: Bool
    let home: String
    let profileKey: String?
    let excludedProfileKeys: Set<String>
    let holder: String?

    static func parse(_ args: [String]) throws -> SwapLeaseOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let home = try parser.takeRequiredValue("--home")
        let profileKey = parser.takeOptionalValue("--profile-key")
        let excluded = try parser.takeAllValues("--exclude-profile-key")
        let holder = parser.takeOptionalValue("--holder")?.trimmingCharacters(in: .whitespacesAndNewlines)
        try parser.finish()
        if profileKey?.isEmpty == true {
            throw CLIError.usage("Missing value for --profile-key.", jsonPreferred: false)
        }
        if let holder, holder.isEmpty || holder.count > 200 {
            throw CLIError.usage("--holder must be 1 to 200 characters.", jsonPreferred: false)
        }
        return SwapLeaseOptions(
            json: json,
            home: home,
            profileKey: profileKey,
            excludedProfileKeys: Set(excluded),
            holder: holder
        )
    }
}

private struct SwitchOptions {
    let json: Bool
    let profileKey: String
    let surface: SurfaceScope
    let stopConsumers: Bool

    static func parse(_ args: [String]) throws -> SwitchOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let stopConsumers = parser.takeFlag("--stop-consumers")
        let profileKey = try parser.takeRequiredValue("--profile-key")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return SwitchOptions(
            json: json,
            profileKey: profileKey,
            surface: surface,
            stopConsumers: stopConsumers
        )
    }
}

private struct LeaseOptions {
    let json: Bool
    let profileKey: String
    let home: String
    let holder: String

    static func parse(_ args: [String]) throws -> LeaseOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let profileKey = try parser.takeRequiredValue("--profile-key")
        let home = try parser.takeRequiredValue("--home")
        let holder = try parser.takeRequiredValue("--holder")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try parser.finish()
        guard !holder.isEmpty, holder.count <= 200 else {
            throw CLIError.usage("--holder must be 1 to 200 characters.", jsonPreferred: false)
        }
        return LeaseOptions(json: json, profileKey: profileKey, home: home, holder: holder)
    }
}

private struct ReturnOptions {
    let json: Bool
    let profileKey: String
    let home: String

    static func parse(_ args: [String]) throws -> ReturnOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let profileKey = try parser.takeRequiredValue("--profile-key")
        let home = try parser.takeRequiredValue("--home")
        try parser.finish()
        return ReturnOptions(json: json, profileKey: profileKey, home: home)
    }
}

private struct DoctorOptions {
    let json: Bool

    static func parse(_ args: [String]) throws -> DoctorOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        try parser.finish()
        return DoctorOptions(json: json)
    }
}

private struct AutoSwapStatusOptions {
    let json: Bool
    let surface: SurfaceScope

    static func parse(_ args: [String]) throws -> AutoSwapStatusOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let surface = try parser.takeSurface(default: .all, allowed: [.all, .desktop, .cli])
        try parser.finish()
        return AutoSwapStatusOptions(json: json, surface: surface)
    }
}

private struct AutoSwapToggleOptions {
    let json: Bool
    let surface: SurfaceScope
    let triggerSessionFreePercent: Double?
    let triggerWeeklyFreePercent: Double?
    let targetMinSessionFreePercent: Double?
    let cooldownSeconds: Double?
    let maxSwitchesPerHour: Int?

    static func parse(_ args: [String]) throws -> AutoSwapToggleOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let triggerSessionFreePercent = try parser.takeOptionalDouble("--trigger-session-free")
        let triggerWeeklyFreePercent = try parser.takeOptionalDouble("--trigger-weekly-free")
        let targetMinSessionFreePercent = try parser.takeOptionalDouble("--target-min-session-free")
        let cooldownSeconds = try parser.takeOptionalDouble("--cooldown-seconds")
        let maxSwitchesPerHour = try parser.takeOptionalInt("--max-switches-per-hour")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return AutoSwapToggleOptions(
            json: json,
            surface: surface,
            triggerSessionFreePercent: triggerSessionFreePercent,
            triggerWeeklyFreePercent: triggerWeeklyFreePercent,
            targetMinSessionFreePercent: targetMinSessionFreePercent,
            cooldownSeconds: cooldownSeconds,
            maxSwitchesPerHour: maxSwitchesPerHour
        )
    }

    func apply(to policy: inout AutoSwapPolicy) {
        if let triggerSessionFreePercent {
            policy.triggerSessionFreePercent = max(0, min(100, triggerSessionFreePercent))
        }
        if let triggerWeeklyFreePercent {
            policy.triggerWeeklyFreePercent = max(0, min(100, triggerWeeklyFreePercent))
        }
        if let targetMinSessionFreePercent {
            policy.targetMinSessionFreePercent = max(0, min(100, targetMinSessionFreePercent))
        }
        if let cooldownSeconds {
            policy.cooldownSeconds = max(0, cooldownSeconds)
        }
        if let maxSwitchesPerHour {
            policy.maxSwitchesPerHour = max(1, maxSwitchesPerHour)
        }
    }
}

private struct AutoSwapRunOptions {
    let json: Bool
    let surface: SurfaceScope
    let dryRun: Bool
    let stopConsumers: Bool

    static func parse(_ args: [String]) throws -> AutoSwapRunOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let dryRun = parser.takeFlag("--dry-run")
        let stopConsumers = parser.takeFlag("--stop-consumers")
        let surface = try parser.takeSurface(default: nil, allowed: [.desktop, .cli, .both])
        try parser.finish()
        return AutoSwapRunOptions(json: json, surface: surface, dryRun: dryRun, stopConsumers: stopConsumers)
    }
}

private struct ArgumentParser {
    private var args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    mutating func takeFlag(_ flag: String) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    mutating func takeRequiredValue(_ flag: String) throws -> String {
        guard let value = takeOptionalValue(flag), !value.isEmpty else {
            throw CLIError.usage("Missing required \(flag).", jsonPreferred: false)
        }
        return value
    }

    mutating func takeOptionalValue(_ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        args.remove(at: index)
        guard index < args.count else { return "" }
        return args.remove(at: index)
    }

    mutating func takeAllValues(_ flag: String) throws -> [String] {
        var values: [String] = []
        while let value = takeOptionalValue(flag) {
            guard !value.isEmpty else {
                throw CLIError.usage("Missing value for \(flag).", jsonPreferred: false)
            }
            values.append(value)
        }
        return values
    }

    mutating func takeOptionalDouble(_ flag: String) throws -> Double? {
        guard let raw = takeOptionalValue(flag) else { return nil }
        guard let value = Double(raw) else {
            throw CLIError.usage("Invalid \(flag) \(raw). Expected a number.", jsonPreferred: false)
        }
        return value
    }

    mutating func takeOptionalInt(_ flag: String) throws -> Int? {
        guard let raw = takeOptionalValue(flag) else { return nil }
        guard let value = Int(raw) else {
            throw CLIError.usage("Invalid \(flag) \(raw). Expected an integer.", jsonPreferred: false)
        }
        return value
    }

    mutating func takeSurface(default defaultSurface: SurfaceScope?, allowed: Set<SurfaceScope>) throws -> SurfaceScope {
        guard let raw = takeOptionalValue("--surface") else {
            if let defaultSurface { return defaultSurface }
            throw CLIError.usage("Missing required --surface.", jsonPreferred: false)
        }
        guard let surface = SurfaceScope(rawValue: raw), allowed.contains(surface) else {
            let values = allowed.map(\.rawValue).sorted().joined(separator: "|")
            throw CLIError.usage("Invalid --surface \(raw). Expected \(values).", jsonPreferred: false)
        }
        return surface
    }

    func finish() throws {
        guard args.isEmpty else {
            throw CLIError.usage("Unexpected arguments: \(args.joined(separator: " "))", jsonPreferred: false)
        }
    }
}

private struct SwitchboardPaths {
    let fileManager = FileManager.default
    let homeURL: URL
    let environment: [String: String]
    let appSupportURL: URL
    let profilesURL: URL
    let backupsURL: URL
    let accountsURL: URL
    let snapshotURL: URL
    let autoSwapPolicyURL: URL
    let autoSwapAuditURL: URL
    let leaseStore: CodexLeaseStore

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeURL = homeURL
        self.environment = environment
        if let override = environment["CODEX_SWITCHBOARD_APP_SUPPORT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appSupportURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexSwitchboard", isDirectory: true)
        }
        profilesURL = appSupportURL.appendingPathComponent("profiles", isDirectory: true)
        backupsURL = appSupportURL.appendingPathComponent("backups", isDirectory: true)
        accountsURL = appSupportURL.appendingPathComponent("accounts.json")
        snapshotURL = appSupportURL.appendingPathComponent("accounts-snapshot.json")
        autoSwapPolicyURL = appSupportURL.appendingPathComponent("auto-swap-policy.json")
        autoSwapAuditURL = appSupportURL.appendingPathComponent("auto-swap-events.json")
        leaseStore = CodexLeaseStore(appSupportURL: appSupportURL)
    }

    /// Whether this storage is one a Switchboard app could be using, as opposed to a test or scratch copy.
    var isAppStorage: Bool {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CodexLease.homeSpellings(appSupportURL.path).contains { spelling in
            CodexLease.homeSpellings(applicationSupport.path).contains { spelling.hasPrefix($0 + "/") }
        }
    }

    func codexHome(for kind: SurfaceKind) -> URL {
        switch kind {
        case .desktop:
            return homeURL.appendingPathComponent(".codex", isDirectory: true)
        case .cli:
            if let value = environment["CODEX_HOME"],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return URL(fileURLWithPath: value)
            }
            return homeURL.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    func ensureDirectory(_ url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeData(data, to: url, permissions: permissions)
    }

    func writeData(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
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

private final class CLISurfaceService {
    private let paths: SwitchboardPaths
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths) {
        self.paths = paths
    }

    func statuses(scope: SurfaceScope) -> [SurfaceStatusPayload] {
        let raw = scope.surfaceKinds.map(status)
        return annotateSharedStores(raw)
    }

    func status(for kind: SurfaceKind) -> SurfaceStatusPayload {
        let codexHome = paths.codexHome(for: kind)
        let authURL = codexHome.appendingPathComponent("auth.json")
        let activeAuth = StoredAuth.load(from: authURL)
        let match = activeAuth.flatMap { CapturedProfileStore(paths: paths).profileMatching(auth: $0) }
        let mode = authStoreMode(in: codexHome, for: kind)
        return SurfaceStatusPayload(
            kind: kind,
            displayName: kind.displayName,
            detected: detected(kind),
            running: running(kind),
            authStorePath: authURL.path,
            authStoreMode: mode,
            supportsFileSwitching: mode == "file",
            activeProfileKey: match?.sourceProfileKey,
            activeEmail: match?.email ?? activeAuth?.email,
            activeAccountID: match?.accountID ?? activeAuth?.accountID,
            sharedAuthStore: false,
            sharedWith: nil
        )
    }

    private func annotateSharedStores(_ statuses: [SurfaceStatusPayload]) -> [SurfaceStatusPayload] {
        statuses.map { status in
            var status = status
            let shared = statuses.first {
                $0.kind != status.kind
                    && $0.authStorePath == status.authStorePath
                    && !$0.authStorePath.isEmpty
            }
            status.sharedAuthStore = shared != nil
            status.sharedWith = shared?.kind
            return status
        }
    }

    private func detected(_ kind: SurfaceKind) -> Bool {
        switch kind {
        case .desktop:
            return codexDesktopAppPaths
                .contains { isCodexDesktopApp(atPath: $0) } || running(.desktop)
        case .cli:
            return cliExecutablePath() != nil
        }
    }

    private func running(_ kind: SurfaceKind) -> Bool {
        let lines = processLines()
        switch kind {
        case .desktop:
            return lines.contains { isCodexDesktopProcessCommand($0.lowercased()) }
        case .cli:
            return lines.contains { isCodexExecutableCommand($0.lowercased()) }
        }
    }

    private func cliExecutablePath() -> String? {
        let envPath = paths.environment["PATH"] ?? ""
        let candidates = envPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
        } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(paths.homeURL.path)/.local/bin/codex",
            "\(paths.homeURL.path)/.openclaw/bin/codex",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func authStoreMode(in codexHome: URL, for kind: SurfaceKind) -> String {
        let config = try? String(
            contentsOf: codexHome.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        return CodexCredentialStoreMode.resolve(config: config, surface: kind.autoSwapKind)
    }
}

private final class CLIAccountStore {
    private let paths: SwitchboardPaths
    private let capturedProfiles: CapturedProfileStore

    init(paths: SwitchboardPaths) {
        self.paths = paths
        capturedProfiles = CapturedProfileStore(paths: paths)
    }

    /// Status stays readable when the lease store is not; every writer re-reads it and fails closed.
    func accounts() -> [AccountPayload] {
        let leases = (try? paths.leaseStore.load()) ?? []
        let snapshot = snapshotAccounts() ?? []
        return (snapshot.isEmpty ? profileFallbackAccounts() : snapshot).map { account in
            var account = account
            if let lease = leases.first(where: { $0.profileKey == account.profileKey }) {
                account.leased = true
                account.leaseHolder = lease.holder
            }
            return account
        }
    }

    private func snapshotAccounts() -> [AccountPayload]? {
        guard let data = try? Data(contentsOf: paths.snapshotURL),
              let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data) else {
            return nil
        }
        let snapshotRefreshDate = snapshot.lastRefreshEpoch.map {
            Date(timeIntervalSince1970: $0)
        } ?? Date()
        return snapshot.accounts.compactMap { account in
            guard let profileKey = account.profileKey else { return nil }
            return AccountPayload(
                snapshot: account,
                snapshotRefreshDate: snapshotRefreshDate,
                hasCapturedAuth: capturedProfiles.hasProfile(sourceProfileKey: profileKey)
            )
        }
    }

    private func profileFallbackAccounts() -> [AccountPayload] {
        let collection = LocalProfileCollection.load(from: paths.accountsURL)
        return collection.orderedKeys.compactMap { key in
            guard let entry = collection.profiles[key] else { return nil }
            let email = entry["email"] as? String
                ?? entry["accountId"] as? String
                ?? key.components(separatedBy: ":").last
                ?? key
            return AccountPayload(
                profileKey: key,
                email: email,
                workspace: "?",
                plan: "?",
                sessionFreePercent: 0,
                weeklyFreePercent: 0,
                usableForCodex: false,
                needsRelogin: false,
                nextResetAt: nil,
                isFreePlan: false,
                score: 0
            )
        }
    }
}

private final class CLISwitchService {
    private let paths: SwitchboardPaths
    private let surfaceService: CLISurfaceService
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths, surfaceService: CLISurfaceService) {
        self.paths = paths
        self.surfaceService = surfaceService
    }

    func switchProfile(profileKey: String, scope: SurfaceScope, stopConsumers: Bool) throws -> SwitchPayload {
        try switchProfile(
            profileKey: profileKey,
            surfaces: surfaceService.statuses(scope: scope),
            stopConsumers: stopConsumers
        )
    }

    func switchProfile(
        profileKey: String,
        surfaces: [SurfaceStatusPayload],
        stopConsumers: Bool
    ) throws -> SwitchPayload {
        try ensureSwitchable(profileKey: profileKey, surfaces: surfaces)
        let profileStore = CapturedProfileStore(paths: paths)
        let profile = try profileStore.profile(sourceProfileKey: profileKey)
        try validateCapturedProfile(profile)

        let undetected = surfaces.filter { !$0.detected }
        if let firstUndetected = undetected.first {
            throw CLIError.surfaceNotDetected(
                surface: firstUndetected.kind.rawValue,
                jsonPreferred: true
            )
        }
        let unsupported = surfaces.filter { !$0.supportsFileSwitching }
        if let firstUnsupported = unsupported.first {
            throw CLIError.unsupportedMode(
                surface: firstUnsupported.kind.rawValue,
                mode: firstUnsupported.authStoreMode,
                path: firstUnsupported.authStorePath,
                jsonPreferred: true
            )
        }

        let consumers = consumerProcesses(for: surfaces)
        if !consumers.isEmpty {
            guard stopConsumers else {
                throw CLIError.consumersRunning(consumers.map(\.description), jsonPreferred: true)
            }
            terminate(consumers, for: surfaces)
        }

        var written: [SwitchSurfacePayload] = []
        var destinations: [(surface: SurfaceStatusPayload, url: URL)] = []
        var seenDestinations = Set<String>()
        for surface in surfaces {
            let destination = URL(fileURLWithPath: surface.authStorePath)
            guard !seenDestinations.contains(destination.path) else {
                written.append(SwitchSurfacePayload(
                    kind: surface.kind,
                    authStorePath: destination.path,
                    authStoreMode: surface.authStoreMode,
                    sharedAuthStore: true
                ))
                continue
            }
            seenDestinations.insert(destination.path)
            destinations.append((surface, destination))
        }

        try CodexAuthStoreLock.withRequiredLock(appSupportURL: paths.appSupportURL) {
            // A lease taken while consumers were being checked must still win.
            try ensureSwitchable(profileKey: profileKey, surfaces: surfaces)
            let sourceData = try Data(contentsOf: profile.authURL)
            let previousAuth = destinations.reduce(into: [String: Data?]()) { result, destination in
                result[destination.url.path] = try? Data(contentsOf: destination.url)
            }
            var mutatedDestinations: [URL] = []
            do {
                for (surface, destination) in destinations {
                    try backupLiveAuth(at: destination, target: profile)
                    try paths.writeData(sourceData, to: destination, permissions: 0o600)
                    mutatedDestinations.append(destination)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    written.append(SwitchSurfacePayload(
                        kind: surface.kind,
                        authStorePath: destination.path,
                        authStoreMode: surface.authStoreMode,
                        sharedAuthStore: surface.sharedAuthStore
                    ))
                }
            } catch {
                rollback(destinations: mutatedDestinations, previousAuth: previousAuth)
                throw error
            }
        }

        for surface in surfaces {
            let destination = URL(fileURLWithPath: surface.authStorePath)
            guard seenDestinations.contains(destination.path),
                  destinations.contains(where: { $0.url.path == destination.path }) else {
                continue
            }
            if written.contains(where: { $0.kind == surface.kind }) {
                continue
            }
            written.append(SwitchSurfacePayload(
                kind: surface.kind,
                authStorePath: destination.path,
                authStoreMode: surface.authStoreMode,
                sharedAuthStore: surface.sharedAuthStore
            ))
        }

        return SwitchPayload(
            generatedAt: Date(),
            profileKey: profile.sourceProfileKey,
            email: profile.email,
            accountID: profile.accountID,
            surfaces: written
        )
    }

    /// A leased account has exactly one live holder, its lease home, and a lease home is never a switch target.
    private func ensureSwitchable(profileKey: String, surfaces: [SurfaceStatusPayload]) throws {
        let leases = try paths.leaseStore.load()
        if let lease = leases.first(where: { $0.profileKey == profileKey }) {
            throw CLIError.refused(
                code: "account_leased",
                message: "profile_key \(profileKey) is leased to \(lease.holder); return the lease before switching to it.",
                details: nil
            )
        }
        for surface in surfaces {
            let surfaceHome = URL(fileURLWithPath: surface.authStorePath).deletingLastPathComponent().path
            if let lease = leases.first(where: { CodexLease.sameHome($0.home, surfaceHome) }) {
                throw CLIError.refused(
                    code: "surface_is_lease_home",
                    message: "The \(surface.kind.rawValue) auth store is the lease home of \(lease.holder); unset CODEX_HOME or return that lease first.",
                    details: nil
                )
            }
        }
    }

    private func rollback(destinations: [URL], previousAuth: [String: Data?]) {
        for destination in destinations.reversed() {
            if let previous = previousAuth[destination.path] ?? nil {
                try? paths.writeData(previous, to: destination, permissions: 0o600)
            } else {
                try? fileManager.removeItem(at: destination)
            }
        }
    }

    func consumerProcesses() -> [ProcessInfoPayload] {
        let currentPID = Darwin.getpid()
        return processLinesWithPID().compactMap { pid, command in
            guard pid != currentPID else { return nil }
            guard isCodexConsumerCommand(command.lowercased()) else { return nil }
            return ProcessInfoPayload(pid: pid, command: command)
        }
    }

    func consumerProcesses(for surfaces: [SurfaceStatusPayload]) -> [ProcessInfoPayload] {
        let targetKinds = consumerTargetKinds(for: surfaces)
        let currentPID = Darwin.getpid()
        return processLinesWithPID().compactMap { pid, command in
            guard pid != currentPID else { return nil }
            guard isCodexConsumerCommand(command.lowercased(), for: targetKinds) else { return nil }
            return ProcessInfoPayload(pid: pid, command: command)
        }
    }

    private func consumerTargetKinds(for surfaces: [SurfaceStatusPayload]) -> Set<SurfaceKind> {
        surfaces.reduce(into: Set<SurfaceKind>()) { result, surface in
            let sharedWith = surface.sharedAuthStore ? surface.sharedWith?.autoSwapKind : nil
            let kinds = AutoSwapSurfaceTopology.consumerKinds(
                for: surface.kind.autoSwapKind,
                sharedWith: sharedWith
            )
            if kinds.contains(.desktop) { result.insert(.desktop) }
            if kinds.contains(.cli) { result.insert(.cli) }
        }
    }

    private func validateCapturedProfile(_ profile: CapturedProfile) throws {
        guard let auth = StoredAuth.load(from: profile.authURL),
              auth.hasCompleteTokens,
              auth.email.isEmpty || profile.email.isEmpty || auth.email == profile.email,
              auth.accountID.isEmpty || profile.accountID.isEmpty || auth.accountID == profile.accountID else {
            throw CLIError.failure(message: "Captured profile is missing valid redacted identity fields.", jsonPreferred: true)
        }
    }

    private func terminate(_ consumers: [ProcessInfoPayload], for surfaces: [SurfaceStatusPayload]) {
        let pids = consumers.map(\.pid)
        _ = try? run("/bin/kill", ["-TERM"] + pids.map(String.init), timeout: 3)
        if waitForConsumersToExit(for: surfaces, timeout: 3) {
            return
        }
        let remaining = consumerProcesses(for: surfaces).map(\.pid)
        guard !remaining.isEmpty else { return }
        _ = try? run("/bin/kill", ["-KILL"] + remaining.map(String.init), timeout: 3)
        _ = waitForConsumersToExit(for: surfaces, timeout: 2)
    }

    private func waitForConsumersToExit(for surfaces: [SurfaceStatusPayload], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if consumerProcesses(for: surfaces).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return consumerProcesses(for: surfaces).isEmpty
    }

    private func backupLiveAuth(at authURL: URL, target: CapturedProfile) throws {
        guard fileManager.fileExists(atPath: authURL.path) else { return }
        let timestamp = DateFormatter.cliBackup.string(from: Date())
        let backupURL = paths.backupsURL
            .appendingPathComponent("\(timestamp)-cli-switch", isDirectory: true)
        try paths.ensureDirectory(backupURL, permissions: 0o700)
        let safeAuthName = authURL.path
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let backupAuthURL = backupURL.appendingPathComponent("\(safeAuthName)-auth.json")
        try fileManager.copyItem(at: authURL, to: backupAuthURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupAuthURL.path)
        try paths.writeJSON(
            [
                "target_email": target.email,
                "target_account_id": target.accountID,
                "target_source_profile_key": target.sourceProfileKey,
                "destination_auth_store": authURL.path,
                "created_at": ISO8601DateFormatter.cli.string(from: Date()),
                "reason": "cli-switch",
            ],
            to: backupURL.appendingPathComponent("\(safeAuthName)-metadata.json"),
            permissions: 0o600
        )
    }

    private func copyReplacing(source: URL, destination: URL) throws {
        let data = try Data(contentsOf: source)
        try paths.writeData(data, to: destination, permissions: 0o600)
    }
}

/// Lends one account's captured auth to a separate CODEX_HOME and takes it back. A refresh token is
/// single-use, so two live copies of one chain log each other out: a lease home must be the account's
/// only live holder, and the stored profile must end up with the home's latest rotated token.
private final class CLILeaseService {
    private let paths: SwitchboardPaths
    private let surfaceService: CLISurfaceService
    private let accountStore: CLIAccountStore
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths, surfaceService: CLISurfaceService, accountStore: CLIAccountStore) {
        self.paths = paths
        self.surfaceService = surfaceService
        self.accountStore = accountStore
    }

    func lease(profileKey: String, home rawHome: String, holder: String) throws -> LeasePayload {
        let requestedHome = URL(fileURLWithPath: (rawHome as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.path
        try ensureLeaseHomeAllowed(requestedHome)

        return try CodexAuthStoreLock.withRequiredLock(appSupportURL: paths.appSupportURL) {
            let leases = try paths.leaseStore.load()
            if let existing = leases.first(where: { $0.profileKey == profileKey }) {
                throw CLIError.refused(
                    code: "already_leased",
                    message: "profile_key \(profileKey) is already leased to \(existing.holder) at \(existing.home).",
                    details: nil
                )
            }
            if let existing = leases.first(where: { CodexLease.sameHome($0.home, requestedHome) }) {
                throw CLIError.refused(
                    code: "home_already_leased",
                    message: "\(requestedHome) already holds the lease of \(existing.holder).",
                    details: nil
                )
            }
            if CodexRefreshReservations(appSupportURL: paths.appSupportURL)
                .isReserved(profileKey: profileKey, runningAppPIDs: Set(runningSwitchboardAppPIDs())) {
                throw CLIError.refused(
                    code: "refresh_in_progress",
                    message: "Switchboard is refreshing the token of profile_key \(profileKey) right now; lease again in a few seconds.",
                    details: nil
                )
            }
            if surfaceService.statuses(scope: .all).contains(where: { $0.activeProfileKey == profileKey }) {
                throw CLIError.refused(
                    code: "active_account",
                    message: "profile_key \(profileKey) is the active CLI or Desktop account; lease an account no surface is using.",
                    details: nil
                )
            }
            try ensureLeasableAccount(profileKey: profileKey)
            try ensureAppMirrorsLeases()

            let configText = try? String(
                contentsOf: URL(fileURLWithPath: requestedHome).appendingPathComponent("config.toml"),
                encoding: .utf8
            )
            let mode = CodexCredentialStoreMode.resolve(config: configText, surface: .cli)
            guard mode == "file" else {
                throw CLIError.unsupportedMode(surface: "lease home", mode: mode, path: requestedHome, jsonPreferred: true)
            }

            let profile = try CapturedProfileStore(paths: paths).profile(sourceProfileKey: profileKey)
            guard let profileAuth = StoredAuth.load(from: profile.authURL), profileAuth.hasCompleteTokens else {
                throw CLIError.failure(message: "Captured profile is missing valid redacted identity fields.", jsonPreferred: true)
            }

            try paths.ensureDirectory(URL(fileURLWithPath: requestedHome, isDirectory: true), permissions: 0o700)
            let home = CodexLease.normalizedHome(requestedHome)
            let authURL = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
            let alreadyHeld = try homeAlreadyHolds(profileAuth, at: authURL)

            let lease = CodexLease(
                profileKey: profileKey,
                home: home,
                holder: holder,
                profileDirectory: profile.profileURL.lastPathComponent
            )
            // Record the lease before the copy exists, so switch, auto-swap and the app see it first.
            try paths.leaseStore.save(leases + [lease])
            if !alreadyHeld {
                do {
                    try paths.writeData(try Data(contentsOf: profile.authURL), to: authURL, permissions: 0o600)
                } catch {
                    try? paths.leaseStore.save(leases)
                    throw error
                }
            }
            return LeasePayload(
                generatedAt: Date(),
                profileKey: profileKey,
                home: home,
                holder: holder,
                leasedAt: lease.leasedAt,
                authStorePath: authURL.path,
                authWritten: !alreadyHeld
            )
        }
    }

    func returnLease(profileKey: String, home rawHome: String) throws -> LeaseReturnPayload {
        let requestedHome = URL(fileURLWithPath: (rawHome as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.path

        return try CodexAuthStoreLock.withRequiredLock(appSupportURL: paths.appSupportURL) {
            var leases = try paths.leaseStore.load()
            guard let lease = leases.first(where: { $0.profileKey == profileKey }) else {
                throw CLIError.refused(
                    code: "not_leased",
                    message: "profile_key \(profileKey) has no active lease.",
                    details: nil
                )
            }
            guard CodexLease.sameHome(lease.home, requestedHome) else {
                throw CLIError.refused(
                    code: "home_mismatch",
                    message: "profile_key \(profileKey) is leased at \(lease.home), not \(requestedHome).",
                    details: nil
                )
            }
            let consumers = consumerProcesses(usingHome: lease.home)
            guard consumers.isEmpty else {
                // Only pid and program name: a full command line can carry a prompt with secrets in it.
                throw CLIError.refused(
                    code: "home_in_use",
                    message: "Processes are still using \(lease.home); stop them, then return the lease.",
                    details: consumers.map { "\($0.pid) \(programName(of: $0.command))" }
                )
            }

            let outcome = try CodexLeaseSync.syncHome(lease, appSupportURL: paths.appSupportURL)
            switch outcome {
            case .identityMismatch:
                throw CLIError.refused(
                    code: "home_holds_other_account",
                    message: "\(lease.authURL.path) now holds a different account. Nothing was synced or removed; move that file away, then return again.",
                    details: nil
                )
            case .homeAuthUnreadable:
                throw CLIError.refused(
                    code: "home_auth_unreadable",
                    message: "\(lease.authURL.path) cannot be read as Codex auth. Nothing was removed.",
                    details: nil
                )
            case .storedProfileMissing:
                throw CLIError.refused(
                    code: "stored_profile_missing",
                    message: "The captured profile for profile_key \(profileKey) is gone, so the lease home holds the only copy. Nothing was removed.",
                    details: nil
                )
            case .rotated, .unchanged, .homeAuthMissing:
                break
            }

            let removeHomeAuth = outcome != .homeAuthMissing
            if removeHomeAuth {
                try fileManager.removeItem(at: lease.authURL)
            }
            leases.removeAll { $0.profileKey == profileKey }
            try paths.leaseStore.save(leases)
            return LeaseReturnPayload(
                generatedAt: Date(),
                profileKey: profileKey,
                home: lease.home,
                holder: lease.holder,
                leasedAt: lease.leasedAt,
                sync: outcome.rawValue,
                homeAuthRemoved: removeHomeAuth
            )
        }
    }

    func list() throws -> LeasesPayload {
        let leases = try paths.leaseStore.load()
        let activeKeys = Set(surfaceService.statuses(scope: .all).compactMap(\.activeProfileKey))
        let accounts = accountStore.accounts()
        return LeasesPayload(
            generatedAt: Date(),
            leases: leases.map { lease in
                let account = accounts.first { $0.profileKey == lease.profileKey }
                return LeaseStatusPayload(
                    profileKey: lease.profileKey,
                    plan: account?.plan,
                    sessionFreePercent: account?.sessionFreePercent,
                    weeklyFreePercent: account?.weeklyFreePercent,
                    usableForCodex: account?.usableForCodex ?? false,
                    needsRelogin: account?.needsRelogin ?? false,
                    score: account?.score,
                    home: lease.home,
                    holder: lease.holder,
                    leasedAt: lease.leasedAt,
                    homeAuthPresent: fileManager.fileExists(atPath: lease.authURL.path),
                    homeMatchesStoredProfile: CodexLeaseSync.homeMatchesStoredProfile(
                        lease,
                        appSupportURL: paths.appSupportURL
                    ),
                    activeOnSurface: activeKeys.contains(lease.profileKey)
                )
            }
        )
    }

    /// Marks the accounts an agent could lease now: unleased, a known paid plan, usable quota, no
    /// re-login needed, and not the active account of any surface.
    func annotateLeasable(_ accounts: [AccountPayload]) -> [AccountPayload] {
        let activeKeys = Set(surfaceService.statuses(scope: .all).compactMap(\.activeProfileKey))
        return accounts.map { account in
            var account = account
            account.leasable = !account.leased
                && account.isKnownPaidPlan
                && account.usableForCodex
                && !account.needsRelogin
                && !activeKeys.contains(account.profileKey)
            return account
        }
    }

    /// Returns the account leased at `home` and leases another into the same home, for a lane whose
    /// account runs low. Every process in the home must have stopped: a live Codex holds the old
    /// token in memory.
    func swapLease(
        home rawHome: String,
        to requestedKey: String?,
        excluding excludedKeys: Set<String>,
        holder newHolder: String?
    ) throws -> LeaseSwapPayload {
        let requestedHome = URL(fileURLWithPath: (rawHome as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.path

        return try CodexAuthStoreLock.withRequiredLock(appSupportURL: paths.appSupportURL) {
            let leases = try paths.leaseStore.load()
            guard let current = leases.first(where: { CodexLease.sameHome($0.home, requestedHome) }) else {
                throw CLIError.refused(
                    code: "no_lease_at_home",
                    message: "\(requestedHome) holds no lease; use lease for its first account.",
                    details: nil
                )
            }
            let candidates = annotateLeasable(accountStore.accounts())
            let targetKey: String
            if let requestedKey {
                targetKey = requestedKey
            } else {
                guard let best = candidates
                    .filter({ $0.leasable && $0.profileKey != current.profileKey && !excludedKeys.contains($0.profileKey) })
                    .max(by: { ($0.score, $0.sessionFreePercent) < ($1.score, $1.sessionFreePercent) }) else {
                    throw CLIError.refused(
                        code: "no_candidate",
                        message: "No other paid, usable, unleased account is free to lease.",
                        details: nil
                    )
                }
                targetKey = best.profileKey
            }
            guard targetKey != current.profileKey else {
                throw CLIError.refused(
                    code: "same_account",
                    message: "profile_key \(targetKey) is already the account leased at \(current.home).",
                    details: nil
                )
            }
            // Check the target before giving anything back, so a refusal leaves the lane as it was.
            if let target = candidates.first(where: { $0.profileKey == targetKey }), !target.leasable {
                try ensureLeasableAccount(profileKey: targetKey)
                let (code, reason) = target.leased
                    ? ("already_leased", "it is already leased")
                    : target.usableForCodex
                        ? ("active_account", "it is the active CLI or Desktop account")
                        : ("not_usable", "it has no usable quota left")
                throw CLIError.refused(
                    code: code,
                    message: "profile_key \(targetKey) cannot be leased now: \(reason).",
                    details: nil
                )
            }
            try ensureLeasableAccount(profileKey: targetKey)
            try ensureAppMirrorsLeases()

            let returned = try returnLease(profileKey: current.profileKey, home: current.home)
            let leased: LeasePayload
            do {
                leased = try lease(profileKey: targetKey, home: current.home, holder: newHolder ?? current.holder)
            } catch {
                throw CLIError.refused(
                    code: "swap_incomplete",
                    message: "Returned profile_key \(current.profileKey) from \(current.home), but leasing \(targetKey) failed: \(error.localizedDescription) The home now holds no account.",
                    details: nil
                )
            }
            return LeaseSwapPayload(
                generatedAt: Date(),
                home: leased.home,
                holder: leased.holder,
                returnedProfileKey: returned.profileKey,
                returnSync: returned.sync,
                leasedProfileKey: leased.profileKey,
                leasedAt: leased.leasedAt
            )
        }
    }

    private func ensureLeaseHomeAllowed(_ home: String) throws {
        func refuse(_ reason: String) -> CLIError {
            CLIError.refused(code: "home_not_allowed", message: "Cannot lease into \(home): \(reason)", details: nil)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: home, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw refuse("it is not a directory.")
        }
        if home == "/" || CodexLease.sameHome(home, paths.homeURL.path) {
            throw refuse("use a dedicated directory.")
        }
        for kind in [SurfaceKind.desktop, .cli] where CodexLease.sameHome(home, paths.codexHome(for: kind).path) {
            throw refuse("it is the \(kind.displayName) home. Unset CODEX_HOME when it points at the lease home.")
        }
        let storage = CodexLease.homeSpellings(paths.appSupportURL.path)
        if CodexLease.homeSpellings(home).contains(where: { spelling in
            storage.contains { spelling == $0 || spelling.hasPrefix($0 + "/") }
        }) {
            throw refuse("it is inside Switchboard's app storage.")
        }
    }

    private func ensureLeasableAccount(profileKey: String) throws {
        guard let account = accountStore.accounts().first(where: { $0.profileKey == profileKey }) else {
            throw CLIError.refused(
                code: "unknown_profile",
                message: "profile_key \(profileKey) is not in Switchboard's account list.",
                details: nil
            )
        }
        if account.isFreePlan {
            throw CLIError.refused(code: "free_plan", message: "profile_key \(profileKey) is a free-plan account.", details: nil)
        }
        if !account.isKnownPaidPlan {
            throw CLIError.refused(
                code: "plan_unknown",
                message: "profile_key \(profileKey) has no known paid plan yet; open Switchboard to refresh usage, then lease again.",
                details: nil
            )
        }
        if account.needsRelogin {
            throw CLIError.refused(code: "needs_relogin", message: "profile_key \(profileKey) needs a new sign-in.", details: nil)
        }
    }

    /// A running app that predates leases would keep refreshing a leased token itself, which logs the
    /// lease home out. Only a lease-aware app that recorded its pid may run during a lease.
    private func ensureAppMirrorsLeases() throws {
        guard paths.isAppStorage else { return }
        let ready = CodexLeaseMirrorMarker.isReady(
            runningAppPIDs: runningSwitchboardAppPIDs(),
            recordedPID: CodexLeaseMirrorMarker.recordedPID(appSupportURL: paths.appSupportURL)
        )
        guard ready else {
            throw CLIError.refused(
                code: "app_not_lease_aware",
                message: "A running Codex Switchboard app does not mirror leases: it predates them or uses other storage, and it would refresh the leased token itself. Update or quit the app, then lease again.",
                details: nil
            )
        }
    }

    /// Never overwrites another sign-in: only an exact copy of the stored token counts as already held.
    private func homeAlreadyHolds(_ profileAuth: StoredAuth, at authURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: authURL.path) else { return false }
        guard let homeAuth = StoredAuth.load(from: authURL) else {
            throw CLIError.refused(
                code: "home_auth_unreadable",
                message: "\(authURL.path) exists and cannot be read as Codex auth; move it away first.",
                details: nil
            )
        }
        if homeAuth.hasSameTokens(as: profileAuth) {
            return true
        }
        if homeAuth.identity.matches(profileAuth.identity) {
            throw CLIError.refused(
                code: "home_holds_other_login",
                message: "\(authURL.path) holds a separate sign-in for this account; leasing over it would discard that sign-in.",
                details: nil
            )
        }
        throw CLIError.refused(
            code: "home_holds_other_account",
            message: "\(authURL.path) holds a different account's auth.",
            details: nil
        )
    }
}

private struct LocalProfileCollection {
    let profiles: [String: [String: Any]]
    let orderedKeys: [String]

    static func load(from url: URL) -> LocalProfileCollection {
        guard let root = readJSON(url),
              let profiles = root["profiles"] as? [String: [String: Any]] else {
            return LocalProfileCollection(profiles: [:], orderedKeys: [])
        }
        return LocalProfileCollection(
            profiles: profiles,
            orderedKeys: orderedKeys(root: root, profiles: profiles)
        )
    }

    private static func orderedKeys(root: [String: Any], profiles: [String: [String: Any]]) -> [String] {
        let orderMap = root["order"] as? [String: [String]] ?? [:]
        var ordered: [String] = []
        var seen = Set<String>()
        for keys in orderMap.values {
            for key in keys where profiles[key] != nil && !seen.contains(key) {
                ordered.append(key)
                seen.insert(key)
            }
        }
        for key in profiles.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }
        return ordered
    }
}

private final class CapturedProfileStore {
    private let paths: SwitchboardPaths
    private let fileManager = FileManager.default

    init(paths: SwitchboardPaths) {
        self.paths = paths
    }

    func profile(sourceProfileKey: String) throws -> CapturedProfile {
        let matches = profiles().filter { $0.sourceProfileKey == sourceProfileKey }
        guard let newest = matches.max(by: { $0.freshnessDate < $1.freshnessDate }) else {
            throw CLIError.failure(message: "Captured auth was not found for profile_key \(sourceProfileKey).", jsonPreferred: true)
        }
        return newest
    }

    func profileMatching(auth: StoredAuth) -> CapturedProfile? {
        let loadedProfiles = profiles().compactMap { profile -> (profile: CapturedProfile, auth: StoredAuth)? in
            guard let profileAuth = StoredAuth.load(from: profile.authURL) else { return nil }
            return (profile, profileAuth)
        }
        let exactMatches = loadedProfiles.filter { candidate in
            candidate.auth.idToken == auth.idToken
                && candidate.auth.accessToken == auth.accessToken
                && candidate.auth.refreshToken == auth.refreshToken
        }
        if let match = newestProfile(from: exactMatches) {
            return match
        }

        return newestProfile(from: loadedProfiles.filter { candidate in
            candidate.auth.matchesStableIdentity(auth, capturedProfile: candidate.profile)
        })
    }

    func hasProfile(sourceProfileKey: String) -> Bool {
        profiles().contains { $0.sourceProfileKey == sourceProfileKey }
    }

    private func profiles() -> [CapturedProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let authURL = entry.appendingPathComponent("auth.json")
            guard fileManager.fileExists(atPath: authURL.path) else { return nil }
            let meta = readJSON(entry.appendingPathComponent("meta.json")) ?? [:]
            let auth = StoredAuth.load(from: authURL)
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return CapturedProfile(
                profileURL: entry,
                authURL: authURL,
                email: ((meta["email"] as? String) ?? auth?.email ?? "").lowercased(),
                accountID: (meta["account_id"] as? String) ?? auth?.accountID ?? "",
                sourceProfileKey: (meta["source_profile_key"] as? String) ?? "",
                freshnessDate: modified
            )
        }
    }

    private func newestProfile(from matches: [(profile: CapturedProfile, auth: StoredAuth)]) -> CapturedProfile? {
        matches.map(\.profile).max { $0.freshnessDate < $1.freshnessDate }
    }
}

private struct CapturedProfile {
    let profileURL: URL
    let authURL: URL
    let email: String
    let accountID: String
    let sourceProfileKey: String
    let freshnessDate: Date
}

struct StoredAuth {
    let root: [String: Any]
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let email: String
    let subject: String
    /// Access-token expiry in milliseconds, the unit `accounts.json` and profile metadata use.
    let accessExpiresAt: Int?

    var hasCompleteTokens: Bool {
        !idToken.isEmpty && !accessToken.isEmpty && !refreshToken.isEmpty
    }

    func hasSameTokens(as other: StoredAuth) -> Bool {
        idToken == other.idToken
            && accessToken == other.accessToken
            && refreshToken == other.refreshToken
    }

    static func load(from url: URL) -> StoredAuth? {
        guard let root = readJSON(url),
              let tokens = root["tokens"] as? [String: Any] else {
            return nil
        }
        let idToken = tokens["id_token"] as? String ?? ""
        let accessToken = tokens["access_token"] as? String ?? ""
        let refreshToken = tokens["refresh_token"] as? String ?? ""
        let idPayload = decodePayload(idToken)
        let authPayload = idPayload?["https://api.openai.com/auth"] as? [String: Any]
        let accessExpiry = (decodePayload(accessToken)?["exp"] as? Double) ?? (idPayload?["exp"] as? Double)
        return StoredAuth(
            root: root,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: ((tokens["account_id"] as? String) ?? (authPayload?["chatgpt_account_id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            email: ((idPayload?["email"] as? String) ?? "").lowercased(),
            subject: ((idPayload?["sub"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            accessExpiresAt: accessExpiry.map { Int($0 * 1_000) }
        )
    }

    fileprivate func matchesStableIdentity(_ other: StoredAuth, capturedProfile: CapturedProfile) -> Bool {
        CodexAuthIdentity(
            subject: subject,
            accountID: accountID.isEmpty ? capturedProfile.accountID : accountID,
            email: email.isEmpty ? capturedProfile.email : email
        )
        .matches(other.identity)
    }

    var identity: CodexAuthIdentity {
        CodexAuthIdentity(subject: subject, accountID: accountID, email: email)
    }

    private static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(base64URLString: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload
    }
}

private struct AccountSnapshot: Decodable {
    let lastRefreshEpoch: TimeInterval?
    let accounts: [SnapshotAccount]
}

private struct SnapshotAccount: Decodable {
    let profileKey: String?
    let email: String
    let workspace: String
    let plan: String
    let sessionFree: Double
    let weeklyFree: Double
    let sessionResetSeconds: Double
    let weeklyResetSeconds: Double
    let quotaWindows: [SnapshotQuotaWindow]?
    let hasError: Bool
    let errorMessage: String?
}

private struct SnapshotQuotaWindow: Decodable {
    let kind: String
    let usedPercent: Double
    let resetSeconds: Double
    let durationSeconds: Double?

    var freePercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

enum SnapshotQuotaCompatibility {
    static func values(
        windows: [(kind: String, freePercent: Double)]?,
        legacySessionFree: Double,
        legacyWeeklyFree: Double
    ) -> (sessionFree: Double, weeklyFree: Double, score: Double) {
        guard let windows else {
            return (
                legacySessionFree,
                legacyWeeklyFree,
                legacySessionFree * 0.6 + legacyWeeklyFree * 0.4
            )
        }

        let leadingWindow = windows.first { $0.kind != "weekly" }
        let weeklyWindow = windows.first { $0.kind == "weekly" }
        let longTermWindow = weeklyWindow ?? windows.last
        return (
            leadingWindow?.freePercent
                ?? longTermWindow?.freePercent
                ?? legacySessionFree,
            longTermWindow?.freePercent
                ?? leadingWindow?.freePercent
                ?? legacyWeeklyFree,
            windows.map(\.freePercent).min() ?? 0
        )
    }
}

private struct QuotaWindowPayload: Codable {
    let kind: String
    let freePercent: Double
    let resetSeconds: Double
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case freePercent = "free_percent"
        case resetSeconds = "reset_seconds"
        case durationSeconds = "duration_seconds"
    }
}

private struct AccountPayload: Codable {
    let profileKey: String
    let email: String
    let workspace: String
    let plan: String
    let sessionFreePercent: Double
    let weeklyFreePercent: Double
    let quotaWindows: [QuotaWindowPayload]
    let usableForCodex: Bool
    let needsRelogin: Bool
    let nextResetAt: Date?
    let isFreePlan: Bool
    let score: Double
    var leased = false
    var leaseHolder: String?
    var leasable = false

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case email
        case workspace
        case plan
        case sessionFreePercent = "session_free_percent"
        case weeklyFreePercent = "weekly_free_percent"
        case quotaWindows = "quota_windows"
        case usableForCodex = "usable_for_codex"
        case needsRelogin = "needs_relogin"
        case nextResetAt = "next_reset_at"
        case isFreePlan = "is_free_plan"
        case score
        case leased
        case leaseHolder = "lease_holder"
        case leasable
    }

    /// A plan Switchboard has seen and that is not free. An unknown plan is not proof of a paid one.
    var isKnownPaidPlan: Bool {
        let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !isFreePlan && !["", "?", "unknown"].contains(normalized)
    }

    init(
        profileKey: String,
        email: String,
        workspace: String,
        plan: String,
        sessionFreePercent: Double,
        weeklyFreePercent: Double,
        quotaWindows: [QuotaWindowPayload] = [],
        usableForCodex: Bool,
        needsRelogin: Bool,
        nextResetAt: Date?,
        isFreePlan: Bool,
        score: Double
    ) {
        self.profileKey = profileKey
        self.email = email
        self.workspace = workspace
        self.plan = plan
        self.sessionFreePercent = sessionFreePercent
        self.weeklyFreePercent = weeklyFreePercent
        self.quotaWindows = quotaWindows
        self.usableForCodex = usableForCodex
        self.needsRelogin = needsRelogin
        self.nextResetAt = nextResetAt
        self.isFreePlan = isFreePlan
        self.score = score
    }

    init?(
        snapshot: SnapshotAccount,
        snapshotRefreshDate: Date,
        hasCapturedAuth: Bool
    ) {
        guard let profileKey = snapshot.profileKey, !profileKey.isEmpty else { return nil }
        let quotaWindows = snapshot.quotaWindows?.map {
            QuotaWindowPayload(
                kind: $0.kind,
                freePercent: $0.freePercent,
                resetSeconds: $0.resetSeconds,
                durationSeconds: $0.durationSeconds
            )
        }
        let usableQuota: Bool
        if let quotaWindows {
            usableQuota = !quotaWindows.isEmpty
                && quotaWindows.allSatisfy { $0.freePercent > 0.001 }
        } else {
            usableQuota = snapshot.sessionFree > 0.001 && snapshot.weeklyFree > 0.001
        }
        let usable = !snapshot.hasError && usableQuota && hasCapturedAuth
        let isFree = snapshot.plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
        let nextReset = Self.nextResetDate(snapshot: snapshot, baseDate: snapshotRefreshDate)
        let needsRelogin = Self.needsRelogin(snapshot.errorMessage) || !hasCapturedAuth
        let compatibility = SnapshotQuotaCompatibility.values(
            windows: quotaWindows?.map { ($0.kind, $0.freePercent) },
            legacySessionFree: snapshot.sessionFree,
            legacyWeeklyFree: snapshot.weeklyFree
        )
        let penalty = (snapshot.hasError ? 1_000.0 : 0) + (isFree ? 100.0 : 0)
        self.init(
            profileKey: profileKey,
            email: snapshot.email,
            workspace: snapshot.workspace,
            plan: snapshot.plan,
            sessionFreePercent: compatibility.sessionFree,
            weeklyFreePercent: compatibility.weeklyFree,
            quotaWindows: quotaWindows ?? [],
            usableForCodex: usable,
            needsRelogin: needsRelogin,
            nextResetAt: nextReset,
            isFreePlan: isFree,
            score: compatibility.score - penalty
        )
    }

    private static func nextResetDate(snapshot: SnapshotAccount, baseDate: Date) -> Date? {
        if let quotaWindows = snapshot.quotaWindows {
            let exhaustedReset = quotaWindows
                .filter { $0.freePercent <= 0.001 && $0.resetSeconds > 0 }
                .map(\.resetSeconds)
                .min()
            let nextReset = exhaustedReset
                ?? quotaWindows.filter { $0.resetSeconds > 0 }.map(\.resetSeconds).min()
            return nextReset.map { baseDate.addingTimeInterval($0) }
        }

        let seconds: Double
        if snapshot.sessionFree <= 0.001, snapshot.sessionResetSeconds > 0 {
            seconds = snapshot.sessionResetSeconds
        } else if snapshot.weeklyFree <= 0.001, snapshot.weeklyResetSeconds > 0 {
            seconds = snapshot.weeklyResetSeconds
        } else if snapshot.weeklyResetSeconds > 0 {
            seconds = snapshot.weeklyResetSeconds
        } else if snapshot.sessionResetSeconds > 0 {
            seconds = snapshot.sessionResetSeconds
        } else {
            return nil
        }
        return baseDate.addingTimeInterval(seconds)
    }

    private static func needsRelogin(_ errorMessage: String?) -> Bool {
        guard let value = errorMessage?.lowercased() else { return false }
        return value.contains("expired")
            || value.contains("revoked")
            || value.contains("invalidated")
            || value.contains("refresh token reused")
            || value.contains("http 401")
            || value.contains("http 403")
            || value.contains("refresh failed")
    }
}

private struct SurfaceStatusPayload: Codable {
    let kind: SurfaceKind
    let displayName: String
    let detected: Bool
    let running: Bool
    let authStorePath: String
    let authStoreMode: String
    let supportsFileSwitching: Bool
    let activeProfileKey: String?
    let activeEmail: String?
    let activeAccountID: String?
    var sharedAuthStore: Bool
    var sharedWith: SurfaceKind?

    enum CodingKeys: String, CodingKey {
        case kind
        case displayName = "display_name"
        case detected
        case running
        case authStorePath = "auth_store_path"
        case authStoreMode = "auth_store_mode"
        case supportsFileSwitching = "supports_file_switching"
        case activeProfileKey = "active_profile_key"
        case activeEmail = "active_email"
        case activeAccountID = "active_account_id"
        case sharedAuthStore = "shared_auth_store"
        case sharedWith = "shared_with"
    }
}

private extension SurfaceStatusPayload {
    var autoSwapSurface: AutoSwapSurface {
        AutoSwapSurface(
            kind: kind.autoSwapKind,
            detected: detected,
            supportsFileSwitching: supportsFileSwitching,
            activeProfileKey: activeProfileKey,
            authStoreMode: authStoreMode
        )
    }
}

private extension AccountPayload {
    var autoSwapAccount: AutoSwapAccount {
        AutoSwapAccount(
            profileKey: profileKey,
            sessionFreePercent: sessionFreePercent,
            weeklyFreePercent: weeklyFreePercent,
            usableForCodex: usableForCodex,
            needsRelogin: needsRelogin,
            isFreePlan: isFreePlan,
            score: score,
            isLeased: leased
        )
    }
}

private struct StatusPayload: Codable {
    let generatedAt: Date
    let surfaces: [SurfaceStatusPayload]
    let accounts: [AccountPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case surfaces
        case accounts
    }
}

private struct SwitchPayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let email: String
    let accountID: String
    let surfaces: [SwitchSurfacePayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case email
        case accountID = "account_id"
        case surfaces
    }
}

private struct SwitchSurfacePayload: Codable {
    let kind: SurfaceKind
    let authStorePath: String
    let authStoreMode: String
    let sharedAuthStore: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case authStorePath = "auth_store_path"
        case authStoreMode = "auth_store_mode"
        case sharedAuthStore = "shared_auth_store"
    }
}

private struct LeasePayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let home: String
    let holder: String
    let leasedAt: Date
    let authStorePath: String
    let authWritten: Bool

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case home
        case holder
        case leasedAt = "leased_at"
        case authStorePath = "auth_store_path"
        case authWritten = "auth_written"
    }
}

private struct LeaseReturnPayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let home: String
    let holder: String
    let leasedAt: Date
    let sync: String
    let homeAuthRemoved: Bool

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case home
        case holder
        case leasedAt = "leased_at"
        case sync
        case homeAuthRemoved = "home_auth_removed"
    }
}

private struct LeaseStatusPayload: Codable {
    let profileKey: String
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
    let activeOnSurface: Bool

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case plan
        case sessionFreePercent = "session_free_percent"
        case weeklyFreePercent = "weekly_free_percent"
        case usableForCodex = "usable_for_codex"
        case needsRelogin = "needs_relogin"
        case score
        case home
        case holder
        case leasedAt = "leased_at"
        case homeAuthPresent = "home_auth_present"
        case homeMatchesStoredProfile = "home_matches_stored_profile"
        case activeOnSurface = "active_on_surface"
    }
}

private struct LeaseSwapPayload: Codable {
    let generatedAt: Date
    let home: String
    let holder: String
    let returnedProfileKey: String
    let returnSync: String
    let leasedProfileKey: String
    let leasedAt: Date

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case home
        case holder
        case returnedProfileKey = "returned_profile_key"
        case returnSync = "return_sync"
        case leasedProfileKey = "leased_profile_key"
        case leasedAt = "leased_at"
    }
}

private struct LeasesPayload: Codable {
    let generatedAt: Date
    let leases: [LeaseStatusPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case leases
    }
}

private struct DoctorPayload: Codable {
    let generatedAt: Date
    let appSupportPath: String
    let profilesPath: String
    let consumersRunning: Bool
    let consumerCount: Int
    let unsupportedSurfaces: [SurfaceKind]
    let surfaces: [SurfaceStatusPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case appSupportPath = "app_support_path"
        case profilesPath = "profiles_path"
        case consumersRunning = "consumers_running"
        case consumerCount = "consumer_count"
        case unsupportedSurfaces = "unsupported_surfaces"
        case surfaces
    }
}

private struct AutoSwapStatusPayload: Codable {
    let generatedAt: Date
    let policy: AutoSwapPolicy
    let recentEvents: [AutoSwapAuditEvent]
    let decisions: [AutoSwapDecision]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case policy
        case recentEvents = "recent_events"
        case decisions
    }
}

private struct AutoSwapRunPayload: Codable {
    let generatedAt: Date
    let policy: AutoSwapPolicy
    let dryRun: Bool
    let consumerCount: Int
    let decisions: [AutoSwapDecision]
    let switches: [AutoSwapSwitchPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case policy
        case dryRun = "dry_run"
        case consumerCount = "consumer_count"
        case decisions
        case switches
    }
}

private struct AutoSwapSwitchPayload: Codable {
    let generatedAt: Date
    let profileKey: String
    let surfaces: [AutoSwapSwitchSurfacePayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case profileKey = "profile_key"
        case surfaces
    }

    init(outcome: SwitchPayload) {
        generatedAt = outcome.generatedAt
        profileKey = outcome.profileKey
        surfaces = outcome.surfaces.map(AutoSwapSwitchSurfacePayload.init)
    }
}

private struct AutoSwapSwitchSurfacePayload: Codable {
    let kind: SurfaceKind
    let authStoreMode: String
    let sharedAuthStore: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case authStoreMode = "auth_store_mode"
        case sharedAuthStore = "shared_auth_store"
    }

    init(surface: SwitchSurfacePayload) {
        kind = surface.kind
        authStoreMode = surface.authStoreMode
        sharedAuthStore = surface.sharedAuthStore
    }
}

private struct ProcessInfoPayload: Codable {
    let pid: Int32
    let command: String

    var description: String {
        "\(pid) \(command)"
    }
}

private enum EncodablePayload {
    case text(String)
    case status(StatusPayload)
    case switchOutcome(SwitchPayload)
    case lease(LeasePayload)
    case leaseReturn(LeaseReturnPayload)
    case leases(LeasesPayload)
    case leaseSwap(LeaseSwapPayload)
    case doctor(DoctorPayload)
    case autoSwapStatus(AutoSwapStatusPayload)
    case autoSwapRun(AutoSwapRunPayload)
    case error(ErrorPayload)
}

private struct ErrorPayload: Codable {
    let generatedAt: Date
    let error: String
    let message: String
    let details: [String]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case error
        case message
        case details
    }
}

private enum CLIError: LocalizedError {
    case usage(String, jsonPreferred: Bool)
    case surfaceNotDetected(surface: String, jsonPreferred: Bool)
    case consumersRunning([String], jsonPreferred: Bool)
    case unsupportedMode(surface: String, mode: String, path: String, jsonPreferred: Bool)
    case refused(code: String, message: String, details: [String]?)
    case failure(message: String, jsonPreferred: Bool)

    var errorDescription: String? {
        switch self {
        case let .usage(message, _):
            return message
        case let .surfaceNotDetected(surface, _):
            return "Requested Codex surface is not detected: \(surface)."
        case let .consumersRunning(processes, _):
            return "Codex consumers are running; pass --stop-consumers to terminate them before switching. \(processes.joined(separator: "; "))"
        case let .unsupportedMode(surface, mode, path, _):
            return "Unsupported auth store mode for \(surface): \(mode) at \(path). File-backed switching is supported; keyring, auto, and ephemeral modes are detected but not mutated."
        case let .refused(_, message, _):
            return message
        case let .failure(message, _):
            return message
        }
    }

    var code: String {
        switch self {
        case .usage:
            return "usage"
        case .surfaceNotDetected:
            return "surface_not_detected"
        case .consumersRunning:
            return "consumers_running"
        case .unsupportedMode:
            return "unsupported_auth_store_mode"
        case let .refused(code, _, _):
            return code
        case .failure:
            return "failure"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage:
            return 64
        case .surfaceNotDetected, .consumersRunning, .unsupportedMode, .refused:
            return 2
        case .failure:
            return 1
        }
    }

    var jsonPreferred: Bool {
        switch self {
        case let .usage(_, value),
             let .surfaceNotDetected(_, value),
             let .consumersRunning(_, value),
             let .unsupportedMode(_, _, _, value),
             let .failure(_, value):
            return value
        case .refused:
            return true
        }
    }

    var details: [String]? {
        switch self {
        case let .consumersRunning(processes, _):
            return processes
        case let .refused(_, _, details):
            return details
        default:
            return nil
        }
    }
}

private enum Output {
    static func render(_ payload: EncodablePayload, json: Bool, exitCode: Int32) -> CommandOutput {
        if json {
            let text: String
            switch payload {
            case let .status(value):
                text = encodeJSON(value)
            case let .switchOutcome(value):
                text = encodeJSON(value)
            case let .lease(value):
                text = encodeJSON(value)
            case let .leaseReturn(value):
                text = encodeJSON(value)
            case let .leases(value):
                text = encodeJSON(value)
            case let .leaseSwap(value):
                text = encodeJSON(value)
            case let .doctor(value):
                text = encodeJSON(value)
            case let .autoSwapStatus(value):
                text = encodeJSON(value)
            case let .autoSwapRun(value):
                text = encodeJSON(value)
            case let .error(value):
                text = encodeJSON(value)
            case let .text(value):
                text = value
            }
            return CommandOutput(exitCode: exitCode, stdout: text, stderr: nil)
        }

        let text: String
        switch payload {
        case let .text(value):
            text = value
        case let .status(value):
            text = "surfaces: \(value.surfaces.count), accounts: \(value.accounts.count)"
        case let .switchOutcome(value):
            text = "switched \(value.profileKey) on \(value.surfaces.map { $0.kind.rawValue }.joined(separator: ","))"
        case let .lease(value):
            text = "leased to \(value.holder) at \(value.home)"
        case let .leaseReturn(value):
            text = "returned from \(value.holder) at \(value.home), sync: \(value.sync)"
        case let .leases(value):
            text = (["leases: \(value.leases.count)"] + value.leases.map { "\($0.holder) \($0.home)" })
                .joined(separator: "\n")
        case let .leaseSwap(value):
            text = "swapped the lease at \(value.home) for \(value.holder), returned sync: \(value.returnSync)"
        case let .doctor(value):
            text = "consumers_running: \(value.consumersRunning), unsupported_surfaces: \(value.unsupportedSurfaces.map(\.rawValue).joined(separator: ","))"
        case let .autoSwapStatus(value):
            text = "autoswap_enabled: \(value.policy.enabledSurfaces.map(\.rawValue).sorted().joined(separator: ",")), decisions: \(value.decisions.count)"
        case let .autoSwapRun(value):
            let summary = value.decisions.map { "\($0.surface.rawValue):\($0.decision.rawValue)" }.joined(separator: ",")
            text = "autoswap_run: \(summary), consumers: \(value.consumerCount)"
        case let .error(value):
            return CommandOutput(exitCode: exitCode, stdout: nil, stderr: value.message)
        }
        return CommandOutput(exitCode: exitCode, stdout: text, stderr: nil)
    }

    static func renderError(_ error: CLIError, json: Bool) -> CommandOutput {
        let payload = ErrorPayload(
            generatedAt: Date(),
            error: error.code,
            message: error.localizedDescription,
            details: error.details
        )
        if json {
            return CommandOutput(exitCode: error.exitCode, stdout: encodeJSON(payload), stderr: nil)
        }
        return CommandOutput(exitCode: error.exitCode, stdout: nil, stderr: payload.message)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return #"{"error":"encode_failed"}"#
        }
    }
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func processLines() -> [String] {
    runBestEffort("/bin/ps", ["-axo", "command="])
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// With `includeEnvironment`, each command is followed by the process's environment, as `ps -E` prints it.
private func processLinesWithPID(includeEnvironment: Bool = false) -> [(pid: Int32, command: String)] {
    runBestEffort("/bin/ps", (includeEnvironment ? ["-wwE"] : []) + ["-axo", "pid=,command="])
        .split(separator: "\n")
        .compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<split]) else {
                return nil
            }
            let command = trimmed[split...].trimmingCharacters(in: .whitespaces)
            return (pid, command)
        }
}

/// Processes still using a lease home: any process holding a file open directly inside it (Codex
/// keeps its SQLite state there while it runs), and Codex CLI consumers whose environment points
/// CODEX_HOME at it, where macOS lets `ps -E` show that environment.
private func consumerProcesses(usingHome home: String) -> [ProcessInfoPayload] {
    let commands = Dictionary(
        processLinesWithPID().map { ($0.pid, $0.command) },
        uniquingKeysWith: { first, _ in first }
    )
    var pids = Set(CodexLease.homeSpellings(home).flatMap(openFileHolderPIDs(in:)))

    let assignments = CodexLease.homeSpellings(home).flatMap { ["CODEX_HOME=\($0)", "CODEX_HOME=\($0)/"] }
    for (pid, environment) in processLinesWithPID(includeEnvironment: true) {
        guard let command = commands[pid],
              isCodexConsumerCommand(command.lowercased(), for: [.cli]),
              assignments.contains(where: { environment.hasSuffix(" \($0)") || environment.contains(" \($0) ") }) else {
            continue
        }
        pids.insert(pid)
    }
    pids.remove(Darwin.getpid())
    return pids.sorted().map { ProcessInfoPayload(pid: $0, command: commands[$0] ?? "") }
}

/// Owners of numbered file descriptors on files at the top level of `directory`. A working
/// directory or program text there does not count, so a shell sitting in the home is not a user.
private func openFileHolderPIDs(in directory: String) -> [Int32] {
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    var holders = Set<Int32>()
    var pid: Int32?
    // lsof exits 1 even when it lists holders, so its output is read whatever the status.
    let output = (try? run("/usr/sbin/lsof", ["-w", "-Fpf", "+d", directory], acceptingFailure: true)) ?? ""
    for line in output.split(separator: "\n") {
        if line.hasPrefix("p") {
            pid = Int32(line.dropFirst())
        } else if line.hasPrefix("f"), line.dropFirst().allSatisfy(\.isNumber), let pid {
            holders.insert(pid)
        }
    }
    return Array(holders)
}

private func runningSwitchboardAppPIDs() -> [Int32] {
    processLinesWithPID().compactMap { pid, command in
        isSwitchboardAppCommand(command) ? pid : nil
    }
}

/// A Switchboard app process, bundled or a bare build product, but not this CLI (`codex-switchboard`).
func isSwitchboardAppCommand(_ command: String) -> Bool {
    let lowercased = command.lowercased()
    return lowercased.hasSuffix("/codexswitchboard")
        || lowercased.contains("/codexswitchboard ")
        || lowercased == "codexswitchboard"
        || lowercased.hasPrefix("codexswitchboard ")
}

private func programName(of command: String) -> String {
    let program = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
    return URL(fileURLWithPath: program).lastPathComponent
}

private func isCodexConsumerCommand(_ lowercasedCommand: String) -> Bool {
    isCodexConsumerCommand(lowercasedCommand, for: [.desktop, .cli])
}

private func isCodexConsumerCommand(_ lowercasedCommand: String, for targetKinds: Set<SurfaceKind>) -> Bool {
    if targetKinds.contains(.desktop),
       isCodexDesktopProcessCommand(lowercasedCommand) {
        return true
    }
    guard targetKinds.contains(.cli) else {
        return false
    }
    if isCodexExecutableCommand(lowercasedCommand) {
        return true
    }
    if lowercasedCommand.hasPrefix("node "),
       lowercasedCommand.contains("/codex "),
       (lowercasedCommand.contains(" app-server ") || lowercasedCommand.contains(" exec ")) {
        return true
    }
    return lowercasedCommand.hasPrefix("/")
        && (
            lowercasedCommand.contains("/node_repl ")
                || lowercasedCommand.hasSuffix("/node_repl")
        )
}

private let codexDesktopAppPaths = [
    "/Applications/ChatGPT.app",
    "/Applications/Codex.app",
]

private func isCodexDesktopProcessCommand(_ lowercasedCommand: String) -> Bool {
    codexDesktopAppPaths.contains { appPath in
        lowercasedCommand.contains("\(appPath.lowercased())/contents/")
            && isCodexDesktopApp(atPath: appPath)
    }
}

private func isCodexDesktopApp(atPath path: String) -> Bool {
    let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return false
    }
    return info["CFBundleIdentifier"] as? String == "com.openai.codex"
}

private func isCodexExecutableCommand(_ lowercasedCommand: String) -> Bool {
    if lowercasedCommand == "codex" || lowercasedCommand.hasPrefix("codex ") {
        return true
    }
    guard lowercasedCommand.hasPrefix("/") else {
        return false
    }
    return lowercasedCommand.hasSuffix("/codex")
        || lowercasedCommand.contains("/codex ")
        || lowercasedCommand.hasSuffix("/codex/codex")
        || lowercasedCommand.contains("/codex/codex ")
}

@discardableResult
private func run(
    _ launchPath: String,
    _ arguments: [String],
    timeout: TimeInterval = 10,
    acceptingFailure: Bool = false
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSwitchboardCLI-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          let outputHandle = FileHandle(forWritingAtPath: outputURL.path) else {
        throw CLIError.failure(message: "Could not create temporary command output file.", jsonPreferred: true)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    defer {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
    }

    process.standardOutput = outputHandle
    process.standardError = outputHandle
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.25)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
    try outputHandle.synchronize()

    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 && !acceptingFailure {
        throw CLIError.failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines), jsonPreferred: true)
    }
    return output
}

private func runBestEffort(_ launchPath: String, _ arguments: [String]) -> String {
    (try? run(launchPath, arguments)) ?? ""
}

private extension Data {
    init?(base64URLString: String) {
        var normalized = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

private extension ISO8601DateFormatter {
    static let cli: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension DateFormatter {
    static let cliBackup: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
