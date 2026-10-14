import Foundation
import Testing
@testable import AIQuota

struct QuotaProviderTests {
    @Test func waitingStateRequiresExplicitNullFromDesktop() throws {
        for field in ["", ",\"resets_at\":\"not-a-date\"", ",\"resets_at\":123"] {
            let json = "{\"five_hour\":{\"utilization\":0\(field)}}"
            let sample = try ClaudeQuotaProvider().parseOAuthUsage(data: Data(json.utf8), now: Date())
            #expect(!sample.isAwaitingFirstClaudeMessage)
        }
    }

    @Test func backendQuotaFailureDoesNotRecommendChangingLogin() {
        #expect(AppError.codexApiError("Failed to fetch usage").errorDescription?.contains("codex login") == false)
        #expect(AppError.codexApiError("Unauthorized usage request").errorDescription?.contains("codex login") == true)
    }
    @Test func waitingStateRequiresAuthoritativeZeroUsageAndAbsentReset() {
        for source: QuotaSource in [.claudeDesktop, .claudeCollector, .codexCLI] {
            let window = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 0, remainingPercent: nil, resetsAt: nil)
            #expect(!QuotaSnapshot(provider: .claude, windows: [window], source: source).isAwaitingFirstClaudeMessage)
        }
        for window in [
            QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 5, remainingPercent: nil, resetsAt: nil),
            QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 0, remainingPercent: nil, resetsAt: Date().addingTimeInterval(3600))
        ] {
            #expect(!QuotaSnapshot(provider: .claude, windows: [window], source: .claudeDesktopSession).isAwaitingFirstClaudeMessage)
        }
    }
    @Test func desktopZeroUsageWithNullFiveHourResetRemainsUnknown() throws {
        let sample = try ClaudeQuotaProvider().parseOAuthUsage(data: Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":45,"resets_at":"2030-01-07T12:00:00Z"}}"#.utf8), now: Date())
        #expect(sample.windows.count == 2)
        #expect(sample.primaryWindow?.type == .fiveHour)
        #expect(sample.primaryWindow?.usedPercent == 0)
        #expect(sample.primaryWindow?.resetsAt == nil)
        #expect(sample.windows.first(where: { $0.type == .weekly })?.resetsAt != nil)
        #expect(sample.isAwaitingFirstClaudeMessage)
    }
    @Test func desktopSessionWithoutFallbackKeepsActionableError() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let provider = ClaudeQuotaProvider(homeDirectory: fixture.root, supportDirectory: fixture.support,
            desktopUsage: { throw ClaudeDesktopUsageService.DesktopError.keychainLocked })
        do {
            _ = try await provider.refresh()
            Issue.record("Expected protected desktop session error")
        } catch {
            #expect(error.localizedDescription == ClaudeDesktopUsageService.DesktopError.keychainLocked.errorDescription)
        }
    }
    @Test func desktopSessionFailurePreservesLocalQuotaWithSafeWarning() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let sampled = Date().timeIntervalSince1970 - 30
        try fixture.history(used: 40, time: sampled)
        let provider = ClaudeQuotaProvider(homeDirectory: fixture.root, supportDirectory: fixture.support,
            desktopUsage: { throw ClaudeDesktopUsageService.DesktopError.unauthorized })
        let sample = try await provider.refresh()
        #expect(sample.source == .claudeDesktop)
        #expect(sample.primaryWindow?.usedPercent == 40)
        #expect(sample.primaryWindow?.resetsAt == nil)
        #expect(sample.observedAt.timeIntervalSince1970 == sampled)
        #expect(sample.warning == ClaudeDesktopUsageService.DesktopError.unauthorized.errorDescription)
        #expect(sample.aged().warning == sample.warning)
    }

    @Test func desktopResponseWithoutWindowsFallsBackRatherThanInventingReset() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        try fixture.history(used: 40, time: Date().timeIntervalSince1970 - 30)
        let provider = ClaudeQuotaProvider(homeDirectory: fixture.root, supportDirectory: fixture.support,
            desktopUsage: { Data(#"{"five_hour":null,"seven_day":null}"#.utf8) })
        let sample = try await provider.refresh()
        #expect(sample.source == .claudeDesktop)
        #expect(sample.warning != nil)
        #expect(sample.primaryWindow?.resetsAt == nil)
    }
    @Test func desktopSessionUsageSuppliesRealResetsWithoutClaudeCode() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        try fixture.history(used: 40, time: Date().timeIntervalSince1970 - 20)
        let provider = ClaudeQuotaProvider(homeDirectory: fixture.root, supportDirectory: fixture.support,
            desktopUsage: { Data(#"{"five_hour":{"utilization":15,"resets_at":"2030-01-01T12:00:00Z"},"seven_day":{"utilization":45,"resets_at":"2030-01-07T12:00:00Z"}}"#.utf8) })
        let sample = try await provider.refresh()
        #expect(sample.windows.count == 2)
        #expect(sample.primaryWindow?.usedPercent == 15)
        #expect(sample.primaryWindow?.resetsAt != nil)
        #expect(sample.source?.rawValue == "claudeDesktopSession")
    }

    @Test func desktopUsageRejectsInvalidPercentAndKeepsOptionalResetUnknown() throws {
        let provider = ClaudeQuotaProvider()
        for value in ["true", "-1", "101"] {
            #expect(throws: (any Error).self) {
                try provider.parseOAuthUsage(data: Data("{\"five_hour\":{\"utilization\":\(value)}}".utf8), now: Date())
            }
        }
        let sample = try provider.parseOAuthUsage(data: Data(#"{"seven_day":{"utilization":45,"resets_at":null}}"#.utf8), now: Date())
        #expect(sample.windows.count == 1)
        #expect(sample.windows[0].resetsAt == nil)
    }

    @Test func configuredClaudeWaitsForFirstSample() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let settings = fixture.root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "'/somewhere/claude_status_collector_v2.sh'"]]).write(to: settings)
        let snapshot = try await fixture.provider.refresh()
        #expect(snapshot.freshness == .unknown)
        #expect(snapshot.windows.isEmpty)
    }

    @Test func codexIncludesSecondaryAndPrefersPerLimitEnvelope() throws {
        let data = Data(#"{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1900500000}}}}}"#.utf8)
        let windows = try CodexQuotaProvider().parseWindows(from: data, now: Date())
        #expect(windows.count == 2)
        #expect(windows.first(where: { $0.type == .fiveHour })?.remainingPercent == 75)
        #expect(windows.first(where: { $0.type == .weekly })?.resetsAt == Date(timeIntervalSince1970: 1900500000))
    }

    @Test func codexSecondaryOnlyAndNumericErrorIDs() throws {
        let provider = CodexQuotaProvider()
        let windows = try provider.parseWindows(from: Data(#"{"id":2,"result":{"rateLimits":{"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}"#.utf8), now: Date())
        #expect(windows.count == 1)
        #expect(throws: (any Error).self) {
            try provider.parseWindows(from: Data(#"{"id":2,"error":{"message":"unauthorized"}}"#.utf8), now: Date())
        }
    }

    @Test func claudeCollectorWinsOverDesktopAndPreservesSampleTime() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let sampled = Date().timeIntervalSince1970 - 30
        try fixture.collector(["sampled_at": sampled, "rate_limits": ["five_hour": ["used_percentage": 25, "resets_at": 1900000000]]])
        try fixture.history(used: 80, time: Date().timeIntervalSince1970)
        let snapshot = try await fixture.provider.refresh()
        #expect(snapshot.primaryWindow?.usedPercent == 25)
        #expect(snapshot.primaryWindow?.resetsAt == Date(timeIntervalSince1970: 1900000000))
        #expect(snapshot.observedAt.timeIntervalSince1970 == sampled)
    }

    @Test func claudeNewFileDoesNotMakeOldSampleLive() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        try fixture.collector(["sampled_at": Date().timeIntervalSince1970 - 8000, "rate_limits": ["five_hour": ["used_percentage": 25]]])
        let snapshot = try await fixture.provider.refresh()
        #expect(snapshot.freshness == .stale)
    }

    @Test func claudeRejectsInvalidSamples() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        for sample: [String: Any] in [
            ["rate_limits": ["five_hour": ["used_percentage": 25]]],
            ["sampled_at": Date().timeIntervalSince1970 + 3600, "rate_limits": ["five_hour": ["used_percentage": 25]]],
            ["sampled_at": Date().timeIntervalSince1970, "rate_limits": ["five_hour": ["used_percentage": 1700000000]]]
        ] {
            try fixture.collector(sample)
            await #expect(throws: (any Error).self) { try await fixture.provider.refresh() }
        }
    }

    @Test func claudeFallsBackToNewerDesktopWhenCollectorIsOld() async throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        try fixture.collector(["sampled_at": Date().timeIntervalSince1970 - 8000, "rate_limits": ["five_hour": ["used_percentage": 25]]])
        try fixture.history(used: 40, time: Date().timeIntervalSince1970 - 30)
        let snapshot = try await fixture.provider.refresh()
        #expect(snapshot.primaryWindow?.usedPercent == 40)
        #expect(snapshot.primaryWindow?.resetsAt == nil)
        #expect(snapshot.freshness == .cached)
    }
}

struct ClaudeFiles {
    let root: URL
    let support: URL
    var provider: ClaudeQuotaProvider { ClaudeQuotaProvider(homeDirectory: root, supportDirectory: support) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuota tests \(UUID())")
        support = root.appendingPathComponent("Application Support/AIQuota")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    func collector(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: support.appendingPathComponent("claude_quota_snapshot.json"), options: .atomic)
    }
    func history(used: Double, time: Double) throws {
        let path = root.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["samples": [["t": time * 1000, "u": ["fh": used]]]]).write(to: path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
