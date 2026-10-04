import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var floatingPanel: FloatingPanel?
    private var isPopoverShown = false
    private var cancellables = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerProviders()
        setupStatusItem()
        setupPopover()
        store.startPeriodicRefresh()

        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemText() }
            .store(in: &cancellables)
        store.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemText() }
            .store(in: &cancellables)

        Task {
            await store.refreshAll()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func registerProviders() {
        store.registerProvider(CodexQuotaProvider())
        store.registerProvider(ClaudeQuotaProvider())
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "chart.pie.fill",
                accessibilityDescription: "Quota Monitor"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            )
            button.imagePosition = .imageLeading
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItemText()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 410)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(store: store, onFix: { [weak self] in
                self?.fixDashboard()
            })
        )
    }

    func updateStatusItemText() {
        let text = store.menuBarText
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        statusItem?.button?.attributedTitle = attributed
        statusItem?.button?.toolTip = store.menuBarTooltip
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if floatingPanel != nil {
            floatingPanel?.bringToFront()
            return
        }

        if isPopoverShown {
            popover.performClose(nil)
            isPopoverShown = false
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isPopoverShown = true
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(handleRefresh), keyEquivalent: "r")
        menu.addItem(refreshItem)

        let fixItem = NSMenuItem(title: store.isFloatingPanelFixed ? "Unfix Panel" : "Fix Panel", action: #selector(handleFixPanel), keyEquivalent: "f")
        menu.addItem(fixItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func handleRefresh() {
        Task { await store.manualRefreshCodex() }
    }

    @objc private func handleFixPanel() {
        fixDashboard()
    }

    private func fixDashboard() {
        if let floatingPanel {
            floatingPanel.close()
            self.floatingPanel = nil
            store.isFloatingPanelFixed = false
        } else {
            let panel = FloatingPanel(
                store: store,
                onClose: { [weak self] in
                    self?.floatingPanel = nil
                    self?.store.isFloatingPanelFixed = false
                }
            )
            floatingPanel = panel
            store.isFloatingPanelFixed = true
            if isPopoverShown {
                popover.performClose(nil)
                isPopoverShown = false
            }
        }
    }

    @objc private func handleSettings() {
        if isPopoverShown {
            popover.performClose(nil)
            isPopoverShown = false
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if #available(macOS 14, *) {
            NSApp.keyWindow?.orderFrontRegardless()
        }
    }

    @objc private func handleWake() {
        store.checkFreshnessAfterWake()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopPeriodicRefresh()
    }
}
