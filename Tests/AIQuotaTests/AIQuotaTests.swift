import Testing
import Foundation
@testable import AIQuota

struct AIQuotaTests {
    @Test func testModelCreation() {
        let window = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 30, remainingPercent: nil as Double?, resetsAt: Date())
        #expect(window.remainingPercent == 70)
        #expect(window.type == .fiveHour)
    }

    @Test func testWindowTypeMapping() {
        #expect(WindowType.from(durationMinutes: 300) == .fiveHour)
        #expect(WindowType.from(durationMinutes: 10080) == .weekly)
        #expect(WindowType.from(durationMinutes: 42) == .unknown)
    }

    @Test func testFreshnessStates() {
        #expect(DataFreshness.live.displayName == "Live")
        #expect(DataFreshness.stale.displayName == "Stale")
    }

    @Test func testSnapshotPrimaryWindow() {
        let now = Date()
        let fiveHour = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 30, remainingPercent: nil as Double?, resetsAt: now)
        let weekly = QuotaWindow(type: .weekly, durationMinutes: 10080, usedPercent: 50, remainingPercent: nil as Double?, resetsAt: now)
        let snapshot = QuotaSnapshot(provider: .codex, windows: [weekly, fiveHour])
        #expect(snapshot.primaryWindow?.type == .fiveHour)
        #expect(snapshot.primaryWindow?.remainingPercent == 70)
    }

    @Test func testPercentClamping() {
        let window = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 150, remainingPercent: nil as Double?, resetsAt: Date())
        #expect(window.usedPercent == 100)
        #expect(window.remainingPercent == 0)

        let window2 = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: -10, remainingPercent: nil as Double?, resetsAt: Date())
        #expect(window2.usedPercent == 0)
        #expect(window2.remainingPercent == 100)
    }

    @Test func testExplicitRemainingRespected() {
        let window = QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 30, remainingPercent: 80, resetsAt: Date())
        #expect(window.remainingPercent == 80)
    }

    @Test func testClaudeDesktopHistoryParsing() throws {
        let now = Date(timeIntervalSince1970: 1_784_880_900)
        let data = Data(#"{"version":2,"samples":[{"t":1784880812179,"org":"test","u":{"fh":14,"sd":5}}]}"#.utf8)
        let snapshot = try ClaudeQuotaProvider().parseDesktopHistory(data: data, now: now)

        #expect(snapshot.freshness == .live)
        #expect(snapshot.windows.first(where: { $0.type == .fiveHour })?.usedPercent == 14)
        #expect(snapshot.windows.first(where: { $0.type == .weekly })?.usedPercent == 5)
        #expect(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    @Test func testClaudeOldDesktopHistoryIsStale() throws {
        let now = Date(timeIntervalSince1970: 1_784_884_000)
        let data = Data(#"{"version":2,"samples":[{"t":1784880812179,"org":"test","u":{"fh":14,"sd":5}}]}"#.utf8)
        let snapshot = try ClaudeQuotaProvider().parseDesktopHistory(data: data, now: now)

        #expect(snapshot.freshness == .stale)
    }

    @Test func testClaudeOAuthUsageParsingIncludesResetTimes() throws {
        let now = Date(timeIntervalSince1970: 1_784_880_900)
        let data = Data(#"{"five_hour":{"utilization":14,"resets_at":"2026-07-24T12:40:00.000Z"},"seven_day":{"utilization":5,"resets_at":"2026-07-30T00:59:00Z"}}"#.utf8)
        let snapshot = try ClaudeQuotaProvider().parseOAuthUsage(data: data, now: now)

        #expect(snapshot.freshness == .live)
        #expect(snapshot.windows.first(where: { $0.type == .fiveHour })?.usedPercent == 14)
        #expect(snapshot.windows.first(where: { $0.type == .weekly })?.usedPercent == 5)
        #expect(snapshot.windows.allSatisfy { $0.resetsAt != nil })
    }
}
