import SwiftUI
import Charts

struct TrendChartPlaceholder: View {
    @State private var animate = false

    var body: some View {
        Chart {
            ForEach(mockTrendPoints, id: \.id) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used %", point.usedPercent)
                )
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used %", point.usedPercent)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.secondary.opacity(0.12), .secondary.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(range: .plotDimension(startPadding: 4, endPadding: 4))
        .opacity(animate ? 1 : 0.3)
        .onAppear {
            withAnimation(.easeIn(duration: 0.4)) { animate = true }
        }
    }

    private let mockTrendPoints: [TrendPoint] = {
        let now = Date()
        var points: [TrendPoint] = []
        for i in 0..<30 {
            let time = now.addingTimeInterval(-Double(30 - i) * 600)
            let value = Double.random(in: 20...60)
            points.append(TrendPoint(timestamp: time, usedPercent: value, provider: .codex, windowType: "five_hour"))
        }
        return points
    }()
}

struct TrendChartView: View {
    let dataPoints: [TrendPoint]
    let accentColor: Color
    let showResetLines: Bool

    var body: some View {
        Chart {
            ForEach(dataPoints) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used %", point.usedPercent)
                )
                .foregroundStyle(accentColor.gradient)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Used %", point.usedPercent)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor.opacity(0.15), accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            if showResetLines {
                let resetPoints = dataPoints.filter { $0.isAfterReset }
                ForEach(resetPoints) { point in
                    RuleMark(x: .value("Reset", point.timestamp))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel()
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { value in
                AxisValueLabel {
                    if let pct = value.as(Double.self) {
                        Text("\(Int(pct))%")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Trend Description

struct TrendSummaryText: View {
    let dataPoints: [TrendPoint]
    let accentColor: Color

    var body: some View {
        if let first = dataPoints.first, let last = dataPoints.last {
            let diff = last.usedPercent - first.usedPercent
            HStack(spacing: 4) {
                Image(systemName: diff > 0 ? "arrow.up" : diff < 0 ? "arrow.down" : "minus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(diff > 0 ? .orange : diff < 0 ? .green : .secondary)

                Text("\(abs(diff).formatted(.number.precision(.fractionLength(0)))) pts \(diff > 0 ? "consumed" : "recovered")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
