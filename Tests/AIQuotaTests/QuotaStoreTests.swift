import Foundation
import Testing
@testable import AIQuota

@MainActor
struct QuotaStoreTests {
    @Test func expiredDesktopSessionKeepsNewerSnapshotAndRecoveryHint() async throws {
        let fixture = try StoreFiles()
        let claude = try ClaudeFiles()
        defer { fixture.remove(); claude.remove() }
        let observed = Date().addingTimeInterval(-10)
        let store = fixture.store()
        store.snapshots[.claude] = QuotaSnapshot(provider: .claude,
            windows: [QuotaWindow(type: .weekly, durationMinutes: 10080, usedPercent: 45,
                remainingPercent: nil, resetsAt: Date(timeIntervalSince1970: 1900500000), observedAt: observed)],
            observedAt: observed, source: .claudeDesktopSession)
        try claude.history(used: 40, time: observed.timeIntervalSince1970 - 100)
        store.registerProvider(ClaudeQuotaProvider(homeDirectory: claude.root, supportDirectory: claude.support,
            desktopUsage: { throw ClaudeDesktopUsageService.DesktopError.unauthorized }))
        await store.refresh(.claude)
        #expect(store.claudeSnapshot?.source == .claudeDesktopSession)
        #expect(store.claudeSnapshot?.primaryWindow?.usedPercent == 45)
        #expect(store.claudeSnapshot?.primaryWindow?.resetsAt != nil)
        #expect(store.errors[.claude] == ClaudeDesktopUsageService.DesktopError.unauthorized.errorDescription)
    }
    @Test @MainActor func desktopSessionAccessIsOptInAndPersistsAcrossRestart() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let store = fixture.store()
        #expect(!store.claudeDesktopSessionEnabled)
        store.setClaudeDesktopSessionEnabled(true)
        #expect(fixture.store().claudeDesktopSessionEnabled)
        store.setClaudeDesktopSessionEnabled(false)
        #expect(!fixture.store().claudeDesktopSessionEnabled)
    }
    @Test func lowestMenuModeIncludesWeeklyConstraint() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let store = fixture.store()
        store.settings.menuBarMode = .lowestOnly
        store.snapshots[.codex] = QuotaSnapshot(provider: .codex, windows: [
            QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 20, remainingPercent: nil, resetsAt: nil),
            QuotaWindow(type: .weekly, durationMinutes: 10080, usedPercent: 95, remainingPercent: nil, resetsAt: nil)
        ])
        #expect(store.menuBarText.contains("5%"))
        #expect(!store.menuBarText.contains("80%"))
    }

    @Test func olderDesktopFallbackCannotReplaceNewerCollectorCache() async throws {
        let fixture = try StoreFiles()
        let claude = try ClaudeFiles()
        defer { fixture.remove(); claude.remove() }
        let observed = Date().addingTimeInterval(-60)
        let store = fixture.store()
        store.snapshots[.claude] = QuotaSnapshot(provider: .claude,
            windows: [QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 25,
                remainingPercent: nil, resetsAt: Date(timeIntervalSince1970: 1900000000), observedAt: observed)],
            observedAt: observed, source: .claudeCollector)
        try claude.history(used: 80, time: observed.timeIntervalSince1970 - 300)
        store.registerProvider(claude.provider)
        await store.refresh(.claude)
        #expect(store.claudeSnapshot?.primaryWindow?.usedPercent == 25)
        #expect(store.claudeSnapshot?.primaryWindow?.resetsAt == Date(timeIntervalSince1970: 1900000000))
        #expect(store.errors[.claude] != nil)
    }

    @Test func persistedLiveSampleAgesOnLoad() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let old = Date().addingTimeInterval(-8000)
        let snapshot = QuotaSnapshot(provider: .claude, windows: [QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 25, remainingPercent: nil, resetsAt: nil, observedAt: old)], observedAt: old)
        fixture.defaults.set(try JSONEncoder().encode(["claude": snapshot]), forKey: "com.aiquota.snapshots")
        let store = fixture.store()
        #expect(store.claudeSnapshot?.freshness == .stale)
    }

    @Test func failedRefreshPreservesSampleAndError() async throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let store = fixture.store()
        let observed = Date().addingTimeInterval(-60)
        store.snapshots[.claude] = QuotaSnapshot(provider: .claude, windows: [QuotaWindow(type: .fiveHour, durationMinutes: 300, usedPercent: 25, remainingPercent: nil, resetsAt: nil, observedAt: observed)], observedAt: observed, source: .claudeCollector)
        store.registerProvider(FailingClaudeProvider())
        await store.refresh(.claude)
        #expect(store.claudeSnapshot?.primaryWindow?.remainingPercent == 75)
        #expect(store.claudeSnapshot?.observedAt == observed)
        #expect(store.claudeSnapshot?.source == .claudeCollector)
        #expect(store.errors[.claude] != nil)
    }

    @Test func unconfiguredProviderRemainsActionable() async throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let store = fixture.store()
        store.registerProvider(ClaudeQuotaProvider(homeDirectory: fixture.root, supportDirectory: fixture.root))
        await store.refresh(.claude)
        #expect(store.claudeSnapshot?.freshness == .notConfigured)
    }
}

struct FailingClaudeProvider: QuotaProviderProtocol {
    let id = ProviderID.claude
    let isAvailable = true
    func refresh() async throws -> QuotaSnapshot { throw AppError.claudeNoSnapshot }
    func isInstalledAndLoggedIn() async -> Bool { false }
}

@MainActor
struct StoreFiles {
    let root: URL
    let suite = "AIQuotaTests.\(UUID())"
    let defaults: UserDefaults
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuota store \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }
    func store() -> QuotaStore {
        QuotaStore(userDefaults: defaults, historyStore: HistoryStore(storageURL: root.appendingPathComponent("history.json"), desktopHistoryURL: root.appendingPathComponent("desktop.json")))
    }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
