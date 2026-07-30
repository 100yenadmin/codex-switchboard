import AppKit
import Combine
import SwiftUI

private let statusBarSymbolName = "chart.bar.fill"

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let viewModel: UsageViewModel
    private let authMirrorService = CodexAuthMirrorService()
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let fixtureSnapshotOnly: Bool
    private var fixtureWindow: NSWindow?

    override init() {
        let fixtureSnapshotOnly = CommandLine.arguments.contains(
            "--fixture-snapshot-only"
        )
        self.fixtureSnapshotOnly = fixtureSnapshotOnly
        self.viewModel = UsageViewModel(skipCodexSurfaces: fixtureSnapshotOnly)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if fixtureSnapshotOnly {
            setupFixtureWindow()
            return
        }

        authMirrorService.start()
        setupStatusItem()
        setupPopover()
        viewModel.refresh()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: statusBarSymbolName,
                          accessibilityDescription: "Codex Switchboard")
        img?.isTemplate = true
        button.image = img
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Popover

    private func setupPopover() {
        let root = ContentView(viewModel: viewModel)
        let controller = NSHostingController(rootView: root)
        controller.preferredContentSize = preferredContentSize(for: viewModel.informationMode)
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        }

        popover = NSPopover()
        popover.contentSize = preferredContentSize(for: viewModel.informationMode)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller

        viewModel.$informationMode
            .removeDuplicates()
            .sink { [weak self, weak controller] mode in
                let size = Self.preferredContentSize(for: mode)
                controller?.preferredContentSize = size
                self?.popover.contentSize = size
            }
            .store(in: &cancellables)
    }

    private func syncPopoverSizeToSelectedMode() {
        let size = preferredContentSize(for: viewModel.informationMode)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }

    private static func preferredContentSize(for mode: AccountInformationMode) -> NSSize {
        NSSize(
            width: ContentView.preferredWidth(for: mode),
            height: ContentView.preferredHeight(for: mode)
        )
    }

    private func preferredContentSize(for mode: AccountInformationMode) -> NSSize {
        Self.preferredContentSize(for: mode)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            removeEventMonitor()
        } else {
            syncPopoverSizeToSelectedMode()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.popover.performClose(nil)
                self?.removeEventMonitor()
            }
        }
    }

    private func setupFixtureWindow() {
        let size = preferredContentSize(for: viewModel.informationMode)
        let controller = NSHostingController(rootView: ContentView(viewModel: viewModel))
        controller.preferredContentSize = size

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Switchboard Fork RC Fixture"
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()
        fixtureWindow = window

        viewModel.$informationMode
            .removeDuplicates()
            .sink { [weak window, weak controller] mode in
                let nextSize = Self.preferredContentSize(for: mode)
                controller?.preferredContentSize = nextSize
                window?.setContentSize(nextSize)
            }
            .store(in: &cancellables)
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    let fixtureSnapshotOnly = CommandLine.arguments.contains("--fixture-snapshot-only")
    app.setActivationPolicy(fixtureSnapshotOnly ? .regular : .accessory)
    app.run()
}
