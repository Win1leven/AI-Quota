import Foundation

final class ClaudeQuotaProvider: QuotaProviderProtocol, @unchecked Sendable {
    let id = ProviderID.claude
    private let homeDirectory: URL
    private let supportDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIQuota")) {
        self.homeDirectory = homeDirectory
        self.supportDirectory = supportDirectory
    }

    var isAvailable: Bool {
        desktopHistoryFileExists() || collectorFileExists()
    }

    private var desktopHistoryPath: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    private var collectorPath: URL {
        supportDirectory.appendingPathComponent("claude_quota_snapshot.json")
    }

    private var settingsPath: URL {
        let home = homeDirectory
        return home.appendingPathComponent(".claude/settings.json")
    }

    func refresh() async throws -> QuotaSnapshot {
        let now = Date()

        let collector = try? Data(contentsOf: collectorPath)
        let desktop = try? Data(contentsOf: desktopHistoryPath)
        let collectorSnapshot = collector.flatMap { try? parseCollectorSnapshot(data: $0, now: now) }
        let desktopSnapshot = desktop.flatMap { try? parseDesktopHistory(data: $0, now: now) }

        // An active collector carries reset times that desktop history cannot provide.
        if let collectorSnapshot, now.timeIntervalSince(collectorSnapshot.observedAt) <= 900 {
            return collectorSnapshot
        }
        if let latest = [collectorSnapshot, desktopSnapshot].compactMap({ $0 })
            .max(by: { $0.observedAt < $1.observedAt }) {
            return latest
        }
        if collectorFileExists() || desktopHistoryFileExists() {
            throw AppError.claudeNoSnapshot
        }
        return QuotaSnapshot(provider: .claude, windows: [], observedAt: now, receivedAt: now, freshness: .notConfigured)
    }

    func isInstalledAndLoggedIn() async -> Bool {
        guard let snapshot = try? await refresh() else { return false }
        return !snapshot.windows.isEmpty
    }

    private func desktopHistoryFileExists() -> Bool {
        FileManager.default.fileExists(atPath: desktopHistoryPath.path)
    }

    private func collectorFileExists() -> Bool {
        FileManager.default.fileExists(atPath: collectorPath.path)
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

    func parseCollectorSnapshot(data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = json["rate_limits"] as? [String: Any],
              let seconds = (json["sampled_at"] as? NSNumber)?.doubleValue,
              seconds.isFinite, seconds > 0, seconds <= now.timeIntervalSince1970 + 60 else {
            throw AppError.claudeNoSnapshot
        }
        let sampledAt = Date(timeIntervalSince1970: seconds)
        let windows: [QuotaWindow] = [("five_hour", WindowType.fiveHour, 300), ("seven_day", .weekly, 10080)].compactMap { key, type, duration in
            guard let value = rateLimits[key] as? [String: Any],
                  let used = (value["used_percentage"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { return nil }
            let reset = (value["resets_at"] as? NSNumber)?.doubleValue
            return QuotaWindow(type: type, durationMinutes: duration, usedPercent: used, remainingPercent: nil,
                resetsAt: reset.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }, observedAt: sampledAt)
        }
        guard !windows.isEmpty else { throw AppError.claudeNoSnapshot }
        return QuotaSnapshot(provider: .claude, windows: windows, observedAt: sampledAt, receivedAt: now,
            freshness: .live, source: .claudeCollector).aged(at: now)
    }

    func parseDesktopHistory(data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let latest = samples.max(by: { (($0["t"] as? NSNumber)?.doubleValue ?? 0) < (($1["t"] as? NSNumber)?.doubleValue ?? 0) }),
              let timestampMilliseconds = (latest["t"] as? NSNumber)?.doubleValue,
              let usage = latest["u"] as? [String: Any] else {
            throw AppError.claudeNoSnapshot
        }

        guard timestampMilliseconds.isFinite, timestampMilliseconds > 0, timestampMilliseconds / 1000 <= now.timeIntervalSince1970 + 60 else { throw AppError.claudeNoSnapshot }
        let sampledAt = Date(timeIntervalSince1970: timestampMilliseconds / 1_000)
        let age = now.timeIntervalSince(sampledAt)
        let freshness: DataFreshness = age > 1_800 ? .stale : .cached
        var windows: [QuotaWindow] = []

        if let fiveHourUsed = (usage["fh"] as? NSNumber)?.doubleValue, fiveHourUsed.isFinite, (0...100).contains(fiveHourUsed) {
            windows.append(QuotaWindow(
                type: .fiveHour,
                durationMinutes: 300,
                usedPercent: fiveHourUsed,
                remainingPercent: nil,
                resetsAt: nil,
                observedAt: sampledAt
            ))
        }

        if let sevenDayUsed = (usage["sd"] as? NSNumber)?.doubleValue, sevenDayUsed.isFinite, (0...100).contains(sevenDayUsed) {
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
            freshness: freshness,
            source: .claudeDesktop
        )
    }

    func settingsExist() -> Bool {
        FileManager.default.fileExists(atPath: settingsPath.path)
    }

    func readCurrentSettings() -> Data? {
        try? Data(contentsOf: settingsPath)
    }
}
