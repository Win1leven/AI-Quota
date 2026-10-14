import Foundation
import Testing
@testable import AIQuota

struct DesktopAssistantTests {
    @Test func capsuleUsesMostConstrainedWindowAndDoesNotInventMissingData() {
        let sample = QuotaSnapshot(provider: .claude, windows: [
            QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 0, remainingPercent: nil, resetsAt: nil),
            QuotaWindow(type: .weekly, durationMinutes: 10080, usedPercent: 80, remainingPercent: nil, resetsAt: nil)
        ])
        #expect(sample.limitingWindow?.type == .weekly)
        #expect(sample.limitingWindow?.remainingPercent == 20)
        let missing = QuotaSnapshot(provider: .claude, windows: [QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: nil, remainingPercent: nil, resetsAt: nil)])
        #expect(missing.limitingWindow == nil)
    }

    @Test func legacySettingsRetainValuesAndNewModeSurvivesCoding() throws {
        var settings = AppSettings.default
        settings.menuBarMode = .compact
        settings.historyRetentionDays = 90
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object.removeValue(forKey: "assistantDisplayMode")
        let legacy = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.menuBarMode == .compact)
        #expect(legacy.historyRetentionDays == 90)
        #expect(legacy.effectiveDisplayMode == .menuBarOnly)
        settings.assistantDisplayMode = .both
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.effectiveDisplayMode == .both)
    }
}
