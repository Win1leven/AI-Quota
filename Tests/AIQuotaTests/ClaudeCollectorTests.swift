import Foundation
import Testing
@testable import AIQuota

struct ClaudeCollectorTests {
    @Test func explicitLegacyMigrationIsReversible() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        let oldCommand = files.support.appendingPathComponent("claude_status_collector.sh").path + " --snapshot " + files.snapshotURL.path
        try files.writeConfig(["statusLine": ["type": "command", "command": oldCommand], "unrelated": true])
        try files.manager.installCollector(replaceLegacyCollector: true)
        #expect(files.manager.isCollectorInstalled())
        let command = try #require((try files.config()["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(try files.run(command, input: #"{"rate_limits":{"five_hour":{"used_percentage":25}}}"#) == "")
        _ = try files.manager.restoreConfig()
        #expect((try files.config()["statusLine"] as? [String: Any])?["command"] as? String == oldCommand)
    }

    @Test func migrationCannotReplaceCustomLegacyWrapper() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        let custom = files.support.appendingPathComponent("claude_status_collector.sh").path + " && printf custom-status"
        try files.writeConfig(["statusLine": ["type": "command", "command": custom]])
        #expect(throws: (any Error).self) { try files.manager.installCollector(replaceLegacyCollector: true) }
        #expect((try files.config()["statusLine"] as? [String: Any])?["command"] as? String == custom)
    }

    @Test func alternatingIdleSessionsDoNotResampleOldQuota() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.manager.installCollector()
        let command = try #require((try files.config()["statusLine"] as? [String: Any])?["command"] as? String)
        let sessionA = #"{"session_id":"A","cost":{"total_api_duration_ms":10},"rate_limits":{"five_hour":{"used_percentage":25}}}"#
        let sessionB = #"{"session_id":"B","cost":{"total_api_duration_ms":20},"rate_limits":{"five_hour":{"used_percentage":30}}}"#
        _ = try files.run(command, input: sessionA)
        _ = try files.run(command, input: sessionB)
        let newer = try Data(contentsOf: files.snapshotURL)
        _ = try files.run(command, input: sessionA)
        #expect(try Data(contentsOf: files.snapshotURL) == newer)
        #expect((try files.snapshot()["rate_limits"] as? [String: Any])?["five_hour"] as? NSDictionary == ["used_percentage": 30] as NSDictionary)
    }

    @Test func restoreRefusesChangedStatusLine() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.manager.installCollector()
        var config = try files.config()
        config["statusLine"] = ["type": "command", "command": "printf user-change"]
        try files.writeConfig(config)
        #expect(throws: (any Error).self) { try files.manager.restoreConfig() }
        #expect((try files.config()["statusLine"] as? [String: Any])?["command"] as? String == "printf user-change")
    }

    @Test func legacyCollectorRequiresExplicitMigration() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        let config = ["statusLine": ["type": "command", "command": "'/old path/claude_status_collector.sh'"]]
        try files.writeConfig(config)
        #expect(throws: (any Error).self) { try files.manager.installCollector() }
        #expect(try files.config() as NSDictionary == config as NSDictionary)
    }

    @Test func newResponseUpdatesQuotaButInvalidWindowCannotReplaceIt() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.manager.installCollector()
        let command = try #require((try files.config()["statusLine"] as? [String: Any])?["command"] as? String)
        _ = try files.run(command, input: #"{"cost":{"total_api_duration_ms":10},"rate_limits":{"five_hour":{"used_percentage":25}}}"#)
        let first = try Data(contentsOf: files.snapshotURL)
        _ = try files.run(command, input: #"{"cost":{"total_api_duration_ms":20},"rate_limits":{"five_hour":{"used_percentage":25}}}"#)
        let second = try Data(contentsOf: files.snapshotURL)
        #expect(first != second)
        _ = try files.run(command, input: #"{"rate_limits":{"five_hour":{"used_percentage":1700000000}}}"#)
        #expect(try Data(contentsOf: files.snapshotURL) == second)
        let permissions = try FileManager.default.attributesOfItem(atPath: files.snapshotURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func installationPreservesStatusLineAndCollectsInSpacePaths() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.writeConfig(["statusLine": ["type": "command", "command": "cat", "padding": 2], "unrelated": true])
        try files.manager.installCollector()
        let config = try files.config()
        let status = try #require(config["statusLine"] as? [String: Any])
        #expect(status["padding"] as? Int == 2)
        #expect(config["unrelated"] as? Bool == true)
        #expect(files.manager.isCollectorInstalled())
        let command = try #require(status["command"] as? String)
        #expect(command != "cat")
        let input = #"{"session_id":"synthetic","cost":{"total_api_duration_ms":10},"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1900000000},"seven_day":{"used_percentage":60,"resets_at":1900500000}}}"#
        let output = try files.run(command, input: input)
        #expect(output == input)
        let snapshot = try files.snapshot()
        let limits = try #require(snapshot["rate_limits"] as? [String: Any])
        #expect((limits["five_hour"] as? [String: Any])?["used_percentage"] as? Int == 25)
        let sampleBytes = try Data(contentsOf: files.snapshotURL)
        _ = try files.run(command, input: input)
        #expect(try Data(contentsOf: files.snapshotURL) == sampleBytes)
        _ = try files.run(command, input: "{invalid json")
        #expect(try Data(contentsOf: files.snapshotURL) == sampleBytes)
        _ = try files.run(command, input: #"{"rate_limits":{}}"#)
        #expect(try Data(contentsOf: files.snapshotURL) == sampleBytes)
        try files.manager.installCollector()
        #expect(try files.config()["statusLine"] as? NSDictionary == status as NSDictionary)
    }

    @Test func restorePreservesUnrelatedChangesAndRemovesOnlyCollector() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.writeConfig(["statusLine": ["type": "command", "command": "cat", "padding": 2], "unrelated": true])
        try files.manager.installCollector()
        var config = try files.config()
        config["unrelated"] = false
        try files.writeConfig(config)
        _ = try files.manager.restoreConfig()
        let restored = try files.config()
        #expect(restored["unrelated"] as? Bool == false)
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat")
        #expect(!files.manager.isCollectorInstalled())
    }

    @Test func firstInstallAndRestoreWithoutExistingSettings() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try files.manager.installCollector()
        #expect(files.manager.isCollectorInstalled())
        let command = try #require((try files.config()["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(try files.run(command, input: #"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#) == "")
        #expect(try files.snapshot()["rate_limits"] != nil)
        _ = try files.manager.restoreConfig()
        #expect(try files.config()["statusLine"] == nil)
    }

    @Test func malformedConfigIsNeverOverwritten() throws {
        let files = try CollectorFiles()
        defer { files.remove() }
        try FileManager.default.createDirectory(at: files.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("invalid config".utf8)
        try invalid.write(to: files.settingsURL)
        #expect(throws: (any Error).self) { try files.manager.installCollector() }
        #expect(try Data(contentsOf: files.settingsURL) == invalid)
    }
}

struct CollectorFiles {
    let root: URL
    let support: URL
    var settingsURL: URL { root.appendingPathComponent(".claude/settings.json") }
    var snapshotURL: URL { support.appendingPathComponent("claude_quota_snapshot.json") }
    var manager: ClaudeCollectorManager { ClaudeCollectorManager(homeDirectory: root, supportDirectory: support) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuota collector 'test' \(UUID())")
        support = root.appendingPathComponent("Application Support/AIQuota")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    func writeConfig(_ config: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: settingsURL, options: .atomic)
    }
    func config() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any] }
    func snapshot() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any] }
    func run(_ command: String, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
