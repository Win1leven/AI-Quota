import Foundation

final class HistoryStore: @unchecked Sendable {
    private var snapshots: [TrendPoint] = []
    private var retentionDays = 30
    private var clearedAt: Date?
    private let queue = DispatchQueue(label: "com.aiquota.history", qos: .utility)
    private var lastHeartbeat: [String: Date] = [:]
    private let storageURL: URL?
    private let desktopHistoryURL: URL?

    init(storageURL: URL? = nil, desktopHistoryURL: URL? = nil) {
        self.storageURL = storageURL
        self.desktopHistoryURL = desktopHistoryURL
    }

    private var storeURL: URL {
        if let storageURL { return storageURL }
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("AIQuota", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("trend_history.json")
    }

    func record(snapshot: QuotaSnapshot) {
        queue.sync {
            let now = Date()

            for window in snapshot.windows {
                guard let usedPercent = window.usedPercent else { continue }
                if let clearedAt, window.observedAt <= clearedAt { continue }

                let key = "\(snapshot.provider.rawValue)-\(window.type.rawValue)"
                let lastBeat = self.lastHeartbeat[key]

                let shouldRecord: Bool
                if let lastBeat {
                    let timeSinceLastBeat = now.timeIntervalSince(lastBeat)
                    let valueUnchanged = self.snapshots.last(where: { $0.provider == snapshot.provider && $0.windowType == window.type.rawValue })?.usedPercent == usedPercent
                    shouldRecord = timeSinceLastBeat >= 300 || !valueUnchanged
                } else {
                    shouldRecord = true
                }

                if shouldRecord {
                    let point = TrendPoint(
                        timestamp: window.observedAt,
                        usedPercent: usedPercent,
                        provider: snapshot.provider,
                        windowType: window.type.rawValue,
                        isAfterReset: false
                    )
                    guard !self.snapshots.contains(where: { $0.id == point.id }) else { continue }
                    self.snapshots.append(point)
                    self.lastHeartbeat[key] = now
                }
            }

            self.trim()
            self.persist()
        }
    }

    func importClaudeDesktopHistory() {
        let path = desktopHistoryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]] else {
            return
        }

        queue.sync {
            var knownIDs = Set(snapshots.map(\.id))
            var imported = false
            for sample in samples {
                guard let milliseconds = (sample["t"] as? NSNumber)?.doubleValue,
                      let usage = sample["u"] as? [String: Any] else { continue }
                let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
                guard milliseconds.isFinite, milliseconds > 0,
                      timestamp <= Date().addingTimeInterval(60) else { continue }
                if let clearedAt, timestamp <= clearedAt { continue }

                for (key, type) in [("fh", WindowType.fiveHour), ("sd", WindowType.weekly)] {
                    guard let used = (usage[key] as? NSNumber)?.doubleValue,
                          used.isFinite, (0...100).contains(used) else { continue }
                    let point = TrendPoint(
                        timestamp: timestamp,
                        usedPercent: used,
                        provider: .claude,
                        windowType: type.rawValue
                    )
                    guard knownIDs.insert(point.id).inserted else { continue }
                    snapshots.append(point)
                    imported = true
                }
            }

            if imported {
                trim()
                persist()
            }
        }
    }

    func query(provider: ProviderID, windowType: String, range: TrendRange) -> [TrendPoint] {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-range.duration)
            return snapshots.filter { point in
                point.provider == provider &&
                point.windowType == windowType &&
                point.timestamp >= cutoff
            }
            .sorted { $0.timestamp < $1.timestamp }
        }
    }

    func clearAll() throws {
        try queue.sync {
            let cutoff = Date()
            try JSONEncoder().encode(cutoff).write(to: storeURL.appendingPathExtension("clearedAt"), options: .atomic)
            try JSONEncoder().encode([TrendPoint]()).write(to: storeURL, options: .atomic)
            self.clearedAt = cutoff
            self.snapshots.removeAll()
            self.lastHeartbeat.removeAll()
        }
    }

    func setRetentionDays(_ days: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.retentionDays = max(1, days)
            let cutoff = Date().addingTimeInterval(-Double(self.retentionDays) * 86_400)
            self.snapshots.removeAll { $0.timestamp < cutoff }
            self.persist()
        }
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        snapshots.removeAll { $0.timestamp < cutoff }

        let maxPoints = 10_000
        if snapshots.count > maxPoints {
            snapshots.sort { $0.timestamp < $1.timestamp }
            snapshots = Array(snapshots.suffix(maxPoints))
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func load() {
        queue.sync {
            if let data = try? Data(contentsOf: storeURL.appendingPathExtension("clearedAt")) {
                clearedAt = try? JSONDecoder().decode(Date.self, from: data)
            }
            guard let data = try? Data(contentsOf: storeURL),
                  let decoded = try? JSONDecoder().decode([TrendPoint].self, from: data) else {
                return
            }
            var knownIDs = Set<String>()
            snapshots = decoded.filter {
                ($0.timestamp > (clearedAt ?? .distantPast)) && knownIDs.insert($0.id).inserted
            }
            if snapshots.count != decoded.count {
                persist()
            }
        }
    }
}
