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
            ("leased-running", ResetTestFixtures.account(email: "running@example.invalid"), LeaseTestFixtures.account(leased: true)),
            ("leased-idle", ResetTestFixtures.account(email: "idle@example.invalid"), LeaseTestFixtures.account(leased: true)),
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
        try render(LeasesSection(leases: [LeaseTestFixtures.lease(running: true, index: 1), LeaseTestFixtures.lease(index: 2), LeaseTestFixtures.lease(quarantined: true, index: 3)],
                                accounts: [LeaseTestFixtures.account()]).frame(width: 680), name: "leases", directory: directory)
        let fullList = try ResetTestFixtures.list()
        let list = ResetCreditsList(credits: Array(fullList.available.prefix(2)) + [fullList.history.last!], availableCount: 2, totalEarnedCount: 3)
        let account = ResetTestFixtures.account()
        let confirmation = ResetConfirmation(credit: list.available[0], requestID: UUID())
        let states: [(String, ResetCreditsContent)] = [
            ("loading", .init(account: account, state: .loading)),
            ("list", .init(account: account, state: .loaded(list))),
            ("confirm", .init(account: account, state: .loaded(list), confirmation: confirmation)),
            ("success", .init(account: account, state: .loaded(list), notice: "Usage reset (2 limits restored).")),
            ("nothing-to-reset", .init(account: account, state: .loaded(list), notice: ResetConsumeOutcome.nothingToReset.message)),
            ("error", .init(account: account, state: .error("Usage limit resets request failed (HTTP 500).")))
        ]
        for (name, var view) in states {
            // ImageRenderer cannot capture the native macOS scroll view. Render its value content.
            view.scrolls = false
            try render(view, name: "reset-\(name)", directory: directory)
        }
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
