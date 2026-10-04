import Foundation

final class ClaudeQuotaProvider: QuotaProviderProtocol, @unchecked Sendable {
    let id = ProviderID.claude

    var isAvailable: Bool {
        desktopHistoryFileExists() || collectorFileExists()
    }

    private var desktopHistoryPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    private var collectorPath: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("AIQuota")
        return appSupport.appendingPathComponent("claude_quota_snapshot.json")
    }

    private var settingsPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    func refresh() async throws -> QuotaSnapshot {
        let now = Date()

        if desktopHistoryFileExists(),
           let data = try? Data(contentsOf: desktopHistoryPath),
           let snapshot = try? parseDesktopHistory(data: data, now: now) {
            return snapshot
        }

        guard collectorFileExists() else {
            return QuotaSnapshot(
                provider: .claude,
                windows: [],
                observedAt: now,
                receivedAt: now,
                freshness: .notConfigured
            )
        }

        do {
            let data = try Data(contentsOf: collectorPath)
            let snapshot = try parseCollectorSnapshot(data: data, now: now)
            return snapshot
        } catch {
            let age = collectorFileAge()
            let freshness: DataFreshness = (age > 7200) ? .stale : (age > 900 ? .cached : .unknown)
            return QuotaSnapshot(
                provider: .claude,
                windows: [],
                observedAt: now,
                receivedAt: now,
                freshness: freshness
            )
        }
    }

    func isInstalledAndLoggedIn() async -> Bool {
        desktopHistoryFileExists() || collectorFileExists()
    }

    private func desktopHistoryFileExists() -> Bool {
        FileManager.default.fileExists(atPath: desktopHistoryPath.path)
    }

    private func collectorFileExists() -> Bool {
        FileManager.default.fileExists(atPath: collectorPath.path)
    }

    private func collectorFileAge() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: collectorPath.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return .infinity
        }
        return Date().timeIntervalSince(modDate)
    }

    func parseOAuthUsage(data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.claudeNoSnapshot
        }

        var windows: [QuotaWindow] = []
        if let fiveHour = json["five_hour"] as? [String: Any],
           let used = (fiveHour["utilization"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(
                type: .fiveHour,
                durationMinutes: 300,
                usedPercent: used,
                remainingPercent: nil,
                resetsAt: parseISO8601(fiveHour["resets_at"] as? String),
                observedAt: now
            ))
        }

        if let sevenDay = json["seven_day"] as? [String: Any],
           let used = (sevenDay["utilization"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(
                type: .weekly,
                durationMinutes: 10_080,
                usedPercent: used,
                remainingPercent: nil,
                resetsAt: parseISO8601(sevenDay["resets_at"] as? String),
                observedAt: now
            ))
        }

        guard !windows.isEmpty else {
            throw AppError.claudeNoSnapshot
        }
        return QuotaSnapshot(provider: .claude, windows: windows, observedAt: now, receivedAt: now, freshness: .live)
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func parseCollectorSnapshot(data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.codexParseFailed("Invalid collector JSON")
        }

        guard let rateLimits = json["rate_limits"] as? [String: Any] else {
            throw AppError.claudeNoSnapshot
        }

        let fileAge = collectorFileAge()
        let freshness: DataFreshness = fileAge > 7200 ? .stale : (fileAge > 900 ? .cached : .live)

        let snapshotTime = (json["sampled_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? now

        var windows: [QuotaWindow] = []

        if let fiveHour = rateLimits["five_hour"] as? [String: Any] {
            let usedPct = fiveHour["used_percentage"] as? Double
            let resetsAt = (fiveHour["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(
                type: .fiveHour,
                durationMinutes: 300,
                usedPercent: usedPct,
                remainingPercent: nil,
                resetsAt: resetsAt,
                observedAt: snapshotTime
            ))
        }

        if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
            let usedPct = sevenDay["used_percentage"] as? Double
            let resetsAt = (sevenDay["resets_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(
                type: .weekly,
                durationMinutes: 10080,
                usedPercent: usedPct,
                remainingPercent: nil,
                resetsAt: resetsAt,
                observedAt: snapshotTime
            ))
        }

        return QuotaSnapshot(
            provider: .claude,
            windows: windows,
            observedAt: snapshotTime,
            receivedAt: now,
            freshness: freshness
        )
    }

    func parseDesktopHistory(data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let latest = samples.last,
              let timestampMilliseconds = (latest["t"] as? NSNumber)?.doubleValue,
              let usage = latest["u"] as? [String: Any] else {
            throw AppError.claudeNoSnapshot
        }

        let sampledAt = Date(timeIntervalSince1970: timestampMilliseconds / 1_000)
        let age = now.timeIntervalSince(sampledAt)
        let freshness: DataFreshness = age > 1_800 ? .stale : (age > 600 ? .cached : .live)
        var windows: [QuotaWindow] = []

        if let fiveHourUsed = (usage["fh"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(
                type: .fiveHour,
                durationMinutes: 300,
                usedPercent: fiveHourUsed,
                remainingPercent: nil,
                resetsAt: nil,
                observedAt: sampledAt
            ))
        }

        if let sevenDayUsed = (usage["sd"] as? NSNumber)?.doubleValue {
            windows.append(QuotaWindow(
                type: .weekly,
                durationMinutes: 10_080,
                usedPercent: sevenDayUsed,
                remainingPercent: nil,
                resetsAt: nil,
                observedAt: sampledAt
            ))
        }

        guard !windows.isEmpty else {
            throw AppError.claudeNoSnapshot
        }

        return QuotaSnapshot(
            provider: .claude,
            windows: windows,
            observedAt: sampledAt,
            receivedAt: now,
            freshness: freshness
        )
    }

    func settingsExist() -> Bool {
        FileManager.default.fileExists(atPath: settingsPath.path)
    }

    func readCurrentSettings() -> Data? {
        try? Data(contentsOf: settingsPath)
    }
}
