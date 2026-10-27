import AppKit
import SwiftUI

struct LeaseAction: Identifiable {
    let lease: AppLease
    let target: AppLeaseAccount?
    var id: String { lease.id + (target?.handle ?? "return") }
    var confirmation: String {
        if let target { return "Swap \(lease.holder)'s lease from \(lease.displayName) to \(target.displayName)?" }
        return "Return \(lease.displayName) from \(lease.holder)? The lane at \(lease.home) loses its sign-in."
    }
}

@MainActor
final class LeasesViewModel: ObservableObject {
    @Published private(set) var leases: [AppLease] = []
    @Published private(set) var accounts: [AppLeaseAccount] = []
    @Published private(set) var error: String?
    @Published private(set) var actionError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published var pendingAction: LeaseAction?
    private let client: SwitchboardCLIClient
    private var refreshAgain = false
    var unavailableReason: String? { client.executableURL == nil ? SwitchboardCLIClient.missingCLIMessage : nil }

    init(client: SwitchboardCLIClient = SwitchboardCLIClient()) { self.client = client }

    func status(for account: Account) -> AppLeaseAccount? {
        accounts.first { $0.profileKey == account.profileKey }
    }

    func refresh() async {
        guard !isRefreshing else { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            // Both reads happen off the main thread, even if the first read fails.
            let result = await Task.detached(priority: .utility) { [client] in
                (Result { try client.leases() }, Result { try client.status() })
            }.value
            var messages: [String] = []
            switch result.0 {
            case .success(let payload): leases = payload.leases
            case .failure(let failure): messages.append(failure.localizedDescription)
            }
            switch result.1 {
            case .success(let payload): accounts = payload.accounts
            case .failure(let failure):
                accounts = [] // Never offer swaps from stale eligibility.
                messages.append(failure.localizedDescription)
            }
            error = messages.first
        } while refreshAgain
    }

    func perform(_ action: LeaseAction) async {
        guard !isBusy else { return }
        pendingAction = nil
        isBusy = true
        actionError = nil
        do {
            try await Task.detached(priority: .utility) { [client] in
                if let target = action.target { try client.swapLease(action.lease, to: target) }
                else { try client.returnLease(action.lease) }
            }.value
        } catch { actionError = error.localizedDescription }
        await refresh()
        isBusy = false
    }

    func dismissActionError() { actionError = nil }
}

struct LeasesSection: View {
    let leases: [AppLease]
    let accounts: [AppLeaseAccount]
    var isCollapsed = false
    var isBusy = false
    var unavailableReason: String? = nil
    var toggle: () -> Void = {}
    var requestAction: (LeaseAction) -> Void = { _ in }
    var revealHome: (String) -> Void = { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0) }

    var body: some View {
        if !leases.isEmpty {
            VStack(spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        Text("Leases (\(leases.count))").fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Color.primary.opacity(0.03)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !isCollapsed {
                    ForEach(leases) { lease in
                        leaseRow(lease)
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    private func leaseRow(_ lease: AppLease) -> some View {
        let disabledReason = unavailableReason ?? (lease.holderRunning ? "The holder is running" : nil)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(lease.holderRunning ? Color.green : Color.gray).frame(width: 6, height: 6)
                    .help(lease.holderRunning ? "Holder running" : "Holder idle")
                Text(lease.displayName).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(lease.state).foregroundStyle(.secondary)
                Menu {
                    leaseActions(lease, disabledReason: disabledReason)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .help(disabledReason ?? "Lease actions")
            }
            HStack(spacing: 4) {
                Text(lease.holder)
                Text("· since \(lease.leasedAt.formatted(.relative(presentation: .named)))")
                Spacer()
            }.foregroundStyle(.secondary)
            Text((lease.home as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).help(lease.home)
            if lease.quarantined {
                Label("Quarantined — the CLI will check whether this lease can be changed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            leaseActions(lease, disabledReason: disabledReason)
        }
    }

    @ViewBuilder
    private func leaseActions(_ lease: AppLease, disabledReason: String?) -> some View {
        Button("Return lease") { requestAction(LeaseAction(lease: lease, target: nil)) }
            .disabled(disabledReason != nil || isBusy).help(disabledReason ?? "Return this lease")
        Menu("Swap to") {
            ForEach(accounts.filter(\.leasable)) { account in
                Button(String(format: "%@ · 5h %.0f%% / weekly %.0f%% free", account.displayName, account.sessionFreePercent, account.weeklyFreePercent)) {
                    requestAction(LeaseAction(lease: lease, target: account))
                }
            }
        }
        .disabled(disabledReason != nil || isBusy || !accounts.contains(where: \.leasable))
        .help(disabledReason ?? "Choose a leasable account")
        Button("Reveal home in Finder") { revealHome(lease.home) }
    }
}
