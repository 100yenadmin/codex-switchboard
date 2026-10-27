import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitchboard

final class SwitchboardSnapshotTests: XCTestCase {
    @MainActor
    func testOwnerSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHBOARD_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SWITCHBOARD_SNAPSHOT_DIR to render owner snapshots.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenarios: [(String, Account, AppLeaseAccount?)] = [
            ("leased", ResetTestFixtures.account(email: "leased@example.invalid"), LeaseTestFixtures.account(leased: true)),
            ("reserved", ResetTestFixtures.account(email: "reserved@example.invalid"), LeaseTestFixtures.account(reserved: true)),
            ("resets-zero", ResetTestFixtures.account(resets: 0), nil),
            ("resets-two", ResetTestFixtures.account(resets: 2), nil)
        ]
        for (name, account, status) in scenarios {
            try render(AccountRow(account: account, leaseStatus: status).frame(width: 680), name: "expanded-\(name)", directory: directory)
            try render(AccountCompactRow(
                account: account, needsRelogin: false, isRelogging: false, isReloginBlocked: false,
                isSwitchingToCodex: false, isActiveInCodex: false, showsCodexControls: false,
                isSwitchBlocked: false, isRemoving: false, isRemoveBlocked: false,
                informationMode: .complete, resetTextScale: 1, relogin: {}, cancelRelogin: {}, switchToCodex: {}, removeAccount: {}, leaseStatus: status
            ).frame(width: 680), name: "compact-\(name)", directory: directory)
        }
        try renderNativeControls(LeasesSection(leases: [LeaseTestFixtures.lease(running: true, index: 1), LeaseTestFixtures.lease(index: 2), LeaseTestFixtures.lease(quarantined: true, index: 3)],
                                accounts: [LeaseTestFixtures.account()]).frame(width: 680), name: "leases", directory: directory)
        let fullList = try ResetTestFixtures.list()
        let list = ResetCreditsList(credits: Array(fullList.available.prefix(2)) + [fullList.history.last!], availableCount: 2, totalEarnedCount: 3)
        let account = ResetTestFixtures.account()
        let confirmation = ResetConfirmation(credit: list.available[0], requestID: UUID())
        let states: [(String, ResetCreditsContent)] = [
            ("weekly-only", .init(account: ResetTestFixtures.account(quotaWindows: [
                QuotaWindow(kind: .weekly, usedPercent: 73, resetSeconds: 86400, durationSeconds: 604800),
            ]), state: .loaded(list))),
            ("loading", .init(account: account, state: .loading)),
            ("list", .init(account: account, state: .loaded(list))),
            ("confirm", .init(account: account, state: .loaded(list), confirmation: confirmation)),
            ("confirm-no-expiry", .init(account: account, state: .loaded(list), confirmation: ResetConfirmation(credit: fullList.available.first { $0.id == "no-expiry" }!, requestID: UUID()))),
            ("success", .init(account: account, state: .loaded(list), notice: .reset(2))),
            ("nothing-to-reset", .init(account: account, state: .loaded(list), notice: .nothingToReset)),
            ("no-credit", .init(account: account, state: .loaded(list), notice: .noCredit)),
            ("error", .init(account: account, state: .error("Usage limit resets request failed (HTTP 500).")))
        ]
        for (name, var view) in states {
            // ImageRenderer cannot capture the native macOS scroll view. Render its value content.
            view.scrolls = false
            try render(view, name: "reset-\(name)", directory: directory)
        }
    }

    /// ImageRenderer does not capture the AppKit-backed Menu control.
    @MainActor
    private func renderNativeControls<V: View>(_ view: V, name: String, directory: URL) throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage, "Could not render \(name)")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
