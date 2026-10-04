import Foundation

final class MockQuotaProvider: QuotaProviderProtocol, @unchecked Sendable {
    let id: ProviderID
    var isAvailable: Bool { true }
    private var callCount = 0

    init(id: ProviderID) {
        self.id = id
    }

    func refresh() async throws -> QuotaSnapshot {
        callCount += 1
        try await Task.sleep(nanoseconds: 500_000_000)

        let now = Date()
        let fiveHourReset = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: now)!
            .addingTimeInterval(now >= Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: now)! ? 86_400 : 0)

        let weekReset = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: now)!
            .addingTimeInterval(TimeInterval((8 - Calendar.current.component(.weekday, from: now)) * 86_400))

        let baseUsed = id == .codex ? 35.0 : 62.0
        let drift = Double(callCount * 2).truncatingRemainder(dividingBy: 20)
        let usedFiveHour = min(100, baseUsed + drift + Double.random(in: -2...2))
        let usedWeekly = max(0, min(100, baseUsed - 10 + drift + Double.random(in: -5...5)))

        let windows = [
            QuotaWindow(
                type: .fiveHour,
                durationMinutes: 300,
                usedPercent: usedFiveHour,
                remainingPercent: nil,
                resetsAt: fiveHourReset,
                observedAt: now
            ),
            QuotaWindow(
                type: .weekly,
                durationMinutes: 10080,
                usedPercent: usedWeekly,
                remainingPercent: nil,
                resetsAt: weekReset,
                observedAt: now
            )
        ]

        return QuotaSnapshot(
            provider: id,
            windows: windows,
            observedAt: now,
            receivedAt: now,
            freshness: .live
        )
    }

    func isInstalledAndLoggedIn() async -> Bool { true }
}
