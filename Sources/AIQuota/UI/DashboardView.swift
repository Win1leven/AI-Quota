import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    var onFix: (() -> Void)?

    @State private var selectedTrendRange: TrendRange = .fiveHours

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .background(Color.white.opacity(0.06))
                .padding(.horizontal, 12)

            VStack(spacing: 10) {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    ServiceCardView(
                        provider: provider,
                        snapshot: store.snapshots[provider],
                        analytics: store.analytics[provider],
                        isLoading: store.isLoading.contains(provider),
                        isLoadingAnalytics: store.isLoadingAnalytics.contains(provider),
                        error: store.errors[provider],
                        trendRange: selectedTrendRange,
                        trendPoints: store.trendPoints(
                            for: provider,
                            windowType: store.snapshots[provider]?.primaryWindow?.type,
                            range: selectedTrendRange
                        )
                    )
                }
            }
            .padding(12)

            Divider()
                .background(Color.white.opacity(0.06))
                .padding(.horizontal, 12)

            footerView
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .onAppear { selectedTrendRange = store.settings.defaultTrendRange }
        .onChange(of: store.settings.defaultTrendRange) { selectedTrendRange = $0 }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            Text("Quota Monitor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            overallStatusIcon
                .font(.system(size: 10))

            refreshButton
                .help("Refresh now")

            if let onFix {
                fixButton(action: onFix)
                    .help("Fix / Unfix panel")
            }
        }
    }

    @ViewBuilder
    private var overallStatusIcon: some View {
        let allLive = ProviderID.allCases.allSatisfy { id in
            store.snapshots[id]?.freshness == .live
        }
        let anyWarning = ProviderID.allCases.contains { id in
            guard let snap = store.snapshots[id],
                  let primary = snap.primaryWindow,
                  let rem = primary.remainingPercent else { return false }
            return rem < 20
        }
        let anyCritical = ProviderID.allCases.contains { id in
            guard let snap = store.snapshots[id],
                  let primary = snap.primaryWindow,
                  let rem = primary.remainingPercent else { return false }
            return rem < 10
        }

        if anyCritical {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if anyWarning {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if allLive {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private var refreshButton: some View {
        Button { Task { await store.refreshAll() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.4))
    }

    private func fixButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: store.isFloatingPanelFixed ? "pin.slash.fill" : "pin.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.isFloatingPanelFixed ? Color.accentColor : .white.opacity(0.4))
    }

    private var footerView: some View {
        HStack {
            Menu {
                ForEach(TrendRange.allCases, id: \.self) { range in
                    Button(range.rawValue) { selectedTrendRange = range }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 10))
                    Text(selectedTrendRange.rawValue)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Text("v1.0.0b")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.2))
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
