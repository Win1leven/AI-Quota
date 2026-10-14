import SwiftUI

struct ServiceCardView: View {
    let provider: ProviderID
    let snapshot: QuotaSnapshot?
    let analytics: UsageAnalytics?
    let isLoading: Bool
    let isLoadingAnalytics: Bool
    let error: String?
    let trendRange: TrendRange
    let trendPoints: [TrendPoint]

    private var accentColor: Color {
        provider == .codex ? Color(red: 0.2, green: 0.9, blue: 0.8) : Color(red: 0.3, green: 0.95, blue: 0.6)
    }

    private var cardBackground: Color {
        Color(red: 0.08, green: 0.08, blue: 0.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && snapshot == nil {
                loadingView
            } else if error != nil, snapshot == nil {
                errorView
            } else if let snapshot {
                contentView(snapshot: snapshot)
            } else {
                emptyView
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func contentView(snapshot: QuotaSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Left: Text content
                VStack(alignment: .leading, spacing: 6) {
                    headerRow
                    primaryValue(snapshot: snapshot)
                    countdownToReset(snapshot: snapshot)
                    syncStatus(snapshot: snapshot)
                    if let source = snapshot.source {
                        Text(source.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: Visual (segmented bar + mini chart)
                VStack(spacing: 8) {
                    SegmentedProgressBar(
                        segments: snapshot.windows,
                        accentColor: accentColor
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(trendRange.rawValue) usage trend")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                            Spacer()
                            if let delta = usageDelta {
                                Text("\(delta >= 0 ? "+" : "")\(Int(delta.rounded())) pts")
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundStyle(delta > 0 ? .orange : accentColor)
                            }
                        }

                        MiniBarChart(dataPoints: trendPoints, accentColor: accentColor)
                            .frame(height: 34)
                    }
                }
                .frame(width: 140)
            }
            .padding(16)

            // Bottom: Analytics row (tokens + weekly value) — expands only when data available
            if analytics != nil || isLoadingAnalytics {
                Divider().background(Color.white.opacity(0.06))
                analyticsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.03))
            }
        }
    }

    @ViewBuilder
    private var analyticsRow: some View {
        if isLoadingAnalytics && analytics == nil {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5).tint(.white.opacity(0.4))
                Text("Loading usage…").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
        } else if let a = analytics {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tokens").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                    Text(formatTokens(a.tokensUsed)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                }
                if a.creditsUsed > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Credits").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                        Text(String(format: "%.1f", a.creditsUsed)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("API 等价").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                    if let usd = a.projectedWeeklyUSD {
                        Text(String(format: "$%.2f", usd)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(accentColor)
                    } else if let t = a.projectedWeeklyTokens {
                        Text(formatTokens(t)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(accentColor)
                    } else {
                        Text("--").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                    }
                }
                Text("近7天").font(.system(size: 7)).foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    private func formatTokens(_ v: Int) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", Double(v)/1e9) }
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v)/1e6) }
        if v >= 1_000 { return String(format: "%.1fK", Double(v)/1e3) }
        return "\(v)"
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)

            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func primaryValue(snapshot: QuotaSnapshot) -> some View {
        Group {
            if let primary = snapshot.primaryWindow {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    if let remaining = primary.remainingPercent {
                        Text("\(Int(remaining.rounded()))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(remainingColor(remaining))
                    } else {
                        Text("--")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Text("%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .baselineOffset(2)

                    Text("remaining")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .baselineOffset(2)

                    if let delta = usageDelta, abs(delta) >= 0.5 {
                        Text(delta > 0 ? "↓" : "↑")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(delta > 0 ? Color.orange : accentColor)
                            .offset(y: -2)
                    }
                }
            } else {
                Text(snapshot.freshness == .notConfigured ? "Enable desktop usage or collector in Settings" : "Waiting for a Claude usage sample")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func countdownToReset(snapshot: QuotaSnapshot) -> some View {
        Group {
            if let primary = snapshot.primaryWindow, let resetsAt = primary.resetsAt {
                let interval = resetsAt.timeIntervalSinceNow
                if interval > 0 {
                    Text("Resets in \(formatCountdown(interval))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text("Reset pending")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            } else {
                Text(snapshot.primaryWindow == nil ? "Unknown" : "Reset time unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func syncStatus(snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(freshnessColor(snapshot.freshness))
                .frame(width: 4, height: 4)

            Text(freshnessDescription(snapshot.freshness))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))

            Spacer()

            Text("Sampled \(snapshot.observedAt.ageDescription)")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.top, 4)
    }

    // MARK: - State Views

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.6)
                .controlSize(.small)
                .tint(.white.opacity(0.4))
            Text("Loading \(provider.displayName)…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var errorView: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            Text(error ?? "Unknown error")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var emptyView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text("Waiting…")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func remainingColor(_ value: Double) -> Color {
        if value < 10 { return .red }
        if value < 20 { return .orange }
        return accentColor
    }

    private func freshnessColor(_ freshness: DataFreshness) -> Color {
        switch freshness {
        case .live: return .green
        case .cached: return .yellow
        case .stale: return .orange
        case .unavailable, .unknown: return .red
        case .notConfigured: return .gray
        }
    }

    private func freshnessDescription(_ freshness: DataFreshness) -> String {
        switch freshness {
        case .live: return provider == .claude ? "Recent sample" : "Live"
        case .cached: return "Cached"
        case .stale: return "Stale"
        case .unavailable: return "Offline"
        case .unknown: return "Unknown"
        case .notConfigured: return "Not set"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h"
    }

    private func formatCountdown(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        return "\(hours)h \(minutes)m"
    }

    private var usageDelta: Double? {
        guard trendPoints.count >= 2,
              let first = trendPoints.first,
              let last = trendPoints.last else { return nil }
        return last.usedPercent - first.usedPercent
    }
}

// MARK: - Segmented Progress Bar (battery-style)

struct SegmentedProgressBar: View {
    let segments: [QuotaWindow]
    let accentColor: Color

    var body: some View {
        VStack(spacing: 6) {
            ForEach(segments) { window in
                SegmentedRow(window: window, accentColor: accentColor)
            }
        }
    }
}

struct SegmentedRow: View {
    let window: QuotaWindow
    let accentColor: Color

    private let totalSegments = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let used = window.usedPercent {
                    Text("\(Int(used.rounded()))% used")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if let reset = window.resetsAt {
                Text(reset > Date() ? "Resets \(reset.formattedAbsolute())" : "Reset passed · awaiting sample")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset time unknown")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 3) {
                ForEach(0..<totalSegments, id: \.self) { index in
                    let filled = isFilled(at: index)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(filled ? segmentColor : Color.white.opacity(0.1))
                        .frame(height: 6)
                }
            }
        }
    }

    private func isFilled(at index: Int) -> Bool {
        guard let used = window.usedPercent else { return false }
        let filledCount = Int((used / 100.0 * Double(totalSegments)).rounded())
        return index < filledCount
    }

    private var segmentColor: Color {
        guard let used = window.usedPercent else { return accentColor }
        if used > 80 { return .red }
        if used > 60 { return .orange }
        return accentColor
    }
}

// MARK: - Mini Bar Chart

struct MiniBarChart: View {
    let dataPoints: [TrendPoint]
    let accentColor: Color

    var body: some View {
        Group {
            if sampledPoints.count >= 2 {
                HStack(spacing: 2) {
                    ForEach(sampledPoints) { point in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barColor(for: point.usedPercent))
                            .frame(height: max(3, CGFloat(point.usedPercent / 100) * 34))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            } else {
                Text(dataPoints.isEmpty ? "Collecting trend…" : "1 sample collected")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var sampledPoints: [TrendPoint] {
        guard dataPoints.count > 14 else { return dataPoints }
        let step = Double(dataPoints.count - 1) / 13
        return (0..<14).map { dataPoints[Int((Double($0) * step).rounded())] }
    }

    private func barColor(for usedPercent: Double) -> Color {
        if usedPercent > 80 { return .red }
        if usedPercent > 60 { return .orange }
        return accentColor
    }

    private var accessibilitySummary: String {
        guard let first = dataPoints.first, let last = dataPoints.last else {
            return "No usage trend data"
        }
        return "Usage changed from \(Int(first.usedPercent.rounded())) to \(Int(last.usedPercent.rounded())) percent"
    }
}

// MARK: - Window Extension

extension QuotaWindow {
    var label: String {
        switch type {
        case .fiveHour: return "5h"
        case .weekly: return "7d"
        case .unknown: return "?"
        }
    }
}

struct QuotaProgressBar: View {
    let value: Double
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))

                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: geo.size.width * value)
            }
        }
    }
}
