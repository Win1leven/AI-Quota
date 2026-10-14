import Foundation
import Testing
@testable import AIQuota

struct HistoryStoreTests {
    @Test func clearedHistoryIsNotReimportedAfterRestart() throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let storage = fixture.root.appendingPathComponent("history.json")
        let desktop = fixture.root.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        try fixture.history(used: 50, time: Date().addingTimeInterval(-60).timeIntervalSince1970)
        let history = HistoryStore(storageURL: storage, desktopHistoryURL: desktop)
        history.importClaudeDesktopHistory()
        #expect(history.query(provider: .claude, windowType: "five_hour", range: .fiveHours).count == 1)
        try history.clearAll()
        let reloaded = HistoryStore(storageURL: storage, desktopHistoryURL: desktop)
        reloaded.load()
        reloaded.importClaudeDesktopHistory()
        #expect(reloaded.query(provider: .claude, windowType: "five_hour", range: .fiveHours).isEmpty)
    }

    @Test func retentionAppliesToSubsequentDesktopImports() throws {
        let fixture = try ClaudeFiles()
        defer { fixture.remove() }
        let history = HistoryStore(storageURL: fixture.root.appendingPathComponent("history.json"),
            desktopHistoryURL: fixture.root.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json"))
        history.setRetentionDays(7)
        try fixture.history(used: 50, time: Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970)
        history.importClaudeDesktopHistory()
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("history.json"))
        let points = try JSONDecoder().decode([TrendPoint].self, from: data)
        #expect(points.isEmpty)
    }
}
