import Foundation

struct Diagnostics {
    @MainActor static func summary(store: QuotaStore) -> String {
        var lines: [String] = []
        lines.append("=== Quota Monitor Diagnostic Summary ===")
        lines.append("Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        for id in ProviderID.allCases {
            lines.append("--- \(id.displayName) ---")
            if let snapshot = store.snapshots[id] {
                lines.append("  Status: \(snapshot.freshness.displayName)")
                lines.append("  Observed: \(snapshot.observedAt.formatted())")
                lines.append("  Received: \(snapshot.receivedAt.formatted())")
                for window in snapshot.windows {
                    let rem = window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "N/A"
                    let used = window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "N/A"
                    let reset = window.resetsAt?.formatted() ?? "N/A"
                    lines.append("  [\(window.type.displayName)] Remaining: \(rem), Used: \(used), Resets: \(reset)")
                }
            } else {
                lines.append("  No data")
            }
            if let error = store.errors[id] {
                lines.append("  Error: \(error)")
            }
            lines.append("")
        }

        lines.append("--- Settings ---")
        lines.append("Menu bar mode: \(store.settings.menuBarMode.rawValue)")
        lines.append("Refresh interval: \(Int(store.settings.codexRefreshInterval))s")
        lines.append("Panel fixed: \(store.isFloatingPanelFixed)")
        lines.append("================================")

        return lines.joined(separator: "\n")
    }

    static func privacyCheck() -> [String] {
        var violations: [String] = []

        let home = FileManager.default.homeDirectoryForCurrentUser

        let sensitivePaths = [
            home.appendingPathComponent(".config/codex/auth.json"),
            home.appendingPathComponent(".claude/credentials.json"),
            home.appendingPathComponent(".claude/settings.json")
        ]

        let appSupportPaths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let appSupport = appSupportPaths.first {
            let appDir = appSupport.appendingPathComponent("AIQuota")
            if let files = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) {
                for file in files {
                    let content = (try? String(contentsOf: file)) ?? ""
                    for path in sensitivePaths {
                        if content.contains(path.path) {
                            violations.append("File \(file.lastPathComponent) references \(path.lastPathComponent)")
                        }
                    }
                }
            }
        }
        return violations
    }
}
