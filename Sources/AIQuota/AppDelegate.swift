import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var floatingPanel: FloatingPanel?
    private var desktopAssistant: DesktopAssistant?
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

        store.$claudeDesktopSessionEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.registerClaudeProvider(desktopSessionEnabled: enabled)
                Task { @MainActor [weak self] in await self?.store.manualRefreshClaude() }
            }
            .store(in: &cancellables)

        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemText() }
            .store(in: &cancellables)
        store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemText()
                self?.applyDisplayMode()
            }
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
        registerClaudeProvider(desktopSessionEnabled: store.claudeDesktopSessionEnabled)
    }

    private func applyDisplayMode() {
        let mode = store.settings.effectiveDisplayMode
        statusItem?.isVisible = mode != .desktopOnly
        if mode == .menuBarOnly {
            desktopAssistant?.close()
            desktopAssistant = nil
        } else if desktopAssistant == nil {
            desktopAssistant = DesktopAssistant(store: store,
                onOpen: { [weak self] in
                    if let panel = self?.floatingPanel { panel.bringToFront() }
                    else { self?.fixDashboard() }
                },
                onSettings: { [weak self] in self?.handleSettings() })
        }
    }

    private func registerClaudeProvider(desktopSessionEnabled: Bool) {
        let usage: (@Sendable () async throws -> Data)?
        if desktopSessionEnabled {
            usage = { @Sendable in try await ClaudeDesktopUsageService().fetchUsage() }
        } else {
            usage = nil
        }
        store.registerProvider(ClaudeQuotaProvider(desktopUsage: usage))
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
        Task { await store.refreshQuotas() }
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
        NSApp.activate(ignoringOtherApps: true)
        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: {
            $0.items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
        }), let index = menu.items.firstIndex(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: nil)
        }
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
