import Foundation

final class ClaudeAnalyticsService: @unchecked Sendable {
    static let shared = ClaudeAnalyticsService()

    // Anthropic list prices (USD per million tokens), Sonnet tier
    private let usdPerMFreshInput: Double = 3.0
    private let usdPerMCacheWrite: Double = 3.75
    private let usdPerMCacheRead: Double = 0.30
    private let usdPerMOutput: Double = 15.0
    private let claudePlanHistoryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    private let buddyTokensPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/buddy-tokens.json")

    func fetchAnalytics(currentSnapshot: QuotaSnapshot?) async throws -> UsageAnalytics {
        // Try local daily tokens from buddy-tokens.json
        let dailyTokens = loadBuddyDailyTokens()
        let weeklyUsedPercent = currentSnapshot?.windows.first(where: { $0.type == .weekly })?.usedPercent
            ?? currentSnapshot?.primaryWindow?.usedPercent

        let creditsUsed = 0.0
        let tokensUsed = dailyTokens.totalToday
        let projectedWeeklyTokens: Int? = {
            guard tokensUsed > 0 else { return nil }
            return tokensUsed // 近7天真累计，已为周量级
        }()
        let projectedUSD: Double? = {
            guard !dailyTokens.daily.isEmpty else { return nil }
            return dailyTokens.daily.reduce(0.0) { sum, d in
                sum
                + Double(d.freshInputTokens) / 1_000_000 * usdPerMFreshInput
                + Double(d.cacheWriteTokens) / 1_000_000 * usdPerMCacheWrite
                + Double(d.cachedInputTokens) / 1_000_000 * usdPerMCacheRead
                + Double(d.outputTokens) / 1_000_000 * usdPerMOutput
            }
        }()

        // Try to enrich from Anthropic API if OAuth token available (best effort, ignore failure)
        if let apiAnalytics = try? await fetchAnthropicUsageIfAvailable() {
            return apiAnalytics
        }

        return UsageAnalytics(
            provider: .claude,
            capturedAt: Date(),
            cycleStartDate: nil,
            creditsUsed: creditsUsed,
            tokensUsed: tokensUsed,
            inputTokens: tokensUsed, // buddy gives total, treat as input+output blended
            outputTokens: 0,
            daily: dailyTokens.daily,
            projectedWeeklyCredits: nil,
            projectedWeeklyTokens: projectedWeeklyTokens,
            projectedWeeklyUSD: projectedUSD,
            primaryUsedPercent: weeklyUsedPercent
        )
    }

    private struct BuddyTokens: Codable {
        struct Entry: Codable { let date: String; let tokens: Int }
        // file shape: {"tokens-today":{"date":"2026-08-21","tokens":96252}}
        let tokensToday: Entry?
        enum CodingKeys: String, CodingKey { case tokensToday = "tokens-today" }
    }

