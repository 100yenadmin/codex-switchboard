import SwiftUI

struct ResetConfirmation: Equatable {
    let credit: ResetCredit
    let requestID: UUID

    func message(email: String) -> String {
        let expiry = credit.expiresAt.map { "expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "no expiry"
        return "Use \u{201C}\(credit.displayTitle)\u{201D} (\(expiry)) on \(email)? It restores the 5-hour and weekly limits. The reset is used up."
    }
}

enum ResetCreditsLoadState: Equatable {
    case loading
    case loaded(ResetCreditsList)
    case error(String)
}

@MainActor
final class ResetCreditsViewModel: ObservableObject {
    @Published private(set) var state: ResetCreditsLoadState = .loading
    @Published private(set) var confirmation: ResetConfirmation?
    @Published private(set) var isConsuming = false
    @Published private(set) var consumeError: String?
    @Published private(set) var notice: ResetConsumeOutcome?
    let account: Account
    private let isLeased: () -> Bool
    private let service: ResetCreditsService
    private let refreshUsage: () -> Void
    /// Set when a consume ended without a definitive answer, so the reset may or may not have been spent.
    private var spendUnresolved = false

    init(account: Account, isLeased: @escaping () -> Bool, service: ResetCreditsService = ResetCreditsService(), refreshUsage: @escaping () -> Void) {
        self.account = account
        self.isLeased = isLeased
        self.service = service
        self.refreshUsage = refreshUsage
    }

    func load() async {
        guard !isConsuming else { return }
        state = .loading
        await reload()
    }

    private func reload() async {
        guard let key = account.profileKey else { state = .error("Account profile unavailable."); return }
        do { state = .loaded(try await service.list(profileKey: key, isLeased: isLeased())) }
        catch { state = .error(error.localizedDescription) }
    }

    func confirm(_ credit: ResetCredit) {
        guard !isConsuming, case .loaded = state else { return }
        confirmation = ResetConfirmation(credit: credit, requestID: UUID())
        consumeError = nil
        notice = nil
    }

    func cancel() async {
        guard !isConsuming else { return }
        let needsReload = spendUnresolved
        confirmation = nil
        consumeError = nil
        if needsReload {
            spendUnresolved = false
            state = .loading
            await reload()
        }
    }

    // Retry returns to the explicit Use reset button, retaining the original idempotency key.
    func tryAgain() { consumeError = nil }

    func useReset() async {
        guard !isConsuming, let pending = confirmation, let key = account.profileKey else { return }
        isConsuming = true
        consumeError = nil
        defer { isConsuming = false }
        do {
            let result = try await service.consume(profileKey: key, isLeased: isLeased(), creditID: pending.credit.id, requestID: pending.requestID)
            spendUnresolved = false
            confirmation = nil
            notice = result
            switch result {
            case .reset:
                refreshUsage()
                await reload()
            case .noCredit: await reload()
            case .nothingToReset: break
            }
        } catch {
            spendUnresolved = true
            consumeError = error.localizedDescription
        }
    }
}

struct ResetCreditsSheet: View {
    @StateObject var model: ResetCreditsViewModel
    // The sheet receives refreshed quotas from its parent after a successful reset.
    let account: Account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ResetCreditsContent(
            account: account, state: model.state, confirmation: model.confirmation,
            isConsuming: model.isConsuming, notice: model.notice, consumeError: model.consumeError,
            load: { Task { await model.load() } }, confirm: model.confirm, cancel: { Task { await model.cancel() } },
            useReset: { Task { await model.useReset() } }, tryAgain: model.tryAgain,
            close: { dismiss() }
        )
        .interactiveDismissDisabled(model.isConsuming)
        .task { await model.load() }
    }
}

/// Value-only inputs keep every state renderable without profile, storage or network access.
struct ResetCreditsContent: View {
    let account: Account
    let state: ResetCreditsLoadState
    var confirmation: ResetConfirmation? = nil
    var isConsuming = false
    var notice: ResetConsumeOutcome? = nil
    var consumeError: String? = nil
    var load: () -> Void = {}
    var confirm: (ResetCredit) -> Void = { _ in }
    var cancel: () -> Void = {}
    var useReset: () -> Void = {}
    var tryAgain: () -> Void = {}
    var close: () -> Void = {}
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage limit resets").font(.headline)
                Spacer()
                Button("Done", action: close).disabled(isConsuming)
            }
            Text(account.email).textSelection(.enabled)
            Text(String(format: "5-hour: %.0f%% free · Weekly: %.0f%% free", account.sessionFree, account.weeklyFree))
                .foregroundStyle(.secondary)
            if let notice {
                switch notice {
                case .reset:
                    Label(notice.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .nothingToReset, .noCredit:
                    Label(notice.message, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            if let confirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(confirmation.message(email: account.email))
                    if let consumeError {
                        Text(consumeError).foregroundStyle(.red)
                        Button("Try again", action: tryAgain).disabled(isConsuming)
                    }
                    HStack {
                        Button("Cancel", action: cancel).buttonStyle(.bordered).disabled(isConsuming)
                        Button("Use reset", action: useReset).buttonStyle(.borderedProminent).disabled(isConsuming || consumeError != nil)
                        if isConsuming { ProgressView().controlSize(.small) }
                    }
                }
                .padding(10).background(Color.orange.opacity(0.1)).cornerRadius(8)
            }
            if scrolls {
                ScrollView { creditList }
            } else {
                creditList
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 520, maxHeight: scrolls ? 520 : nil)
    }

    private var creditList: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .loading:
                Label("Loading usage limit resets…", systemImage: "hourglass").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            case .error(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again", action: load).disabled(isConsuming)
            case .loaded(let list):
                if list.available.isEmpty { Text("No usage limit resets are available.") }
                ForEach(list.available) { credit in creditRow(credit, available: true) }
                if !list.history.isEmpty {
                    Divider()
                    Text("History").font(.headline)
                    ForEach(list.history) { credit in creditRow(credit, available: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func creditRow(_ credit: ResetCredit, available: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(credit.displayTitle).fontWeight(.medium)
                if let description = credit.description, !description.isEmpty { Text(description).foregroundStyle(.secondary) }
                if available {
                    Text(credit.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No expiry")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(credit.status).font(.caption)
                    if let date = credit.redeemedAt ?? credit.grantedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if available {
                Button("Use…") { confirm(credit) }.disabled(isConsuming || confirmation != nil)
            }
        }
        .padding(10).background(Color.primary.opacity(0.04)).cornerRadius(8)
    }
}
