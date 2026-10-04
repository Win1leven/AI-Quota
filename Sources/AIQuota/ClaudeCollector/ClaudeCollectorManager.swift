import Foundation

final class ClaudeCollectorManager {
    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let supportDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIQuota")) {
        self.homeDirectory = homeDirectory
        self.supportDirectory = supportDirectory
    }

    private var settingsURL: URL { homeDirectory.appendingPathComponent(".claude/settings.json") }
    private var stateURL: URL { supportDirectory.appendingPathComponent("claude_collector_install.json") }
    private var scriptURL: URL { supportDirectory.appendingPathComponent("claude_status_collector_v2.sh") }
    private var snapshotURL: URL { supportDirectory.appendingPathComponent("claude_quota_snapshot.json") }
    var configExists: Bool { fileManager.fileExists(atPath: settingsURL.path) }
    var hasBackup: Bool { fileManager.fileExists(atPath: stateURL.path) }
    var canMigrateLegacyCollector: Bool {
        guard let config = try? loadConfig(), config["statusLineCommand"] == nil,
              let status = config["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return isKnownLegacyCommand(command)
    }

    private func isKnownLegacyCommand(_ command: String) -> Bool {
        let oldScript = supportDirectory.appendingPathComponent("claude_status_collector.sh").path
        return [oldScript, shellQuote(oldScript),
            oldScript + " --snapshot " + snapshotURL.path,
            shellQuote(oldScript) + " --snapshot " + shellQuote(snapshotURL.path)].contains(command)
    }

    func isCollectorInstalled() -> Bool {
        guard let config = try? loadConfig(),
              let statusLine = config["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command == shellQuote(scriptURL.path) && fileManager.isExecutableFile(atPath: scriptURL.path)
    }

    @discardableResult
    func installCollector(replaceLegacyCollector: Bool = false) throws -> InstallResult {
        var config = try loadConfig()
        if isCollectorInstalled(), hasBackup { return .alreadyInstalled }
        // A legacy installation has no reliable saved original command. Do not wrap it recursively.
        let existing = config["statusLine"]
        let existingCommand = (existing as? [String: Any])?["command"] as? String
        let replacesKnownLegacy = replaceLegacyCollector && existingCommand.map(isKnownLegacyCommand) == true
        if config["statusLineCommand"] != nil || (existingCommand?.contains("claude_status_collector") == true && !replacesKnownLegacy) {
            throw CollectorError.legacyConfiguration
        }
        if let existing {
            guard let object = existing as? [String: Any], object["type"] as? String == "command",
                  object["command"] is String else { throw CollectorError.invalidConfiguration }
        }
        var installed = existing as? [String: Any] ?? [:]
        installed["type"] = "command"
        installed["command"] = shellQuote(scriptURL.path)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try writeScript(originalCommand: replacesKnownLegacy ? nil : existingCommand)
        let state: [String: Any] = ["originalStatusLine": existing ?? NSNull(), "installedStatusLine": installed]
        try writeJSON(state, to: stateURL)
        config["statusLine"] = installed
        try writeJSON(config, to: settingsURL)
        return .installed
    }

    func restoreConfig() throws -> RestoreResult {
        guard hasBackup else { return .noBackupFound }
        let state = try readJSON(stateURL)
        var config = try loadConfig()
        guard let installed = state["installedStatusLine"] as? NSDictionary,
              let current = config["statusLine"] as? NSDictionary,
              current.isEqual(installed) else { throw CollectorError.configurationChanged }
        if let original = state["originalStatusLine"], !(original is NSNull) {
            config["statusLine"] = original
        } else {
            config.removeValue(forKey: "statusLine")
        }
        // Restore only the owned field, preserving subsequent user edits elsewhere.
        try writeJSON(config, to: settingsURL)
        try fileManager.removeItem(at: stateURL)
        return .restored("original statusLine")
    }

    private func loadConfig() throws -> [String: Any] {
        guard configExists else { return [:] }
        return try readJSON(settingsURL)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CollectorError.invalidConfiguration
        }
        return object
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".aiquota-\(UUID()).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CollectorError.writeFailed
        }
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func writeScript(originalCommand: String?) throws {
        // Persist only quota fields and an opaque activity fingerprint, never the full status-line input.
        let python = #"""
import fcntl, hashlib, json, math, os, sys, tempfile, time
path = sys.argv[1]
try:
    value = json.load(sys.stdin)
    limits = value.get("rate_limits") or {}
    clean = {}
    for key in ("five_hour", "seven_day"):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        used = window.get("used_percentage")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
            continue
        item = {"used_percentage": used}
        reset = window.get("resets_at")
        if not isinstance(reset, bool) and isinstance(reset, (int, float)) and math.isfinite(reset) and reset > 0:
            item["resets_at"] = reset
        clean[key] = item
    if not clean:
        sys.exit(0)
    identity = [value.get("session_id"), (value.get("cost") or {}).get("total_api_duration_ms"), clean]
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    # Keep independent session fingerprints, so idle A/B redraws cannot renew old data.
    lock = os.open(path + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(0)
    previous = {}
    try:
        with open(path) as f:
            previous = json.load(f)
    except (OSError, ValueError):
        pass
    if not isinstance(previous, dict):
        previous = {}
    fingerprints = previous.get("activity_fingerprints") or {}
    if not isinstance(fingerprints, dict):
        fingerprints = {}
    session = hashlib.sha256(str(value.get("session_id") or "unknown").encode()).hexdigest()
    if fingerprints.get(session) == fingerprint:
        sys.exit(0)
    fingerprints[session] = fingerprint
    fingerprints = dict(list(fingerprints.items())[-64:])
    sample = {"sampled_at": time.time(), "rate_limits": clean, "activity_fingerprints": fingerprints}
    fd, temporary = tempfile.mkstemp(prefix=".quota-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(sample, f, allow_nan=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
except (ValueError, TypeError, AttributeError, OSError):
    sys.exit(1)
"""#
        var script = "#!/bin/sh\n# AIQuota passive collector v2\nINPUT=$(cat)\n"
        script += "printf '%s' \"$INPUT\" | /usr/bin/env python3 -c \(shellQuote(python)) \(shellQuote(snapshotURL.path)) >/dev/null 2>&1 || true\n"
        if let originalCommand {
            script += "printf '%s' \"$INPUT\" | /bin/sh -c \(shellQuote(originalCommand))\n"
        }
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    enum InstallResult { case installed, alreadyInstalled }
    enum RestoreResult { case restored(String), noBackupFound }

    enum CollectorError: LocalizedError {
        case invalidConfiguration, legacyConfiguration, configurationChanged, writeFailed
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "Claude settings are invalid. No configuration was replaced."
            case .legacyConfiguration: return "A legacy collector is configured. Review its original status line before migration; it has not been overwritten."
            case .configurationChanged: return "The status line changed after installation. Restore was cancelled to preserve your edits."
            case .writeFailed: return "Could not safely write the collector configuration."
            }
        }
    }
}