    private func loadBuddyDailyTokens() -> (totalToday: Int, daily: [DailyUsage]) {
        var total = 0
        var daily: [DailyUsage] = []
        if let data = try? Data(contentsOf: buddyTokensPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = obj["tokens-today"] as? [String: Any],
           let date = entry["date"] as? String,
           let tokens = entry["tokens"] as? Int {
            total = tokens
            daily = [DailyUsage(date: date, credits: 0, cachedInputTokens: 0, uncachedInputTokens: tokens, outputTokens: 0, turns: 0)]
        }
        // Enrich with last 7 days session aggregate for more accurate weekly (when recent usage high)
        let sessionDaily = aggregateSessionDaily(days: 7)
        let sessionTotal = sessionDaily.reduce(0) { $0 + $1.cachedInputTokens + $1.uncachedInputTokens + $1.outputTokens }
        if sessionTotal > 0 {
            // Use session daily breakdown as source of truth when it has data
            return (sessionTotal, sessionDaily)
        }
        return (total, daily)
    }

    private func aggregateSessionDaily(days: Int) -> [DailyUsage] {
        let projectsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var byDate: [String: (cacheRead: Int, cacheWrite: Int, input: Int, out: Int, turns: Int)] = [:]
        var seenMessageIDs = Set<String>()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let mtimeGate = Calendar.current.date(byAdding: .day, value: -(days + 7), to: Date()) ?? Date()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone.current

        guard let walker = FileManager.default.enumerator(at: projectsURL, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        for case let fileURL as URL in walker {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = vals.contentModificationDate, mod < mtimeGate { continue }
            guard let content = try? String(contentsOf: fileURL) else { continue }
            for line in content.components(separatedBy: .newlines) where line.contains("\"usage\"") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                let message = obj["message"] as? [String: Any]
                guard let usage = (obj["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any]) else { continue }
                // Dedup: subagent transcripts replay parent session messages
                if let mid = message?["id"] as? String {
                    if seenMessageIDs.contains(mid) { continue }
                    seenMessageIDs.insert(mid)
                }
                let ts = (obj["timestamp"] as? String) ?? ""
                let date = String(ts.prefix(10))
                guard let day = df.date(from: date), day >= cutoff else { continue }
                let inp = (usage["input_tokens"] as? Int) ?? 0
                let out = (usage["output_tokens"] as? Int) ?? 0
                let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                var cur = byDate[date] ?? (0,0,0,0,0)
                cur.cacheRead += cr; cur.cacheWrite += cw; cur.input += inp; cur.out += out; cur.turns += 1
                byDate[date] = cur
            }
        }
        return byDate.map { (date, v) in
            DailyUsage(date: date, credits: 0,
                       cachedInputTokens: v.cacheRead,
                       uncachedInputTokens: v.input + v.cacheWrite,
                       outputTokens: v.out,
                       turns: v.turns,
                       cacheWriteTokens: v.cacheWrite)
        }.sorted { $0.date < $1.date }
    }

    private func aggregateSessionTokens(days: Int) -> Int {
        let projectsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: projectsURL.path) else { return 0 }
        var total = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for dir in contents {
            let dirURL = projectsURL.appendingPathComponent(dir)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let fileURL = dirURL.appendingPathComponent(file)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let mod = attrs[.modificationDate] as? Date, mod >= cutoff else { continue }
                guard let data = try? String(contentsOf: fileURL) else { continue }
                // quick scan for "usage":{"input_tokens":x,"output_tokens":y
                for line in data.components(separatedBy: .newlines) where line.contains("\"usage\"") {
                    if let d = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let usage = obj["usage"] as? [String: Any] {
                        let inp = (usage["input_tokens"] as? Int) ?? 0
                        let out = (usage["output_tokens"] as? Int) ?? 0
                        let cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                        let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        total += inp + out + cc + cr
                    }
                }
            }
        }
        return total
    }

    // MARK: - Anthropic private usage (best effort)
    private func fetchAnthropicUsageIfAvailable() async throws -> UsageAnalytics? {
        // Look for OAuth token in keychain is complex; try reading from Claude Code's token file via CLI helper
        // For now, probe a local endpoint: if `claude` CLI can dump usage, use it
        // Fallback: try calling https://api.anthropic.com/api/organizations/usage with token from auth if found
        let token = try? loadClaudeOAuthToken()
        guard let token else { return nil }

        let url = URL(string: "https://api.anthropic.com/api/organizations/usage?limit=30")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            return nil
        }
        // Aggregate last 7 days
        var total = 0; var daily: [DailyUsage] = []
        for row in arr.prefix(7) {
            let date = (row["date"] as? String) ?? ""
            let toks = (row["tokens"] as? Int) ?? ((row["input_tokens"] as? Int) ?? 0) + ((row["output_tokens"] as? Int) ?? 0)
            total += toks
            daily.append(DailyUsage(date: date, credits: 0, cachedInputTokens: 0, uncachedInputTokens: toks, outputTokens: 0, turns: 0))
        }
        let weekly = total // if last 7 days already weekly
        return UsageAnalytics(
            provider: .claude,
            capturedAt: Date(),
            cycleStartDate: nil,
            creditsUsed: 0,
            tokensUsed: total,
            inputTokens: total,
            outputTokens: 0,
            daily: daily,
            projectedWeeklyCredits: nil,
            projectedWeeklyTokens: weekly,
            projectedWeeklyUSD: Double(weekly) / 1_000_000 * usdPerMFreshInput,
            primaryUsedPercent: nil
        )
    }

    private func loadClaudeOAuthToken() throws -> String {
        // Try keychain via `security` is slow; try reading from Claude Code's internal storage via process
        // Check if `claude` CLI can output token (undocumented)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "security find-generic-password -s 'Claude Code-credentials' -a rc -w 2>/dev/null | head -c 2000"]
        let pipe = Pipe(); proc.standardOutput = pipe
        try? proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("sk-ant-") { return out.trimmingCharacters(in: .whitespacesAndNewlines) }
        throw AppError.claudeNotConfigured
    }
}
