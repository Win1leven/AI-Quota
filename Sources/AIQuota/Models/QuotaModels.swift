import Foundation

enum ProviderID: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case claude = "claude"

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

enum WindowType: String, Codable, Sendable {
    case fiveHour = "five_hour"
    case weekly = "weekly"
    case unknown = "unknown"

    static func from(durationMinutes: Int) -> WindowType {
        switch durationMinutes {
        case 300: return .fiveHour
        case 10080: return .weekly
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .weekly: return "Weekly"
        case .unknown: return "Window"
        }
    }
}

struct QuotaWindow: Identifiable, Codable, Sendable {
    let id: String
    let type: WindowType
    let durationMinutes: Int
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetsAt: Date?
    let observedAt: Date

    init(
        id: String? = nil,
        type: WindowType,
        durationMinutes: Int,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetsAt: Date?,
        observedAt: Date = Date()
    ) {
        if let calculatedRemaining = usedPercent.map({ 100 - $0 }) {
            let clamped = max(0, min(100, calculatedRemaining))
            self.remainingPercent = remainingPercent.map { max(0, min(100, $0)) } ?? clamped
        } else {
            self.remainingPercent = remainingPercent.map { max(0, min(100, $0)) }
        }
        self.id = id ?? "\(type.rawValue)-\(observedAt.timeIntervalSince1970)"
        self.type = type
        self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent.map { max(0, min(100, $0)) }
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

enum DataFreshness: String, Codable, Sendable {
    case live
    case cached
    case stale
    case unavailable
    case notConfigured
    case unknown

    var displayName: String {
        switch self {
        case .live: return "Live"
        case .cached: return "Cached"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        case .notConfigured: return "Not Configured"
        case .unknown: return "Unknown"
        }
    }
}

enum QuotaSource: String, Codable, Sendable {
    case claudeCollector
    case claudeDesktop
    case codexCLI

    var displayName: String {
        switch self {
        case .claudeCollector: return "Claude Code sample"
        case .claudeDesktop: return "Desktop history · reset unknown"
        case .codexCLI: return "Codex CLI"
        }
    }
}

struct QuotaSnapshot: Identifiable, Codable, Sendable {
    let id: String
    let provider: ProviderID
    let windows: [QuotaWindow]
    let observedAt: Date
    let receivedAt: Date
    let freshness: DataFreshness
    let source: QuotaSource?

    init(
        provider: ProviderID,
        windows: [QuotaWindow],
        observedAt: Date = Date(),
        receivedAt: Date = Date(),
        freshness: DataFreshness = .live,
        source: QuotaSource? = nil
    ) {
        self.id = "\(provider.rawValue)-\(receivedAt.timeIntervalSince1970)"
        self.provider = provider
        self.windows = windows
        self.observedAt = observedAt
        self.receivedAt = receivedAt
        self.freshness = freshness
        self.source = source
    }

    func aged(at now: Date = Date()) -> QuotaSnapshot {
        let age = now.timeIntervalSince(observedAt)
        let state: DataFreshness
        if windows.isEmpty {
            state = freshness
        } else if age < -60 {
            state = .unknown
        } else if freshness == .stale || age > (provider == .claude ? 1800 : 600) {
            state = .stale
        } else if source == .claudeDesktop || freshness == .cached || age > (provider == .claude ? 120 : 180) {
            state = .cached
        } else {
            state = freshness
        }
        return QuotaSnapshot(provider: provider, windows: windows, observedAt: observedAt,
                             receivedAt: receivedAt, freshness: state, source: source)
    }

    var primaryWindow: QuotaWindow? {
        windows.first(where: { $0.type == .fiveHour }) ?? windows.first
    }
}

struct TrendPoint: Identifiable, Codable, Sendable {
    let id: String
    let timestamp: Date
    let usedPercent: Double
    let provider: ProviderID
    let windowType: String
    let isAfterReset: Bool

    init(timestamp: Date, usedPercent: Double, provider: ProviderID, windowType: String, isAfterReset: Bool = false) {
        self.id = "\(provider.rawValue)-\(windowType)-\(timestamp.timeIntervalSince1970)"
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.provider = provider
        self.windowType = windowType
        self.isAfterReset = isAfterReset
    }
}

enum TrendRange: String, CaseIterable, Codable, Sendable {
    case fiveHours = "5h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"

    var duration: TimeInterval {
        switch self {
        case .fiveHours: return 5 * 3600
        case .twentyFourHours: return 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        }
    }
}

enum MenuBarMode: String, CaseIterable, Codable, Sendable {
    case standard = "Standard"
    case compact = "Compact"
    case lowestOnly = "Lowest Only"
}

struct AppSettings: Codable {
    var menuBarMode: MenuBarMode = .standard
    var launchAtStartup: Bool = false
    var codexRefreshInterval: TimeInterval = 60
    var defaultTrendRange: TrendRange = .fiveHours
    var showOnAllSpaces: Bool = false
    var alwaysOnTop: Bool = false
    var historyRetentionDays: Int = 30
    var floatingPanelCompact: Bool = false

    static let `default` = AppSettings()
}

struct DailyUsage: Codable, Sendable, Identifiable {
    var id: String { date }
    let date: String
    let credits: Double
    let cachedInputTokens: Int
    let uncachedInputTokens: Int
    let outputTokens: Int
    let turns: Int
    /// Cache-creation (write) tokens, subset of uncachedInputTokens. Priced higher than fresh input.
    let cacheWriteTokens: Int

    init(date: String, credits: Double, cachedInputTokens: Int, uncachedInputTokens: Int, outputTokens: Int, turns: Int, cacheWriteTokens: Int = 0) {
        self.date = date
        self.credits = credits
        self.cachedInputTokens = cachedInputTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.turns = turns
        self.cacheWriteTokens = cacheWriteTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        credits = try c.decodeIfPresent(Double.self, forKey: .credits) ?? 0
        cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        uncachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .uncachedInputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
    }

    var totalTokens: Int { cachedInputTokens + uncachedInputTokens + outputTokens }
    var inputTokens: Int { cachedInputTokens + uncachedInputTokens }
    /// Fresh (non-cached, non-cache-write) input tokens.
    var freshInputTokens: Int { max(0, uncachedInputTokens - cacheWriteTokens) }
}

struct UsageAnalytics: Codable, Sendable, Identifiable {
    let id: String
    let provider: ProviderID
    let capturedAt: Date
    let cycleStartDate: String?
    let creditsUsed: Double
    let tokensUsed: Int
    let inputTokens: Int
    let outputTokens: Int
    let daily: [DailyUsage]
    let projectedWeeklyCredits: Double?
    let projectedWeeklyTokens: Int?
    let projectedWeeklyUSD: Double?
    let primaryUsedPercent: Double?

    init(
        provider: ProviderID,
        capturedAt: Date = Date(),
        cycleStartDate: String? = nil,
        creditsUsed: Double,
        tokensUsed: Int,
        inputTokens: Int,
        outputTokens: Int,
        daily: [DailyUsage] = [],
        projectedWeeklyCredits: Double? = nil,
        projectedWeeklyTokens: Int? = nil,
        projectedWeeklyUSD: Double? = nil,
        primaryUsedPercent: Double? = nil
    ) {
        self.id = "\(provider.rawValue)-\(capturedAt.timeIntervalSince1970)"
        self.provider = provider
        self.capturedAt = capturedAt
        self.cycleStartDate = cycleStartDate
        self.creditsUsed = creditsUsed
        self.tokensUsed = tokensUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.daily = daily
        self.projectedWeeklyCredits = projectedWeeklyCredits
        self.projectedWeeklyTokens = projectedWeeklyTokens
        self.projectedWeeklyUSD = projectedWeeklyUSD
        self.primaryUsedPercent = primaryUsedPercent
    }
}

enum AppError: LocalizedError {
    case olderQuotaSample
    case codexNotFound
    case codexNotLoggedIn
    case codexVersionTooOld
    case codexTimeout
    case codexParseFailed(String)
    case codexApiError(String)
    case claudeNotConfigured
    case claudeNoSnapshot
    case claudeConfigConflict(String)
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .olderQuotaSample:
            return "Only an older sample is available. Keeping the last known quota; check the collector in Settings."
        case .codexNotFound:
            return "Codex not found. Install or set the executable path."
        case .codexNotLoggedIn:
            return "Codex not logged in. Please log in from Codex first."
        case .codexVersionTooOld:
            return "Codex version is too old. Please upgrade."
        case .codexTimeout:
            return "Codex request timed out."
        case .codexParseFailed(let detail):
            return "Failed to parse Codex response: \(detail)"
        case .codexApiError(let msg):
            if msg.contains("rateLimits") || msg.contains("wham") || msg.contains("usage") {
                return "Codex quota API unavailable. Run: codex login"
            }
            if msg.contains("auth") || msg.contains("token") || msg.contains("unauthorized") {
                return "Codex auth error. Run: codex login"
            }
            return "Codex error: \(msg)"
        case .claudeNotConfigured:
            return "Claude collector not configured."
        case .claudeNoSnapshot:
            return "No snapshot yet. Complete one Claude Code response."
        case .claudeConfigConflict(let path):
            return "Claude config conflict. Backup at: \(path)"
        case .providerUnavailable(let name):
            return "Provider \(name) is unavailable."
        }
    }
}
