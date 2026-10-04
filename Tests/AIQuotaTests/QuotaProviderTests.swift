import Foundation
import Testing
@testable import AIQuota

struct QuotaProviderTests {
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
