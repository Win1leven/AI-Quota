import Foundation

final class CodexAnalyticsService: @unchecked Sendable {
    static let shared = CodexAnalyticsService()

    private let whamOrigin = "https://chatgpt.com"
    private let usdPerCredit: Double = 40.0 / 1000.0
    // GPT-5 list prices (USD per million tokens)
    private let usdPerMInput: Double = 1.25
    private let usdPerMCachedInput: Double = 0.125
    private let usdPerMOutput: Double = 10.0
    private let lookbackDays = 45

    // MARK: - Public

    func fetchAnalytics() async throws -> UsageAnalytics {
        let token = try loadAccessToken()
        let usage = try await fetchWhamUsage(token: token)
        let daily = try await fetchDailyUsage(token: token)
        return try buildAnalytics(usage: usage, daily: daily)
    }

    // MARK: - Auth

    private func loadAccessToken() throws -> String {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else {
            throw AppError.codexNotLoggedIn
        }
        if let access = tokens["access_token"] as? String, !access.isEmpty {
            return access
        }
        if let id = tokens["id_token"] as? String, !id.isEmpty {
            return id
        }
        throw AppError.codexNotLoggedIn
    }

    // MARK: - Network

    private func fetchWhamUsage(token: String) async throws -> [String: Any] {
        let url = URL(string: "\(whamOrigin)/backend-api/wham/usage")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AppError.codexApiError(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.codexParseFailed("wham/usage invalid JSON")
        }
        return json
    }

    private func fetchDailyUsage(token: String) async throws -> [[String: Any]] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now)!
        let startStr = df.string(from: start)
        let endStr = df.string(from: end)
        let urlStr = "\(whamOrigin)/backend-api/wham/analytics/daily-workspace-usage-counts?start_date=\(startStr)&end_date=\(endStr)&group_by=day"
        let url = URL(string: urlStr)!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw AppError.codexApiError(msg)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw AppError.codexParseFailed("daily invalid JSON")
        }
        return arr
    }

    // MARK: - Build

    private func buildAnalytics(usage: [String: Any], daily: [[String: Any]]) throws -> UsageAnalytics {
        // Extract primary window for reset_at and used_percent
        let rateLimit = usage["rate_limit"] as? [String: Any]
        let primary = rateLimit?["primary_window"] as? [String: Any]
        let usedPercent = primary?["used_percent"] as? Double
        let resetAt = primary?["reset_at"] as? Double
        let windowSeconds = primary?["limit_window_seconds"] as? Double ?? 604800
        let cycleStart: String? = {
            guard let reset = resetAt, reset > 0 else { return nil }
            let start = Date(timeIntervalSince1970: reset - windowSeconds)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return df.string(from: start)
        }()

        // Use last 7 days true cumulative (not single-day extrapolation), so heavy recent usage is reflected
        let cycleStartDate = cycleStart
        let recentList: [[String: Any]] = {
            if daily.count > 7 { return Array(daily.suffix(7)) }
            return daily
        }()

        func stats(for list: [[String: Any]]) -> (credits: Double, tokens: Int, input: Int, output: Int, daily: [DailyUsage]) {
            var c = 0.0; var tok = 0; var inp = 0; var out = 0
            var mapped: [DailyUsage] = []
            for row in list {
                guard let date = row["date"] as? String,
                      let totals = row["totals"] as? [String: Any] else { continue }
                let credits = (totals["credits"] as? Double) ?? 0
                let cached = (totals["cached_text_input_tokens"] as? Int) ?? 0
                let uncached = (totals["uncached_text_input_tokens"] as? Int) ?? 0
                let output = (totals["text_output_tokens"] as? Int) ?? 0
                let totalFromField = (totals["text_total_tokens"] as? Int) ?? (cached + uncached + output)
                let turns = (totals["turns"] as? Int) ?? 0
                c += credits
                tok += totalFromField; inp += cached + uncached; out += output
                mapped.append(DailyUsage(date: date, credits: credits, cachedInputTokens: cached, uncachedInputTokens: uncached, outputTokens: output, turns: turns))
            }
            return (c, tok, inp, out, mapped)
        }

        let current = stats(for: recentList)

        // API 等价：近 7 天真累计（已为周量级，不再 *7 外推）
        let projectedWeeklyCredits: Double? = {
            guard current.credits > 0 else { return nil }
            return current.credits
        }()
        let projectedWeeklyTokens: Int? = {
            guard current.tokens > 0 else { return nil }
            return current.tokens
        }()
        let projectedWeeklyUSD: Double? = {
            if let c = projectedWeeklyCredits { return c * usdPerCredit }
            guard !current.daily.isEmpty else { return nil }
            // Per-token-type pricing (GPT-5 list): cached input is ~10x cheaper than fresh input
            return current.daily.reduce(0.0) { sum, d in
                sum
                + Double(d.uncachedInputTokens) / 1_000_000 * usdPerMInput
                + Double(d.cachedInputTokens) / 1_000_000 * usdPerMCachedInput
                + Double(d.outputTokens) / 1_000_000 * usdPerMOutput
            }
        }()

        return UsageAnalytics(
            provider: .codex,
            capturedAt: Date(),
            cycleStartDate: cycleStartDate,
            creditsUsed: current.credits,
            tokensUsed: current.tokens,
            inputTokens: current.input,
            outputTokens: current.output,
            daily: current.daily,
            projectedWeeklyCredits: projectedWeeklyCredits,
            projectedWeeklyTokens: projectedWeeklyTokens,
            projectedWeeklyUSD: projectedWeeklyUSD,
            primaryUsedPercent: usedPercent
        )
    }
}
