import AppKit
import SwiftUI
import Combine

@MainActor
final class DesktopAssistant {
    private let panel: NSPanel
    private let store: QuotaStore
    private let defaultsKey = "com.aiquota.desktopAssistant.frame"
    private var settingsSubscription: AnyCancellable?

    init(store: QuotaStore, onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quota Assistant"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let view = AssistantHostingView(rootView: AssistantCapsule(store: store))
        view.onOpen = onOpen
        view.onDragEnded = { [weak self] in self?.savePosition() }
        view.onMenu = { [weak self, weak view] event in
            guard self != nil, let view else { return }
            let menu = NSMenu()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                item.representedObject = target
                menu.addItem(item)
            }
            add("Refresh") { Task { await store.refreshQuotas() } }
            add("Settings…", onSettings)
            add("Menu bar only") {
                store.settings.assistantDisplayMode = .menuBarOnly
                store.saveSettings()
            }
            menu.addItem(.separator())
            add("Quit") { NSApp.terminate(nil) }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        panel.contentView = view
        restorePosition()
        applyWindowSettings(store.settings)
        panel.orderFrontRegardless()
        settingsSubscription = store.$settings.dropFirst().sink { [weak self] settings in self?.applyWindowSettings(settings) }
    }

    func close() {
        savePosition()
        panel.close()
    }

    private func applyWindowSettings(_ settings: AppSettings) {
        panel.level = settings.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = settings.showOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: defaultsKey)
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let frame = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) {
                panel.setFrameOrigin(frame.origin)
                return
            }
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - 200, y: bounds.minY + 32))
        }
    }

    private final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

@MainActor
private final class AssistantHostingView: NSHostingView<AssistantCapsule> {
    var onOpen: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        dragStart = window?.convertPoint(toScreen: event.locationInWindow)
        windowStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart else { return }
        guard let current = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y
        guard didDrag || hypot(dx, dy) >= 3 else { return }
        didDrag = true
        window?.setFrameOrigin(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        windowStart = nil
        if didDrag { onDragEnded?() }
        else { onOpen?() }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

private struct AssistantCapsule: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        HStack(spacing: 8) {
            value(for: .codex)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18)
            value(for: .claude)
        }
        .padding(.horizontal, 12)
        .frame(width: 180, height: 48)
        .background(Capsule().fill(Color(red: 0.09, green: 0.10, blue: 0.13)))
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func value(for provider: ProviderID) -> some View {
        let snapshot = store.snapshots[provider]
        let remaining = snapshot?.limitingWindow?.remainingPercent
        let warning = store.errors[provider] != nil || snapshot?.freshness == .stale || snapshot?.freshness == .cached
        let accent = provider == .codex ? Color(red: 0.2, green: 0.9, blue: 0.8) : Color(red: 0.3, green: 0.95, blue: 0.6)
        return HStack(spacing: 3) {
            Text(provider.displayName).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
            Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if warning { Circle().fill(.orange).frame(width: 4, height: 4) }
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity)
        .help(tooltip(provider: provider, snapshot: snapshot))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName) remaining \(remaining.map { "\(Int($0.rounded())) percent" } ?? "unknown")")
    }

    private func tooltip(provider: ProviderID, snapshot: QuotaSnapshot?) -> String {
        guard let snapshot, let window = snapshot.limitingWindow else { return "\(provider.displayName): no quota sample yet" }
        var text = "\(provider.displayName) · \(window.type.rawValue) · \(snapshot.freshness.displayName)\nSampled: \(snapshot.observedAt.formatted())"
        if let reset = window.resetsAt { text += "\nResets: \(reset.formatted())" }
        else { text += "\nReset time unknown" }
        if snapshot.isAwaitingFirstClaudeMessage { text += "\n5h starts after your first message" }
        if let error = store.errors[provider] { text += "\n\(error)" }
        return text
    }
}
