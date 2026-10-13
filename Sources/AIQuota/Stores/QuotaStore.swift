import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshots: [ProviderID: QuotaSnapshot] = [:]
    @Published var analytics: [ProviderID: UsageAnalytics] = [:]
    @Published var isLoading: Set<ProviderID> = []
    @Published var isLoadingAnalytics: Set<ProviderID> = []
    @Published var errors: [ProviderID: String] = [:]
    @Published var settings: AppSettings = .default
    @Published private(set) var claudeDesktopSessionEnabled = false
    @Published var isFloatingPanelFixed: Bool = false

    private var providers: [ProviderID: QuotaProviderProtocol] = [:]
    private var refreshTimers: [ProviderID: Timer] = [:]
    private var analyticsTimers: [ProviderID: Timer] = [:]
    private var freshnessTimer: Timer?
    private let historyStore: HistoryStore

    private let settingsKey = "com.aiquota.settings"
    private let snapshotKey = "com.aiquota.snapshots"
    private let analyticsKey = "com.aiquota.analytics"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, historyStore: HistoryStore = HistoryStore()) {
        self.userDefaults = userDefaults
        claudeDesktopSessionEnabled = userDefaults.bool(forKey: "com.aiquota.claudeDesktopSessionEnabled")
        self.historyStore = historyStore
        loadSettings()
        historyStore.load()
        historyStore.setRetentionDays(settings.historyRetentionDays)
        historyStore.importClaudeDesktopHistory()
        loadSnapshots()
        loadAnalytics()
    }

    private func loadSnapshots() {
        guard let data = userDefaults.data(forKey: snapshotKey),
              let dict = try? JSONDecoder().decode([String: QuotaSnapshot].self, from: data) else {
            return
        }
        for (key, value) in dict {
            if let id = ProviderID(rawValue: key) {
                snapshots[id] = value.aged()
            }
        }
    }

    private func persistSnapshot(_ snapshot: QuotaSnapshot) {
        var dict = [String: QuotaSnapshot]()
        for (id, snap) in snapshots {
            dict[id.rawValue] = snap
        }
        dict[snapshot.provider.rawValue] = snapshot
        if let data = try? JSONEncoder().encode(dict) {
            userDefaults.set(data, forKey: snapshotKey)
        }
    }

    private func loadAnalytics() {
        guard let data = userDefaults.data(forKey: analyticsKey),
              let dict = try? JSONDecoder().decode([String: UsageAnalytics].self, from: data) else {
            return
        }
        for (key, value) in dict {
            if let id = ProviderID(rawValue: key) {
                analytics[id] = value
            }
        }
    }

    private func persistAnalytics(_ a: UsageAnalytics) {
        var dict = [String: UsageAnalytics]()
        for (id, v) in analytics { dict[id.rawValue] = v }
        dict[a.provider.rawValue] = a
        if let data = try? JSONEncoder().encode(dict) {
            userDefaults.set(data, forKey: analyticsKey)
        }
    }

    func registerProvider(_ provider: QuotaProviderProtocol) {
        providers[provider.id] = provider
    }

    func setClaudeDesktopSessionEnabled(_ enabled: Bool) {
        claudeDesktopSessionEnabled = enabled
        userDefaults.set(enabled, forKey: "com.aiquota.claudeDesktopSessionEnabled")
    }

    func getProvider(_ id: ProviderID) -> QuotaProviderProtocol? {
        providers[id]
    }

    func refresh(_ id: ProviderID) async {
        guard let provider = providers[id] else {
            errors[id] = AppError.providerUnavailable(id.displayName).errorDescription
            return
        }
        guard !isLoading.contains(id) else { return }

        isLoading.insert(id)
        errors[id] = nil

        do {
            let snapshot = try await refreshWithTimeout(provider: provider, id: id)
            if snapshot.windows.isEmpty, snapshots[id]?.windows.isEmpty == false {
                throw AppError.providerUnavailable(id.displayName)
            }
            if let current = snapshots[id], !current.windows.isEmpty,
               snapshot.observedAt < current.observedAt {
                if let warning = snapshot.warning { throw AppError.quotaRefreshWarning(warning) }
                throw AppError.olderQuotaSample
            }
            let updated = snapshot.aged()
            if id == .claude {
                historyStore.importClaudeDesktopHistory()
            }
            historyStore.record(snapshot: updated)
            snapshots[id] = updated
            errors[id] = updated.warning
            persistSnapshot(updated)
        } catch {
            if let existing = snapshots[id] {
                // Keep the last known sample and its source while exposing the failure.
                let stale = QuotaSnapshot(
                    provider: existing.provider,
                    windows: existing.windows,
                    observedAt: existing.observedAt,
                    receivedAt: existing.receivedAt,
                    freshness: .stale,
                    source: existing.source
                )
                snapshots[id] = stale
                persistSnapshot(stale)
            }
            errors[id] = error.localizedDescription
        }

        isLoading.remove(id)
    }

    private func refreshWithTimeout(provider: QuotaProviderProtocol, id: ProviderID) async throws -> QuotaSnapshot {
        let timeout: Duration = id == .codex ? .seconds(20) : .seconds(30)
        return try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            group.addTask {
                try await provider.refresh()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                throw AppError.providerUnavailable(id.displayName)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func refreshAll() async {
        await refreshQuotas()
        await refreshAnalyticsAll()
    }

    func refreshQuotas() async {
        async let codex: Void = refresh(.codex)
        async let claude: Void = refresh(.claude)
        _ = await (codex, claude)
    }

    func manualRefreshCodex() async {
        await refresh(.codex)
    }

    func manualRefreshClaude() async {
        await refresh(.claude)
    }

    // MARK: - Analytics

    func refreshAnalytics(_ id: ProviderID) async {
        guard !isLoadingAnalytics.contains(id) else { return }
        isLoadingAnalytics.insert(id)
        defer { isLoadingAnalytics.remove(id) }

        do {
            let result: UsageAnalytics
            switch id {
            case .codex:
                result = try await CodexAnalyticsService.shared.fetchAnalytics()
            case .claude:
                result = try await ClaudeAnalyticsService.shared.fetchAnalytics(currentSnapshot: snapshots[.claude])
            }
            analytics[id] = result
            persistAnalytics(result)
        } catch {
            // Keep stale analytics on failure; surface only if no data yet
            if analytics[id] == nil {
                // silent: leave empty, UI will hide row
            }
        }
    }

    func refreshAnalyticsAll() async {
        async let a: Void = refreshAnalytics(.codex)
        async let b: Void = refreshAnalytics(.claude)
        _ = await (a, b)
    }

    func startPeriodicRefresh() {
        freshnessTimer?.invalidate()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshots = self.snapshots.mapValues { $0.aged() }
            }
        }
        for id in ProviderID.allCases {
            let interval: TimeInterval = id == .codex ? settings.codexRefreshInterval : 120
            refreshTimers[id]?.invalidate()
            refreshTimers[id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { [weak self] in
                    await self?.refresh(id)
                }
            }
        }
        // Analytics refresh every 5 min for Codex, 10 min for Claude
        for id in ProviderID.allCases {
            let interval: TimeInterval = id == .codex ? 300 : 600
            analyticsTimers[id]?.invalidate()
            analyticsTimers[id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { [weak self] in
                    await self?.refreshAnalytics(id)
                }
            }
        }
    }

    func stopPeriodicRefresh() {
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        for timer in refreshTimers.values {
            timer.invalidate()
        }
        refreshTimers.removeAll()
        for timer in analyticsTimers.values { timer.invalidate() }
        analyticsTimers.removeAll()
    }

    var codexSnapshot: QuotaSnapshot? { snapshots[.codex] }
    var claudeSnapshot: QuotaSnapshot? { snapshots[.claude] }

    func trendPoints(for provider: ProviderID, windowType: WindowType?, range: TrendRange) -> [TrendPoint] {
        guard let windowType else { return [] }
        return historyStore.query(provider: provider, windowType: windowType.rawValue, range: range)
    }

    var menuBarText: String {
        if settings.menuBarMode == .lowestOnly {
            let candidates = snapshots.values.flatMap { snapshot in
                snapshot.windows.compactMap { window -> (QuotaSnapshot, QuotaWindow, Double)? in
                    guard let remaining = window.remainingPercent else { return nil }
                    return (snapshot, window, remaining)
                }
            }
            if let lowest = candidates.min(by: { $0.2 < $1.2 }) {
                let prefix = lowest.0.provider == .codex ? "CX" : "CL"
                let marker = lowest.0.aged().freshness == .live ? "" : "~"
                return "\(prefix) \(lowest.1.type.displayName) \(marker)\(Int(lowest.2.rounded()))%"
            }
        }
        let parts = ProviderID.allCases.compactMap { id -> String? in
            guard let snapshot = snapshots[id] else { return nil }
            let prefix = id == .codex ? "CX" : "CL"
            guard let primary = snapshot.primaryWindow else { return "\(prefix) --" }
            guard let remaining = primary.remainingPercent else { return "\(prefix) --" }
            let marker = snapshot.aged().freshness == .live ? "" : "~"
            return "\(prefix) \(marker)\(Int(remaining.rounded()))%"
        }
        if parts.isEmpty {
            return "CX -- · CL --"
        }
        return parts.joined(separator: settings.menuBarMode == .compact ? " / " : " · ")
    }

    var menuBarTooltip: String {
        ProviderID.allCases.compactMap { id -> String? in
            guard let snap = snapshots[id],
                  let primary = snap.primaryWindow,
                  let rem = primary.remainingPercent else { return nil }
            let prefix = id == .codex ? "Codex" : "Claude"
            let window = primary.type == .weekly ? " (weekly)" : ""
            return "\(prefix): \(Int(rem.rounded()))% remaining\(window) · \(snap.aged().freshness.displayName) · sampled \(snap.observedAt.formatted())"
        }.joined(separator: " · ")
    }

    // MARK: - Settings

    func loadSettings() {
        if let data = userDefaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
        }
        historyStore.setRetentionDays(settings.historyRetentionDays)
        startPeriodicRefresh()
    }

    func clearHistory() throws {
        try historyStore.clearAll()
        objectWillChange.send()
    }

    // MARK: - Freeze detection (wake from sleep)

    func checkFreshnessAfterWake() {
        for id in ProviderID.allCases {
            guard let snapshot = snapshots[id] else { continue }
            let age = Date().timeIntervalSince(snapshot.observedAt)
            let threshold: TimeInterval = id == .codex ? 180 : 900
            if age > threshold {
                Task { await self.refresh(id) }
            }
        }
        Task { await refresh(.codex) }
    }
}
