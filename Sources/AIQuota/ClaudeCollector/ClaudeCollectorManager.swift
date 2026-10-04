import Foundation

final class ClaudeCollectorManager {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var settingsURL: URL {
        homeDir.appendingPathComponent(".claude/settings.json")
    }

    private var backupDir: URL {
        appSupportDir.appendingPathComponent("ClaudeSettingsBackups", isDirectory: true)
    }

    private var appSupportDir: URL {
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("AIQuota", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var collectorScriptURL: URL {
        appSupportDir.appendingPathComponent("claude_status_collector.sh")
    }

    private var homeDir: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    var configExists: Bool {
        fileManager.fileExists(atPath: settingsURL.path)
    }

    var hasBackup: Bool {
        fileManager.fileExists(atPath: backupDir.path) &&
        (try? fileManager.contentsOfDirectory(atPath: backupDir.path).contains { $0.hasSuffix(".json") }) == true
    }

    func isCollectorInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        if let statusLine = json["statusLine"] as? String {
            return statusLine.contains("claude_status_collector")
        }

        if let statusLineCommand = json["statusLineCommand"] as? String {
            return statusLineCommand.contains("claude_status_collector")
        }

        return false
    }

    func installCollector() throws -> InstallResult {
        if isCollectorInstalled() {
            return .alreadyInstalled
        }

        try backupExistingConfig()

        try writeCollectorScript()

        var config = try loadOrCreateConfig()

        let collectorCmd = "\(collectorScriptURL.path) --snapshot \(collectorSnapshotPath.path)"

        if let existingStatusLine = config["statusLineCommand"] as? String {
            config["statusLineCommand"] = "\(collectorCmd) && \(existingStatusLine)"
        } else if let existingStatusLine = config["statusLine"] as? String {
            config["statusLineCommand"] = "\(collectorCmd) && \(existingStatusLine)"
            config.removeValue(forKey: "statusLine")
        } else {
            config["statusLineCommand"] = collectorCmd
        }

        try atomicWriteConfig(config)

        return .installed
    }

    func restoreConfig() throws -> RestoreResult {
        guard hasBackup else {
            return .noBackupFound
        }

        let backupFiles = try fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard let latestBackup = backupFiles.first else {
            return .noBackupFound
        }

        try fileManager.removeItem(at: settingsURL)
        try fileManager.copyItem(at: latestBackup, to: settingsURL)

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)

        return .restored(latestBackup.lastPathComponent)
    }

    private func backupExistingConfig() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }

        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let backupURL = backupDir.appendingPathComponent("settings_\(timestamp).json")

        try fileManager.copyItem(at: settingsURL, to: backupURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private func writeCollectorScript() throws {
        let snapshotPath = collectorSnapshotPath.path
        let lines: [String] = [
            "#!/bin/bash",
            "# AIQuota Claude Status Collector",
            "# Installed by Quota Monitor - do not modify manually",
            "set -euo pipefail",
            "",
            "SNAPSHOT_FILE=\"\(snapshotPath)\"",
            "",
            "while [[ $# -gt 0 ]]; do",
            "  case \"$1\" in",
            "    --snapshot) SNAPSHOT_FILE=\"$2\"; shift 2 ;;",
            "    *) shift ;;",
            "  esac",
            "done",
            "",
            "INPUT=$(cat /dev/stdin)",
            "",
            "SAMPLED_AT=$(date +%s)",
            "",
            "RATE_LIMITS=$(echo \"$INPUT\" | python3 -c 'import sys, json; data=json.load(sys.stdin); rl=data.get(\"rate_limits\", data.get(\"rateLimit\", data.get(\"rate_limit\", {})))); print(json.dumps(rl) if isinstance(rl, dict) else json.dumps({}))' 2>/dev/null || echo '{}')",
            "",
            "VERSION=$(echo \"$INPUT\" | python3 -c 'import sys, json; data=json.load(sys.stdin); print(data.get(\"version\", \"unknown\"))' 2>/dev/null || echo 'unknown')",
            "",
            "echo \"{\\\"sampled_at\\\": $SAMPLED_AT, \\\"version\\\": \\\"$VERSION\\\", \\\"rate_limits\\\": $RATE_LIMITS}\" > \"$SNAPSHOT_FILE\"",
            "chmod 600 \"$SNAPSHOT_FILE\"",
            "",
            "echo \"$INPUT\""
        ]
        let script = lines.joined(separator: "\n")

        try fileManager.createDirectory(at: collectorScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.data(using: .utf8)?.write(to: collectorScriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: collectorScriptURL.path)
    }

    private var collectorSnapshotPath: URL {
        appSupportDir.appendingPathComponent("claude_quota_snapshot.json")
    }

    private func loadOrCreateConfig() throws -> [String: Any] {
        if fileManager.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return [:]
    }

    private func atomicWriteConfig(_ config: [String: Any]) throws {
        let tempURL = settingsURL.appendingPathExtension(".tmp")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        _ = try fileManager.replaceItemAt(settingsURL, withItemAt: tempURL)
    }

    enum InstallResult {
        case installed
        case alreadyInstalled
    }

    enum RestoreResult {
        case restored(String)
        case noBackupFound
    }
}
