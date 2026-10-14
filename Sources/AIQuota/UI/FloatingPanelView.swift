import AppKit
import SwiftUI
import Combine

@MainActor
final class FloatingPanel: NSObject {
    private var window: NSPanel?
    private let store: QuotaStore
    private let onClose: () -> Void
    private let defaultsKey = "com.aiquota.floatingPanel.frame"
    private var settingsSubscription: AnyCancellable?

    init(store: QuotaStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = store.settings.alwaysOnTop ? NSWindow.Level.floating : NSWindow.Level.normal
        if store.settings.showOnAllSpaces {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.collectionBehavior = []
        }
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let contentView = FloatingPanelContentView(
            store: store,
            compact: store.settings.floatingPanelCompact,
            onToggleCompact: { [weak self] in
                self?.toggleCompact()
            },
            onClose: { [weak self] in
                self?.close()
                self?.onClose()
            }
        )

        panel.contentView = NSHostingView(rootView: contentView)
        panel.makeKeyAndOrderFront(nil as Any?)

        restoreFrame(panel)

        self.window = panel
        settingsSubscription = store.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowSettings() }
    }

    private func applyWindowSettings() {
        window?.level = store.settings.alwaysOnTop ? .floating : .normal
        window?.collectionBehavior = store.settings.showOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func toggleCompact() {
        guard let panel = window else { return }
        let isCompact = !store.settings.floatingPanelCompact
        store.settings.floatingPanelCompact = isCompact
        store.saveSettings()

        let newHeight: CGFloat = isCompact ? 220 : 520
        var frame = panel.frame
        frame.size.height = newHeight
        panel.setFrame(frame, display: true, animate: true)

        let contentView = FloatingPanelContentView(
            store: store,
            compact: isCompact,
            onToggleCompact: { [weak self] in
                self?.toggleCompact()
            },
            onClose: { [weak self] in
                self?.close()
                self?.onClose()
            }
        )
        panel.contentView = NSHostingView(rootView: contentView)
    }

    func bringToFront() {
        window?.orderFrontRegardless()
    }

    func close() {
        if let panel = window, panel.isVisible {
            saveFrame(panel)
            panel.close()
        }
        window = nil
    }

    private func restoreFrame(_ panel: NSPanel) {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let frame = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data) {
            panel.setFrame(NSRectFromString(frame as String), display: false)
        } else {
            centerPanel(panel)
        }
    }

    private func saveFrame(_ panel: NSPanel) {
        let frameString = NSStringFromRect(panel.frame)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: frameString, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func centerPanel(_ panel: NSPanel) {
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let panelRect = panel.frame
            let x = screenRect.midX - panelRect.width / 2
            let y = screenRect.midY - panelRect.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

extension FloatingPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSPanel {
            saveFrame(panel)
        }
        onClose()
    }
}

struct FloatingPanelContentView: View {
    @ObservedObject var store: QuotaStore
    let compact: Bool
    let onToggleCompact: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quota Monitor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                if compact {
                    compactContent
                }

                Button(action: onToggleCompact) {
                    Text(compact ? "展开详情" : "紧凑视图")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help(compact ? "展开完整额度详情" : "切换为紧凑视图")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Close panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if compact {
                compactDashboard
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(ProviderID.allCases, id: \.self) { provider in
                            ServiceCardView(
                                provider: provider,
                                snapshot: store.snapshots[provider],
                                analytics: store.analytics[provider],
                                isLoading: store.isLoading.contains(provider),
                                isLoadingAnalytics: store.isLoadingAnalytics.contains(provider),
                                error: store.errors[provider],
                                trendRange: store.settings.defaultTrendRange,
                                trendPoints: store.trendPoints(
                                    for: provider,
                                    windowType: store.snapshots[provider]?.primaryWindow?.type,
                                    range: store.settings.defaultTrendRange
                                )
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 300)
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            ForEach(ProviderID.allCases, id: \.self) { id in
                if let snapshot = store.snapshots[id], let primary = snapshot.primaryWindow, let rem = primary.remainingPercent {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(id == .codex ? Color(red: 0.2, green: 0.9, blue: 0.8) : Color(red: 0.3, green: 0.95, blue: 0.6))
                            .frame(width: 6, height: 6)
                        Text("\(Int(rem.rounded()))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(rem < 10 ? Color.red : rem < 20 ? Color.orange : .white.opacity(0.8))
                    }
                }
            }
        }
    }

    private var compactDashboard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                ForEach(ProviderID.allCases, id: \.self) { id in
                    if let snapshot = store.snapshots[id] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(id.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(id == .codex ? Color(red: 0.2, green: 0.9, blue: 0.8) : Color(red: 0.3, green: 0.95, blue: 0.6))

                            Text("\(snapshot.aged().freshness.displayName) · \(snapshot.observedAt.ageDescription)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if let primary = snapshot.primaryWindow, let rem = primary.remainingPercent {
                                QuotaProgressBar(value: rem / 100, accentColor: rem < 10 ? .red : rem < 20 ? .orange : (id == .codex ? Color(red: 0.2, green: 0.9, blue: 0.8) : Color(red: 0.3, green: 0.95, blue: 0.6)))
                                    .frame(height: 4)

                                HStack {
                                    Text("\(Int(rem.rounded()))%")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Spacer()
                                    if let resetsAt = primary.resetsAt {
                                        Text(resetsAt, style: .relative)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)

            Divider()
                .background(Color.white.opacity(0.06))
                .padding(.horizontal, 8)

            if store.snapshots[.codex] != nil {
                MiniBarChart(dataPoints: store.trendPoints(for: .codex, windowType: store.codexSnapshot?.primaryWindow?.type, range: store.settings.defaultTrendRange), accentColor: .cyan)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            HStack {
                if let codex = store.snapshots[.codex] {
                    Text("CX: \(syncStatusText(codex))")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                Text("Next reset: \(nextResetText)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var nextResetText: String {
        let resets = ProviderID.allCases.compactMap { id -> Date? in
            store.snapshots[id]?.primaryWindow?.resetsAt
        }
        if let earliest = resets.min() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: earliest, relativeTo: Date())
        }
        return "--"
    }

    private func syncStatusText(_ snapshot: QuotaSnapshot) -> String {
        switch snapshot.freshness {
        case .live: return "Live"
        case .cached: return "Cached"
        case .stale: return "Stale"
        case .unavailable: return "N/A"
        case .notConfigured: return "Not configured"
        case .unknown: return "Unknown"
        }
    }
}
