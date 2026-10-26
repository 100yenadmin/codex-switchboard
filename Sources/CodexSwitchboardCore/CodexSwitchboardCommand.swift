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
        if paths.storageNamespaceInvalid {
            throw CLIError.refused(
                code: "storage_namespace_invalid",
                message: "\(CodexStorageNamespace.environmentKey) must be a folder name without / or :. Nothing was read or changed.",
                details: nil
            )
        }
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
        if options.leasableOnly {
            // Named by handle only: this view goes into agent transcripts.
            let payload = LeasableStatusPayload(generatedAt: Date(), accounts: accounts.map(LeasableAccountPayload.init))
            return CommandResult(payload: .leasableStatus(payload), json: options.json, exitCode: 0)
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
        // A handle names an account without its email, so callers can pass one instead of the key.
        let profileKey = CodexAccountHandle.resolve(options.profileKey, among: accountStore.accounts().map(\.profileKey))
            ?? options.profileKey
        let outcome = try switchService.switchProfile(
            profileKey: profileKey,
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
                accounts: autoSwapAccounts(accounts),
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

    /// A reserved login's account belongs to its one consumer, so auto-swap never picks it: a switch
    /// would spend that consumer's quota. A manual `switch` may still choose it.
    private func autoSwapAccounts(_ accounts: [AccountPayload]) -> [AutoSwapAccount] {
        let reserved = (try? ReservedLogins.load(from: paths.reservedLoginsURL, homeURL: paths.homeURL))?.profileKeys ?? []
        return accounts.map { $0.autoSwapAccount(reserved: reserved.contains($0.profileKey)) }
    }

    private func autoswapDecisions(policy: AutoSwapPolicy, scope: SurfaceScope) -> [AutoSwapDecision] {
        let accounts = autoSwapAccounts(accountStore.accounts())
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
        (<key> may be a profile key or a handle)
    codex-switchboard lease --profile-key <key> --home <dir> --holder <name> --json
    codex-switchboard return --profile-key <key> --home <dir> --json
    codex-switchboard leases --json
    codex-switchboard swap-lease --home <dir> --holder <name> [--profile-key <key>] [--exclude-profile-key <key>]... --json
        (lease commands name accounts by handle, acct_ plus 12 hex digits; <key> may be a handle or a profile key)
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
    let holder: String

    static func parse(_ args: [String]) throws -> SwapLeaseOptions {
        var parser = ArgumentParser(args)
        let json = parser.takeFlag("--json")
        let home = try parser.takeRequiredValue("--home")
        let profileKey = parser.takeOptionalValue("--profile-key")
        let excluded = try parser.takeAllValues("--exclude-profile-key")
        let holder = try parser.takeRequiredValue("--holder").trimmingCharacters(in: .whitespacesAndNewlines)
        try parser.finish()
        if let profileKey, profileKey.isEmpty || profileKey.hasPrefix("--") {
            throw CLIError.usage("Missing value for --profile-key.", jsonPreferred: false)
        }
        if holder.isEmpty || holder.count > 200 || holder.hasPrefix("--") {
            throw CLIError.usage("--holder must be 1 to 200 characters.", jsonPreferred: false)
        }
        if let profileKey, excluded.contains(profileKey) {
            throw CLIError.usage("--profile-key is also excluded.", jsonPreferred: false)
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
    /// Each argument with its original position, so a value is only ever the token right after its
    /// option, even once flags between them have been taken.
    private var args: [(position: Int, value: String)]

    init(_ args: [String]) {
        self.args = args.enumerated().map { ($0.offset, $0.element) }
    }

    mutating func takeFlag(_ flag: String) -> Bool {
        guard let index = args.firstIndex(where: { $0.value == flag }) else { return false }
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
        guard let index = args.firstIndex(where: { $0.value == flag }) else { return nil }
        let position = args.remove(at: index).position
        guard index < args.count, args[index].position == position + 1 else { return "" }
        return args.remove(at: index).value
    }

    mutating func takeAllValues(_ flag: String) throws -> [String] {
        var values: [String] = []
        while let value = takeOptionalValue(flag) {
            guard !value.isEmpty, !value.hasPrefix("--") else {
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
            // Never echoed: a stray value can be a profile key, which embeds an email.
            throw CLIError.usage("\(args.count) unexpected argument(s); each option takes its value right after it.", jsonPreferred: false)
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
    /// The namespace variable is set but names no usable folder. Falling back to the default storage
    /// would defeat the isolation it asks for, so every command refuses.
    let storageNamespaceInvalid: Bool

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeURL = homeURL
        self.environment = environment
        // Set at all, even empty, means the caller asked for separate storage: only a usable name gets it.
        let namespace = environment[CodexStorageNamespace.environmentKey]
        let namespaceSet = namespace != nil
        if let override = environment["CODEX_SWITCHBOARD_APP_SUPPORT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appSupportURL = URL(fileURLWithPath: override, isDirectory: true)
            storageNamespaceInvalid = false
        } else {
            appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(
                    CodexStorageNamespace.validated(namespace) ?? CodexStorageNamespace.defaultName,
                    isDirectory: true
                )
            storageNamespaceInvalid = namespaceSet && CodexStorageNamespace.validated(namespace) == nil
        }
        profilesURL = appSupportURL.appendingPathComponent("profiles", isDirectory: true)
        backupsURL = appSupportURL.appendingPathComponent("backups", isDirectory: true)
        accountsURL = appSupportURL.appendingPathComponent("accounts.json")
        snapshotURL = appSupportURL.appendingPathComponent("accounts-snapshot.json")
        autoSwapPolicyURL = appSupportURL.appendingPathComponent("auto-swap-policy.json")
        autoSwapAuditURL = appSupportURL.appendingPathComponent("auto-swap-events.json")
        leaseStore = CodexLeaseStore(appSupportURL: appSupportURL)
    }

    /// The codex-logins registry of reserved logins.
    var reservedLoginsURL: URL {
        homeURL.appendingPathComponent(".config/codex-logins/registry.json")
    }

    /// How long lease, return and swap-lease wait for another Switchboard process to release `.auth.lock`.
    var storeLockTimeout: TimeInterval {
        environment["CODEX_SWITCHBOARD_STORE_LOCK_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 60
    }

    /// How long lease, return and swap-lease wait for a lease home's holder to release its auth lock.
    var homeLockTimeout: TimeInterval {
        environment["CODEX_SWITCHBOARD_HOME_LOCK_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 30
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

    /// The accounts whose token chains sit in a Codex home that a surface uses or a switch wrote: ~/.codex,
    /// this process's CODEX_HOME, and every home in the switch record. `unknown` is true when one of those
    /// homes holds an auth.json that cannot be read even on a second look (Codex rewrites it in place), or the
    /// record cannot be read: a lease then cannot tell which account it would share.
    func liveChains() -> (keys: Set<String>, unknown: Bool) {
        var homes = [paths.homeURL.appendingPathComponent(".codex").path, paths.codexHome(for: .cli).path]
        var unknown = false
        if let recorded = CodexSwitchHomes.load(appSupportURL: paths.appSupportURL) {
            homes += recorded
        } else {
            unknown = true
        }
        let store = CapturedProfileStore(paths: paths)
        var keys = Set<String>()
        var seen = Set<String>()
        for home in homes where seen.insert(CodexLease.normalizedHome(home)).inserted {
            let authURL = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
            if CodexFileProbe.isMissing(authURL) { continue }
            var auth = StoredAuth.load(from: authURL)
            if auth == nil {
                usleep(75_000)
                auth = StoredAuth.load(from: authURL)
            }
            if let auth {
                if let key = store.profileMatching(auth: auth)?.sourceProfileKey { keys.insert(key) }
            } else if readJSON(authURL) == nil {
                // Valid JSON without tokens (an API key, a tombstone) holds no chain; anything else is unknown.
                unknown = true
            }
        }
        return (keys, unknown)
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
            account.handle = CodexAccountHandle.handle(for: account.profileKey)
            if let lease = leases.first(where: { $0.profileKey == account.profileKey }) {
                account.leased = true
                account.leaseHolder = lease.holder
                account.leaseQuarantined = CodexLeaseHome.isQuarantined(home: lease.home)
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
            // Recorded before the write: a lease must see this home's chain even after CODEX_HOME is unset.
            for (_, destination) in destinations {
                do {
                    try CodexSwitchHomes.record(
                        destination.deletingLastPathComponent().path,
                        appSupportURL: paths.appSupportURL,
                        defaultHome: paths.homeURL.appendingPathComponent(".codex").path
                    )
                } catch is CodexSwitchHomes.Unreadable {
                    throw CLIError.refused(
                        code: "switch_record_unreadable",
                        message: "\(CodexSwitchHomes.fileName) in Switchboard's storage cannot be read, so Switchboard cannot record this switch for its lease checks. Nothing was switched.",
                        details: nil
                    )
                }
            }
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
    /// A registry-reserved account belongs to its own consumer. Both are matched by seat, so another key that
    /// Switchboard lists for the same seat is refused too.
    private func ensureSwitchable(profileKey: String, surfaces: [SurfaceStatusPayload]) throws {
        let handle = CodexAccountHandle.handle(for: profileKey)
        let seat = seatKeys(of: profileKey)
        let leases = try paths.leaseStore.load()
        if let lease = leases.first(where: { seat.contains($0.profileKey) }) {
            throw CLIError.refused(
                code: "account_leased",
                message: "\(handle) is leased to an agent lane\(lease.profileKey == profileKey ? "" : " under another key of its seat"); return the lease before switching to it.",
                details: nil
            )
        }
        // A missing registry reserves nothing. One that cannot be read, or that reserves a key Switchboard no
        // longer lists, cannot say which seat it reserves, so every switch waits until it is fixed.
        let registry: ReservedLogins
        do {
            registry = try ReservedLogins.load(from: paths.reservedLoginsURL, homeURL: paths.homeURL)
        } catch {
            throw CLIError.refused(
                code: "reserved_registry_unreadable",
                message: "The codex-logins registry cannot be read or lists a login without a profile_key, so Switchboard cannot tell whether \(handle) is reserved; fix the registry before switching.",
                details: nil
            )
        }
        let listed = Set((readJSON(paths.accountsURL)?["profiles"] as? [String: Any])?.keys.map { $0 } ?? [])
        if !registry.staleKeys(among: listed).isEmpty {
            throw CLIError.refused(
                code: "reserved_registry_stale",
                message: "The codex-logins registry reserves a key Switchboard no longer lists (a new sign-in can re-key an account), so Switchboard cannot tell whether \(handle) is that account; register that login again before switching.",
                details: nil
            )
        }
        if !registry.profileKeys.isDisjoint(with: seat) {
            throw CLIError.refused(
                code: "reserved_account",
                message: "\(handle) is reserved in the codex-logins registry for its own consumer.",
                details: nil
            )
        }
        for surface in surfaces {
            let surfaceHome = URL(fileURLWithPath: surface.authStorePath).deletingLastPathComponent().path
            if leases.contains(where: { CodexLease.sameHome($0.home, surfaceHome) }) {
                throw CLIError.refused(
                    code: "surface_is_lease_home",
                    message: "The \(surface.kind.rawValue) auth store is a lease home; unset CODEX_HOME or return that lease first.",
                    details: nil
                )
            }
            if registry.homes.contains(where: { CodexLease.sameHome($0, surfaceHome) }) {
                throw CLIError.refused(
                    code: "surface_is_reserved_home",
                    message: "The \(surface.kind.rawValue) auth store is a reserved login's home in the codex-logins registry; unset CODEX_HOME before switching.",
                    details: nil
                )
            }
            if !CodexFileProbe.isMissing(URL(fileURLWithPath: surfaceHome).appendingPathComponent(CodexLeaseHome.holderLockFileName)) {
                throw CLIError.refused(
                    code: "surface_is_lane_home",
                    message: "The \(surface.kind.rawValue) auth store is in a lane home (it has \(CodexLeaseHome.holderLockFileName)), which only its holder or a lease writes; unset CODEX_HOME before switching.",
                    details: nil
                )
            }
        }
    }

    /// Every key the account list holds for `profileKey`'s seat (same account id and email), itself included.
    private func seatKeys(of profileKey: String) -> Set<String> {
        guard let profiles = readJSON(paths.accountsURL)?["profiles"] as? [String: [String: Any]],
              let entry = profiles[profileKey],
              let accountID = entry["accountId"] as? String, !accountID.isEmpty,
              let email = (entry["email"] as? String)?.lowercased(), !email.isEmpty else {
            return [profileKey]
        }
        let same = profiles.filter { _, value in
            value["accountId"] as? String == accountID && (value["email"] as? String)?.lowercased() == email
        }
        return Set(same.keys).union([profileKey])
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

/// Logins the codex-logins registry sets aside for one consumer each, such as a benchmark director with
/// its own device-code home. Lending one would share its rate limit with another consumer, so none is
/// ever leased, and no lease goes into a registered home.
private struct ReservedLogins {
    let profileKeys: Set<String>
    let homes: [String]

    struct Unreadable: Error {}

    /// A missing registry reserves nothing. One that does not parse, or lists a login without a
    /// profile key, throws, so that callers fail closed as `codex-logins.py check-switch` does.
    static func load(from url: URL, homeURL: URL) throws -> ReservedLogins {
        guard !CodexFileProbe.isMissing(url) else {
            return ReservedLogins(profileKeys: [], homes: [])
        }
        guard let root = readJSON(url), let logins = root["logins"] as? [[String: Any]] else {
            throw Unreadable()
        }
        var profileKeys = Set<String>()
        var homes: [String] = []
        for login in logins {
            guard let profileKey = login["profile_key"] as? String, !profileKey.isEmpty else {
                throw Unreadable()
            }
            profileKeys.insert(profileKey)
            if let home = login["codex_home"] as? String, !home.isEmpty {
                homes.append(home == "~" || home.hasPrefix("~/")
                    ? homeURL.path + home.dropFirst()
                    : home)
            }
        }
        return ReservedLogins(profileKeys: profileKeys, homes: homes)
    }

    /// Registry entries whose key no Switchboard account has any more, for example after a new sign-in
    /// re-keyed the account. While one exists, nothing can tell which account it means.
    func staleKeys(among accountKeys: Set<String>) -> Set<String> {
        profileKeys.subtracting(accountKeys)
    }
}

/// The codex-logins registry, for the app's switch and auto-swap checks. An unreadable registry
/// reserves nothing here: `holder.lock` still marks every home a holder has used, and a reserved
/// account only shares its quota with a switch, not its token chain.
public enum CodexReservedLogins {
    /// Nil when the registry exists but cannot be read.
    public static func homes(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String]? {
        load(homeURL: homeURL)?.homes
    }

    public static func profileKeys(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        load(homeURL: homeURL)?.profileKeys ?? []
    }

    private static func load(homeURL: URL) -> ReservedLogins? {
        try? ReservedLogins.load(
            from: homeURL.appendingPathComponent(".config/codex-logins/registry.json"),
            homeURL: homeURL
        )
    }
}

/// Lends one account's captured auth to a separate CODEX_HOME and takes it back. A refresh token is
/// single-use, so two live copies of one chain log each other out: a lease home must be the account's
/// only live holder, and the stored profile must end up with the home's latest rotated token.
///
/// Every operation on a home holds, in this order, Switchboard's `.auth.lock`, the home's
/// `holder.lock` (taken without waiting, so a live run refuses it), and the home's `auth.json.lock`.
/// Output names accounts by handle: profile keys embed the account's email.
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

    func lease(profileKey given: String, home rawHome: String, holder: String) throws -> LeasePayload {
        let requestedHome = Self.standardized(rawHome)
        try ensureLeaseHomeAllowed(requestedHome)

        return try withStoreLock {
            let leases = try paths.leaseStore.load()
            let profileKey = try resolveAccount(given)
            let handle = CodexAccountHandle.handle(for: profileKey)
            if let existing = leases.first(where: { $0.profileKey == profileKey }) {
                throw refused("already_leased", "\(handle) is already leased to \(existing.holder) at \(existing.home).")
            }
            if let existing = leases.first(where: { CodexLease.sameHome($0.home, requestedHome) }) {
                throw refused("home_already_leased", "\(requestedHome) already holds the lease of \(existing.holder).")
            }
            let (profile, profileAuth) = try ensureCanLend(profileKey: profileKey, into: requestedHome)
            let configURL = URL(fileURLWithPath: requestedHome).appendingPathComponent("config.toml")
            let configText = try leaseConfigText(at: configURL, home: requestedHome)

            if CodexLeaseHome.isQuarantined(home: requestedHome) {
                throw quarantined(requestedHome)
            }
            try paths.ensureDirectory(URL(fileURLWithPath: requestedHome, isDirectory: true), permissions: 0o700)
            let home = CodexLease.normalizedHome(requestedHome)
            let authURL = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")

            return try withHolder(home) {
                try ensureNotInUse(home)
                return try withHomeLock(home) {
                    if CodexLeaseHome.isQuarantined(home: home) {
                        throw quarantined(home)
                    }
                    let alreadyHeld = try homeAlreadyHolds(profileAuth, at: authURL)
                    var lease = CodexLease(
                        profileKey: profileKey,
                        home: home,
                        holder: holder,
                        profileDirectory: profile.profileURL.lastPathComponent,
                        state: alreadyHeld ? .active : .leasing,
                        authWritten: alreadyHeld
                    )
                    // The marker first, then the journal, then config.toml, then auth.json: a crash at any
                    // point leaves a home that return recognises, and the chain is lent only last.
                    try CodexLeaseMarker(lease: lease).write(home: home)
                    try paths.leaseStore.save(leases + [lease])
                    var configWritten = false
                    do {
                        if configText == nil {
                            try CodexAtomicFile.write(Data(Self.leaseConfig.utf8), to: configURL)
                            configWritten = true
                        }
                        if !alreadyHeld {
                            try CodexAtomicFile.write(try Data(contentsOf: profile.authURL), to: authURL)
                        }
                    } catch {
                        try? paths.leaseStore.save(leases)
                        throw error
                    }
                    if !alreadyHeld {
                        lease.state = .active
                        lease.authWritten = true
                        do {
                            try paths.leaseStore.save(leases + [lease])
                        } catch {
                            // The home holds the chain while the journal still says leasing, so a holder that
                            // later empties the home would make return drop the chain. Return it before use.
                            throw refused(
                                "lease_incomplete",
                                "\(handle)'s auth was written to \(home), but the lease could not be marked active: \(error.localizedDescription) Do not use the home; run return for it."
                            )
                        }
                    }
                    return LeasePayload(
                        generatedAt: Date(),
                        handle: handle,
                        leaseID: lease.leaseID,
                        home: home,
                        holder: holder,
                        leasedAt: lease.leasedAt,
                        authStorePath: authURL.path,
                        authWritten: !alreadyHeld,
                        configWritten: configWritten
                    )
                }
            }
        }
    }

    /// Return is also the only recovery path: it always re-reads the home, so repeating a return that
    /// crashed brings back any rotation made since.
    func returnLease(profileKey given: String, home rawHome: String) throws -> LeaseReturnPayload {
        let requestedHome = Self.standardized(rawHome)

        return try withStoreLock {
            let leases = try paths.leaseStore.load()
            let profileKey = CodexAccountHandle.resolve(given, among: leases.map(\.profileKey)) ?? given
            guard let lease = leases.first(where: { $0.profileKey == profileKey }) else {
                throw refused("not_leased", "\(Self.display(given)) has no active lease.")
            }
            guard CodexLease.sameHome(lease.home, requestedHome) else {
                throw refused(
                    "home_mismatch",
                    "\(CodexAccountHandle.handle(for: profileKey)) is leased at \(lease.home), not \(requestedHome)."
                )
            }
            // From here until the entry is removed the lease is returning, which every reader treats as
            // leased. A return that stops on any refusal, a busy holder included, is redone later from a
            // fresh read of the home.
            var returning = lease
            var journal = leases
            if returning.state != .returning {
                returning.state = .returning
                journal = leases.map { $0.leaseID == lease.leaseID ? returning : $0 }
                try paths.leaseStore.save(journal)
            }
            return try withHolder(returning.home) {
                try ensureMarkerMatches(returning)
                try ensureNotInUse(returning.home)
                return try withHomeLock(returning.home) {
                    try finishReturn(returning, leases: journal)
                }
            }
        }
    }

    /// Copies the home's tokens into the stored profile, tombstones the home's auth and removes the
    /// lease. Callers hold all three locks.
    private func finishReturn(_ lease: CodexLease, leases: [CodexLease]) throws -> LeaseReturnPayload {
        let handle = CodexAccountHandle.handle(for: lease.profileKey)
        if CodexLeaseHome.isQuarantined(home: lease.home) {
            throw quarantined(lease.home)
        }

        let outcome: CodexLeaseSyncOutcome
        if let tombstone = CodexLeaseTombstone.leaseID(at: lease.authURL) {
            guard tombstone == lease.leaseID || !lease.authWritten else {
                throw refused(
                    "home_auth_missing",
                    "\(lease.authURL.path) holds an earlier lease's tombstone, so this lease's token is not there. Nothing was changed; the lease stays returning."
                )
            }
            outcome = .homeReturned
        } else if CodexFileProbe.isMissing(lease.authURL) || CodexLeaseHome.holdsNoTokens(authURL: lease.authURL) {
            // A lease that never left leasing lent nothing, so there is nothing to copy. Any other lease's
            // chain is now somewhere Switchboard cannot see, such as a keychain store.
            guard !lease.authWritten else {
                throw refused(
                    "home_auth_missing",
                    "\(lease.authURL.path) is gone or holds no token, so the home's latest token may be somewhere Switchboard cannot see. Nothing was changed; the lease stays returning and the account stays unleasable."
                )
            }
            outcome = .homeAuthMissing
        } else {
            let synced = try CodexLeaseSync.syncHome(lease, appSupportURL: paths.appSupportURL)
            switch synced {
            case .rotated, .unchanged:
                try CodexLeaseTombstone.write(leaseID: lease.leaseID, to: lease.authURL)
            case .homeReturned:
                break
            case .homeAuthMissing:
                throw refused(
                    "home_auth_missing",
                    "\(lease.authURL.path) disappeared during the return. Nothing was changed; the lease stays returning."
                )
            case .homeQuarantined:
                throw quarantined(lease.home)
            case .identityMismatch:
                throw refused(
                    "home_holds_other_account",
                    "\(lease.authURL.path) now holds a different account. Nothing was synced or removed; the lease stays returning."
                )
            case .homeAuthUnreadable:
                throw refused(
                    "home_auth_unreadable",
                    "\(lease.authURL.path) cannot be read as Codex auth. Nothing was removed; the lease stays returning."
                )
            case .storedProfileMissing:
                throw refused(
                    "stored_profile_missing",
                    "The captured profile for \(handle) is gone, so the lease home holds the only copy. Nothing was removed; the lease stays returning."
                )
            }
            outcome = synced
        }

        try paths.leaseStore.save(leases.filter { $0.leaseID != lease.leaseID })
        return LeaseReturnPayload(
            generatedAt: Date(),
            handle: handle,
            leaseID: lease.leaseID,
            home: lease.home,
            holder: lease.holder,
            leasedAt: lease.leasedAt,
            sync: outcome.rawValue,
            homeAuthTombstoned: outcome == .rotated || outcome == .unchanged
        )
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
                    handle: CodexAccountHandle.handle(for: lease.profileKey),
                    leaseID: lease.leaseID,
                    state: lease.state.rawValue,
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
                    holderRunning: CodexHomeHolderLock.isHeld(home: lease.home),
                    activeOnSurface: activeKeys.contains(lease.profileKey),
                    quarantined: CodexLeaseHome.isQuarantined(home: lease.home),
                    quarantinedSince: CodexLeaseHome.quarantinedSince(home: lease.home)
                )
            }
        )
    }

    /// Marks the accounts an agent could lease now: unleased (a returning lease counts), not registry-reserved,
    /// a known paid plan, usable quota, no re-login needed, not being refreshed by the app (no live refresh
    /// reservation), and with no chain in a Codex home a surface uses or a switch wrote. Nothing is leasable
    /// while the lease store, the registry, one of those homes' auth.json or the switch record cannot be read,
    /// while the registry reserves a key no account has, or while a surface keeps its sign-in in a keychain.
    func annotateLeasable(_ accounts: [AccountPayload]) -> [AccountPayload] {
        let storeReadable = (try? paths.leaseStore.load()) != nil
        let reserved = try? ReservedLogins.load(from: paths.reservedLoginsURL, homeURL: paths.homeURL)
        let registryUsable = reserved.map { $0.staleKeys(among: Set(accounts.map(\.profileKey))).isEmpty } ?? false
        let live = surfaceService.liveChains()
        let surfaces = surfaceService.statuses(scope: .all)
        let surfacesKnown = !surfaces.contains { $0.detected && !$0.supportsFileSwitching }
        let activeKeys = Set(surfaces.compactMap(\.activeProfileKey)).union(live.keys)
        let reservations = CodexRefreshReservations(appSupportURL: paths.appSupportURL)
        let appPIDs = Set(runningSwitchboardAppPIDs())
        return accounts.map { account in
            var account = account
            account.reserved = reserved?.profileKeys.contains(account.profileKey) ?? false
            account.leasable = storeReadable
                && !live.unknown
                && surfacesKnown
                && registryUsable
                && !account.reserved
                && !account.leased
                && account.isKnownPaidPlan
                && account.usableForCodex
                && !account.needsRelogin
                && !activeKeys.contains(account.profileKey)
                && !reservations.isReserved(profileKey: account.profileKey, runningAppPIDs: appPIDs)
            return account
        }
    }

    /// Returns the account leased at `home` and leases another into the same home, for a lane whose
    /// account runs low, under one hold of the home's locks. Only the lease's holder swaps it, since its
    /// run records name the account each run used; the check is advisory and catches mistakes. The new
    /// lease keeps that holder.
    func swapLease(
        home rawHome: String,
        to requestedKey: String?,
        excluding excludedGiven: Set<String>,
        holder: String
    ) throws -> LeaseSwapPayload {
        let requestedHome = Self.standardized(rawHome)

        return try withStoreLock {
            let leases = try paths.leaseStore.load()
            guard let current = leases.first(where: { CodexLease.sameHome($0.home, requestedHome) }) else {
                throw refused("no_lease_at_home", "\(requestedHome) holds no lease; use lease for its first account.")
            }
            guard current.holder == holder else {
                throw refused("holder_mismatch", "\(current.home) is leased to \(current.holder); only that holder swaps its account.")
            }
            if CodexLeaseHome.isQuarantined(home: current.home) {
                throw quarantined(current.home)
            }
            let excludedKeys = Set(try excludedGiven.map { try resolveAccount($0) })
            // An unusable registry makes nothing leasable; say so instead of no_candidate.
            try ensureRegistryUsable()
            let candidates = annotateLeasable(accountStore.accounts())
            let targetKey: String
            if let requestedKey {
                targetKey = try resolveAccount(requestedKey)
                guard !excludedKeys.contains(targetKey) else {
                    throw CLIError.usage("--profile-key \(Self.display(requestedKey)) is also excluded.", jsonPreferred: false)
                }
            } else {
                guard let best = candidates
                    .filter({ $0.leasable && $0.profileKey != current.profileKey && !excludedKeys.contains($0.profileKey) })
                    .max(by: { ($0.score, $0.sessionFreePercent) < ($1.score, $1.sessionFreePercent) }) else {
                    throw refused("no_candidate", "No other paid, usable, unleased account is free to lease.")
                }
                targetKey = best.profileKey
            }
            let targetHandle = CodexAccountHandle.handle(for: targetKey)
            guard targetKey != current.profileKey else {
                throw refused("same_account", "\(targetHandle) is already the account leased at \(current.home).")
            }
            // Check the target before giving anything back, so a refusal leaves the lane as it was.
            try ensureNotReserved(profileKey: targetKey, home: current.home)
            if let target = candidates.first(where: { $0.profileKey == targetKey }), !target.leasable {
                try ensureLeasableAccount(profileKey: targetKey)
                if target.leased {
                    throw refused("already_leased", "\(targetHandle) cannot be leased now: it is already leased.")
                }
                // Names the precise reason, such as an active account or an app refresh in flight.
                _ = try ensureCanLend(profileKey: targetKey, into: current.home)
                throw refused("not_usable", "\(targetHandle) cannot be leased now: it has no usable quota left.")
            }
            try ensureLeaseHomeAllowed(current.home)
            _ = try ensureCanLend(profileKey: targetKey, into: current.home)
            _ = try leaseConfigText(
                at: URL(fileURLWithPath: current.home).appendingPathComponent("config.toml"),
                home: current.home
            )

            return try withHolder(current.home) {
                try ensureMarkerMatches(current)
                try ensureNotInUse(current.home)
                return try withHomeLock(current.home) {
                    let returned = try returnLease(profileKey: current.profileKey, home: current.home)
                    let leased: LeasePayload
                    do {
                        leased = try lease(profileKey: targetKey, home: current.home, holder: current.holder)
                    } catch CLIError.refused(code: "lease_incomplete", let message, let details) {
                        throw CLIError.refused(
                            code: "lease_incomplete",
                            message: "Returned \(returned.handle) from \(current.home). \(message)",
                            details: details
                        )
                    } catch {
                        throw refused(
                            "swap_incomplete",
                            "Returned \(returned.handle) from \(current.home), but leasing \(targetHandle) failed: \(error.localizedDescription) The home now holds no account."
                        )
                    }
                    return LeaseSwapPayload(
                        generatedAt: Date(),
                        home: leased.home,
                        holder: leased.holder,
                        returnedHandle: returned.handle,
                        returnSync: returned.sync,
                        leasedHandle: leased.handle,
                        leaseID: leased.leaseID,
                        leasedAt: leased.leasedAt
                    )
                }
            }
        }
    }

    /// What lease writes into a home without a config.toml. The file store keeps the chain in the home
    /// (a keychain store would move it out of sight). A nested `codex` started by a tool inherits
    /// CODEX_HOME, so it gets a path that does not exist and fails at startup instead of becoming a
    /// second holder of this home's sign-in.
    static let leaseConfig = """
    # Written by Codex Switchboard for a lease of this home.
    cli_auth_credentials_store = "file"

    [shell_environment_policy]
    set = { CODEX_HOME = "/var/empty/codex-switchboard-lease-no-nested-codex" }

    """

    private static func standardized(_ rawHome: String) -> String {
        URL(fileURLWithPath: (rawHome as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    /// A key given on the command line, shown without its email: handles stay, keys become handles.
    /// A well-formed handle is shown as given; anything else, which may embed an email, by its handle.
    private static func display(_ given: String) -> String {
        given.range(of: "^acct_[0-9a-f]{12}$", options: .regularExpression) != nil
            ? given
            : CodexAccountHandle.handle(for: given)
    }

    private func refused(_ code: String, _ message: String, details: [String]? = nil) -> CLIError {
        CLIError.refused(code: code, message: message, details: details)
    }

    private func resolveAccount(_ given: String) throws -> String {
        guard let profileKey = CodexAccountHandle.resolve(given, among: accountStore.accounts().map(\.profileKey)) else {
            throw refused("unknown_profile", "\(Self.display(given)) is not in Switchboard's account list.")
        }
        return profileKey
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try CodexAuthStoreLock.withRequiredLock(appSupportURL: paths.appSupportURL, timeout: paths.storeLockTimeout, body)
        } catch let error as POSIXError where error.code == .EBUSY {
            throw refused(
                "auth_store_locked",
                "Another Switchboard process kept \(CodexAuthStoreLock.fileName) locked for \(Int(paths.storeLockTimeout)) s. Nothing was changed; try again."
            )
        }
    }

    /// Takes the home's `holder.lock` without waiting and keeps it for the whole operation.
    private func withHolder<T>(_ home: String, _ body: () throws -> T) throws -> T {
        do {
            return try CodexHomeHolderLock.withLock(home: home, body)
        } catch CodexHomeAuthLockError.busy {
            let holders = (try? consumerProcesses(usingHome: home)) ?? []
            throw refused(
                "home_in_use",
                "A process holds \(home)/\(CodexLeaseHome.holderLockFileName): a run is live there. Nothing was changed.",
                details: holders.map { "\($0.pid) \(programName(of: $0.command))" }
            )
        } catch let error as CodexHomeAuthLockError {
            throw refused("home_lock_unavailable", "\(error.localizedDescription) Nothing was changed.")
        }
    }

    /// Takes the home holder's auth lock, waiting up to the configured timeout.
    private func withHomeLock<T>(_ home: String, _ body: () throws -> T) throws -> T {
        do {
            return try CodexHomeAuthLock.withLock(home: home, timeout: paths.homeLockTimeout, body)
        } catch CodexHomeAuthLockError.busy {
            throw refused(
                "home_locked",
                "The process holding \(home) kept \(CodexLeaseHome.lockFileName) locked for \(Int(paths.homeLockTimeout)) s, probably while refreshing its token. Nothing was changed; try again."
            )
        } catch let error as CodexHomeAuthLockError {
            throw refused("home_lock_unavailable", "\(error.localizedDescription) Nothing was changed.")
        }
    }

    /// A process started without `holder.lock` (a bare `CODEX_HOME=<home> codex`) is caught here: it
    /// keeps files open in the home, or names the home in its environment.
    private func ensureNotInUse(_ home: String) throws {
        let consumers: [ProcessInfoPayload]
        do {
            consumers = try consumerProcesses(usingHome: home)
        } catch {
            throw refused(
                "home_scan_failed",
                "Could not check which processes use \(home): \(error.localizedDescription) Nothing was changed."
            )
        }
        guard consumers.isEmpty else {
            // Only pid and program name: a full command line can carry a prompt with secrets in it.
            throw refused(
                "home_in_use",
                "Processes are still using \(home); stop them, then try again.",
                details: consumers.map { "\($0.pid) \(programName(of: $0.command))" }
            )
        }
    }

    /// The journal names the lease at a home; the home's `lease.json`, when present, must name the same
    /// lease, so a copied or re-used home is not mistaken for this one.
    private func ensureMarkerMatches(_ lease: CodexLease) throws {
        let marker: CodexLeaseMarker?
        do {
            marker = try CodexLeaseMarker.read(home: lease.home)
        } catch {
            throw refused("lease_marker_unreadable", "\(lease.home)/\(CodexLeaseHome.markerFileName) cannot be read. Nothing was changed.")
        }
        if let marker, marker.leaseID != lease.leaseID {
            throw refused(
                "lease_id_mismatch",
                "\(lease.home)/\(CodexLeaseHome.markerFileName) names another lease than the journal does. Nothing was changed."
            )
        }
    }

    private func quarantined(_ home: String) -> CLIError {
        refused(
            "home_quarantined",
            "\(home) holds \(CodexLeaseHome.stoppedSentinelName): its holder stopped after a credential failure, so the token chain there may be spent. Nothing was synced, written or removed. Only the holder's owner removes that file, after diagnosis."
        )
    }

    private func ensureRegistryUsable() throws {
        _ = try usableRegistry()
    }

    private func ensureNotReserved(profileKey: String, home: String?) throws {
        let reserved = try usableRegistry()
        if reserved.profileKeys.contains(profileKey) {
            throw refused(
                "reserved_account",
                "\(CodexAccountHandle.handle(for: profileKey)) is reserved in the codex-logins registry for its own consumer."
            )
        }
        if let home, reserved.homes.contains(where: { CodexLease.sameHome($0, home) }) {
            throw refused("home_reserved", "\(home) is a reserved login's home in the codex-logins registry.")
        }
    }

    private func usableRegistry() throws -> ReservedLogins {
        let reserved: ReservedLogins
        do {
            reserved = try ReservedLogins.load(from: paths.reservedLoginsURL, homeURL: paths.homeURL)
        } catch {
            throw refused(
                "reserved_registry_unreadable",
                "\(paths.reservedLoginsURL.path) cannot be read or lists a login without a profile_key; refusing to guess which accounts are reserved."
            )
        }
        if !reserved.staleKeys(among: Set(accountStore.accounts().map(\.profileKey))).isEmpty {
            throw refused(
                "reserved_registry_stale",
                "\(paths.reservedLoginsURL.path) reserves an account Switchboard no longer lists under that key (a new sign-in can re-key an account); refusing to guess which account it means. Register that login again, then lease."
            )
        }
        return reserved
    }

    /// Everything about the account and the surfaces that lease requires, checked again by swap-lease
    /// before it gives the lane's account back, so that a refusal leaves the lane as it was.
    private func ensureCanLend(profileKey: String, into home: String) throws -> (CapturedProfile, StoredAuth) {
        let handle = CodexAccountHandle.handle(for: profileKey)
        try ensureNotReserved(profileKey: profileKey, home: home)
        if CodexRefreshReservations(appSupportURL: paths.appSupportURL)
            .isReserved(profileKey: profileKey, runningAppPIDs: Set(runningSwitchboardAppPIDs())) {
            throw refused(
                "refresh_in_progress",
                "Switchboard is refreshing the token of \(handle) right now; try again in a few seconds."
            )
        }
        let surfaces = surfaceService.statuses(scope: .all)
        if surfaces.contains(where: { $0.activeProfileKey == profileKey }) {
            throw refused(
                "active_account",
                "\(handle) is the active CLI or Desktop account; lease an account no surface is using."
            )
        }
        let live = surfaceService.liveChains()
        if live.keys.contains(profileKey) {
            throw refused(
                "active_account",
                "\(handle) is signed in to ~/.codex or a Codex home a switch wrote; lease an account no Codex home holds."
            )
        }
        if live.unknown {
            throw refused(
                "surface_identity_unknown",
                "A Codex home that a surface uses or a switch wrote holds an auth.json Switchboard cannot read, so it cannot tell which account that home holds. Try again in a moment; if it persists, check that home."
            )
        }
        if let unknown = surfaces.first(where: { $0.detected && !$0.supportsFileSwitching }) {
            throw refused(
                "surface_identity_unknown",
                "The \(unknown.displayName) keeps its sign-in in a \(unknown.authStoreMode) store, so Switchboard cannot tell which account it uses and could lease that account."
            )
        }
        try ensureLeasableAccount(profileKey: profileKey)
        try ensureOneKeyPerSeat(profileKey: profileKey)
        try ensureAppMirrorsLeases()
        let profile = try CapturedProfileStore(paths: paths).profile(sourceProfileKey: profileKey)
        guard let profileAuth = StoredAuth.load(from: profile.authURL), profileAuth.hasCompleteTokens else {
            throw CLIError.failure(message: "Captured profile is missing valid redacted identity fields.", jsonPreferred: true)
        }
        try ensureStoredCopiesAgree(profileKey: profileKey, profileAuth: profileAuth)
        return (profile, profileAuth)
    }

    /// Every check of a lease runs on its profile key, so a seat listed under a second key would let
    /// that key be switched to, refreshed or leased while its chain is out.
    private func ensureOneKeyPerSeat(profileKey: String) throws {
        guard let profiles = readJSON(paths.accountsURL)?["profiles"] as? [String: [String: Any]],
              let entry = profiles[profileKey],
              let accountID = entry["accountId"] as? String, !accountID.isEmpty,
              let email = (entry["email"] as? String)?.lowercased(), !email.isEmpty else {
            return
        }
        let others = profiles.filter { key, value in
            key != profileKey
                && value["accountId"] as? String == accountID
                && (value["email"] as? String)?.lowercased() == email
        }
        guard others.isEmpty else {
            throw refused(
                "duplicate_account_keys",
                "Switchboard lists \(CodexAccountHandle.handle(for: profileKey))'s seat under more than one key. Remove the account in the Switchboard app, which removes every key of the seat, sign in to it again, then lease."
            )
        }
    }

    /// The config.toml a lease relies on: absent (lease writes its own), or one that keeps Codex on the
    /// file store and gives nested commands a CODEX_HOME of their own. Anything else is refused, since
    /// a keychain store moves the chain out of sight and a nested `codex` would share it.
    private func leaseConfigText(at configURL: URL, home: String) throws -> String? {
        if CodexFileProbe.isMissing(configURL) { return nil }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw refused(
                "home_config_unsafe",
                "\(configURL.path) cannot be read, so Switchboard cannot check it. Move it away, then lease again."
            )
        }
        let mode = CodexCredentialStoreMode.resolve(config: text, surface: .cli)
        guard mode == "file" else {
            throw CLIError.unsupportedMode(surface: "lease home", mode: mode, path: home, jsonPreferred: true)
        }
        guard Self.keepsLeaseOnFileStore(text),
              let nested = Self.nestedCodexHome(text),
              !CodexLease.sameHome(nested, home),
              CodexFileProbe.isMissing(URL(fileURLWithPath: nested)) else {
            throw refused(
                "home_config_unsafe",
                "\(configURL.path) must set cli_auth_credentials_store = \"file\" and, under [shell_environment_policy], set CODEX_HOME to a path that does not exist, so a nested codex cannot share this home's sign-in. Add both, or move the file away so lease writes its own."
            )
        }
        return text
    }

    static func keepsLeaseOnFileStore(_ config: String) -> Bool {
        config.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*"file""#, options: .regularExpression) != nil
    }

    /// The `CODEX_HOME` that `[shell_environment_policy]` sets for commands Codex runs, if any.
    static func nestedCodexHome(_ config: String) -> String? {
        var section = ""
        for rawLine in config.split(separator: "\n") {
            let line = (rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.replacingOccurrences(of: " ", with: "")
                continue
            }
            let pattern: String
            switch section {
            case "[shell_environment_policy]" where line.hasPrefix("set"):
                pattern = #"[{,]\s*CODEX_HOME\s*=\s*"([^"]+)""#
            case "[shell_environment_policy.set]":
                pattern = #"^CODEX_HOME\s*=\s*"([^"]+)""#
            default:
                continue
            }
            if let match = line.range(of: pattern, options: .regularExpression) {
                let assignment = String(line[match])
                if let open = assignment.firstIndex(of: "\""), let close = assignment.lastIndex(of: "\""), open < close {
                    let value = String(assignment[assignment.index(after: open)..<close])
                    // A TOML escape would make Codex read a different path than the one checked here.
                    return value.contains("\\") ? nil : value
                }
            }
        }
        return nil
    }

    /// The captured profile is what lease copies. If its token differs from the account list's, an
    /// earlier write stopped halfway and the captured token may already be spent.
    private func ensureStoredCopiesAgree(profileKey: String, profileAuth: StoredAuth) throws {
        guard let root = readJSON(paths.accountsURL),
              let entry = (root["profiles"] as? [String: Any])?[profileKey] as? [String: Any],
              let listed = entry["refresh"] as? String, !listed.isEmpty else {
            return
        }
        guard listed == profileAuth.refreshToken else {
            throw refused(
                "stored_copies_disagree",
                "Switchboard's stored copies of \(CodexAccountHandle.handle(for: profileKey)) hold different tokens, so the one lease would copy may be spent. Open Switchboard so it refreshes the account, then lease again."
            )
        }
    }

    private func ensureLeaseHomeAllowed(_ home: String) throws {
        func refuse(_ reason: String) -> CLIError {
            refused("home_not_allowed", "Cannot lease into \(home): \(reason)")
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
        let handle = CodexAccountHandle.handle(for: profileKey)
        guard let account = accountStore.accounts().first(where: { $0.profileKey == profileKey }) else {
            throw refused("unknown_profile", "\(handle) is not in Switchboard's account list.")
        }
        if account.isFreePlan {
            throw refused("free_plan", "\(handle) is a free-plan account.")
        }
        if !account.isKnownPaidPlan {
            throw refused(
                "plan_unknown",
                "\(handle) has no known paid plan yet; open Switchboard to refresh usage, then lease again."
            )
        }
        if account.needsRelogin {
            throw refused("needs_relogin", "\(handle) needs a new sign-in.")
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
            throw refused(
                "app_not_lease_aware",
                "A running Codex Switchboard app does not mirror leases: it predates them or uses other storage, and it would refresh the leased token itself. Update or quit the app, then lease again."
            )
        }
    }

    /// Never overwrites another sign-in: only an exact copy of the stored token, or a return's
    /// tombstone, counts as free to write over.
    private func homeAlreadyHolds(_ profileAuth: StoredAuth, at authURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: authURL.path) else { return false }
        if CodexLeaseTombstone.leaseID(at: authURL) != nil {
            return false
        }
        guard let homeAuth = StoredAuth.load(from: authURL) else {
            throw refused("home_auth_unreadable", "\(authURL.path) exists and cannot be read as Codex auth; move it away first.")
        }
        if homeAuth.hasSameTokens(as: profileAuth) {
            return true
        }
        if homeAuth.identity.matches(profileAuth.identity) {
            throw refused(
                "home_holds_other_login",
                "\(authURL.path) holds a separate sign-in for this account; leasing over it would discard that sign-in."
            )
        }
        throw refused("home_holds_other_account", "\(authURL.path) holds a different account's auth.")
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
            throw CLIError.failure(message: "Captured auth was not found for \(CodexAccountHandle.handle(for: sourceProfileKey)).", jsonPreferred: true)
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
    var handle = ""
    var leased = false
    var leaseHolder: String?
    var leaseQuarantined = false
    var reserved = false
    var leasable = false

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile_key"
        case handle
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
        case leaseQuarantined = "lease_quarantined"
        case reserved
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
    func autoSwapAccount(reserved: Bool) -> AutoSwapAccount {
        AutoSwapAccount(
            profileKey: profileKey,
            sessionFreePercent: sessionFreePercent,
            weeklyFreePercent: weeklyFreePercent,
            usableForCodex: usableForCodex,
            needsRelogin: needsRelogin,
            isFreePlan: isFreePlan,
            score: score,
            isLeased: leased || reserved
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
    let handle: String
    let leaseID: String
    let home: String
    let holder: String
    let leasedAt: Date
    let authStorePath: String
    let authWritten: Bool
    let configWritten: Bool

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case handle
        case leaseID = "lease_id"
        case home
        case holder
        case leasedAt = "leased_at"
        case authStorePath = "auth_store_path"
        case authWritten = "auth_written"
        case configWritten = "config_written"
    }
}

private struct LeaseReturnPayload: Codable {
    let generatedAt: Date
    let handle: String
    let leaseID: String
    let home: String
    let holder: String
    let leasedAt: Date
    let sync: String
    let homeAuthTombstoned: Bool

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case handle
        case leaseID = "lease_id"
        case home
        case holder
        case leasedAt = "leased_at"
        case sync
        case homeAuthTombstoned = "home_auth_tombstoned"
    }
}

private struct LeaseStatusPayload: Codable {
    let handle: String
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

    enum CodingKeys: String, CodingKey {
        case handle
        case leaseID = "lease_id"
        case state
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
        case holderRunning = "holder_running"
        case activeOnSurface = "active_on_surface"
        case quarantined
        case quarantinedSince = "quarantined_since"
    }
}

private struct LeaseSwapPayload: Codable {
    let generatedAt: Date
    let home: String
    let holder: String
    let returnedHandle: String
    let returnSync: String
    let leasedHandle: String
    let leaseID: String
    let leasedAt: Date

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case home
        case holder
        case returnedHandle = "returned_handle"
        case returnSync = "return_sync"
        case leasedHandle = "leased_handle"
        case leaseID = "lease_id"
        case leasedAt = "leased_at"
    }
}

/// `status --leasable-only`: what an agent needs to pick an account to lease, named by handle only.
private struct LeasableAccountPayload: Codable {
    let handle: String
    let plan: String
    let sessionFreePercent: Double
    let weeklyFreePercent: Double
    let quotaWindows: [QuotaWindowPayload]
    let score: Double
    let nextResetAt: Date?

    enum CodingKeys: String, CodingKey {
        case handle
        case plan
        case sessionFreePercent = "session_free_percent"
        case weeklyFreePercent = "weekly_free_percent"
        case quotaWindows = "quota_windows"
        case score
        case nextResetAt = "next_reset_at"
    }

    init(_ account: AccountPayload) {
        handle = account.handle
        plan = account.plan
        sessionFreePercent = account.sessionFreePercent
        weeklyFreePercent = account.weeklyFreePercent
        quotaWindows = account.quotaWindows
        score = account.score
        nextResetAt = account.nextResetAt
    }
}

private struct LeasableStatusPayload: Codable {
    let generatedAt: Date
    let accounts: [LeasableAccountPayload]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case accounts
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
    case leasableStatus(LeasableStatusPayload)
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
            case let .leasableStatus(value):
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
        case let .leasableStatus(value):
            text = (["leasable accounts: \(value.accounts.count)"] + value.accounts.map { "\($0.handle) \($0.plan)" })
                .joined(separator: "\n")
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
private func consumerProcesses(usingHome home: String) throws -> [ProcessInfoPayload] {
    let commands = Dictionary(
        processLinesWithPID().map { ($0.pid, $0.command) },
        uniquingKeysWith: { first, _ in first }
    )
    var pids = Set(try CodexLease.homeSpellings(home).flatMap(openFileHolderPIDs(in:)))

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

/// Owners of numbered file descriptors on files anywhere under `directory`. A working directory or
/// program text there does not count, so a shell sitting in the home is not a user.
private func openFileHolderPIDs(in directory: String) throws -> [Int32] {
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    var holders = Set<Int32>()
    var pid: Int32?
    // lsof exits 1 even when it lists holders, so its output is read whatever the status; a scan that
    // cannot start, is killed or times out throws instead of reading as "no holders".
    let output = try run("/usr/sbin/lsof", ["-w", "-Fpf", "+D", directory], timeout: 30, acceptingFailure: true)
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
    // A killed or timed-out helper never gives an answer, even to a caller that accepts failure.
    if process.terminationReason == .uncaughtSignal {
        throw CLIError.failure(message: "\(URL(fileURLWithPath: launchPath).lastPathComponent) was stopped before it finished.", jsonPreferred: true)
    }
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
