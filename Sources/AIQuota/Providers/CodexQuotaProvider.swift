import Foundation

final class CodexQuotaProvider: QuotaProviderProtocol, @unchecked Sendable {
    let id = ProviderID.codex

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: codexPath)
    }

    var detectedPath: String { codexPath }
    var customPath: String? {
        get { UserDefaults.standard.string(forKey: "codexExecutablePath") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "codexExecutablePath")
            } else {
                UserDefaults.standard.removeObject(forKey: "codexExecutablePath")
            }
        }
    }

    private var codexPath: String {
        if let customPath = UserDefaults.standard.string(forKey: "codexExecutablePath") {
            return customPath
        }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin/codex"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if let bundlePath = findCodexInAppBundle() {
            return bundlePath
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        if let data = pipe.fileHandleForReading.availableData as Data?,
           let str = String(data: data, encoding: .utf8),
           !str.isEmpty {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "/opt/homebrew/bin/codex"
    }

    private func findCodexInAppBundle() -> String? {
        let versionsDir = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else {
            return nil
        }
        let fm = FileManager.default
        for version in versions.sorted().reversed() {
            let exec = "\(versionsDir)/\(version)/Helpers/Codex.app/Contents/MacOS/Codex"
            if fm.isExecutableFile(atPath: exec) {
                return exec
            }
        }
        return nil
    }

    func refresh() async throws -> QuotaSnapshot {
        let codexURL = URL(fileURLWithPath: codexPath)

        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw AppError.codexNotFound
        }

        let snapshot = try await fetchQuota(codexURL: codexURL)
        guard !snapshot.windows.isEmpty else {
            throw AppError.codexParseFailed("No usable rate limit windows returned by Codex")
        }
        return snapshot
    }

    func isInstalledAndLoggedIn() async -> Bool {
        guard isAvailable else { return false }
        do {
            let snapshot = try await fetchQuota(codexURL: URL(fileURLWithPath: codexPath))
            return !snapshot.windows.isEmpty
        } catch {
            return false
        }
    }

    private func fetchQuota(codexURL: URL) async throws -> QuotaSnapshot {
        let now = Date()

        let rawData = try await runCodexCommand(codexURL: codexURL, arguments: ["app-server", "--listen", "stdio://"])

        let windows = try parseWindows(from: rawData, now: now)
        return QuotaSnapshot(
            provider: .codex,
            windows: windows,
            observedAt: now,
            receivedAt: Date(),
            freshness: windows.isEmpty ? .unavailable : .live
        )
    }

    private func parseWindows(from data: Data, now: Date) throws -> [QuotaWindow] {
        guard let rawString = String(data: data, encoding: .utf8) else { return [] }

        var windows: [QuotaWindow] = []
        let seenPrimaryIDs = Set(["0", "1", "2"])

        for line in rawString.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Detect JSON-RPC error responses (e.g. auth failure)
            if json["error"] != nil, let id = json["id"] as? String, id == "2",
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AppError.codexApiError(message)
            }

            if let id = json["id"] as? String, !seenPrimaryIDs.contains(id),
               let result = json["result"] as? [String: Any] {
                windows.append(contentsOf: parseRateLimitEnvelope(result, now: now, limitId: id))
                continue
            }

            guard let result = json["result"] as? [String: Any] else {
                continue
            }

            if let rateLimits = result["rateLimits"] as? [String: Any] {
                windows.append(contentsOf: parseRateLimitEnvelope(rateLimits, now: now, limitId: "codex"))
                continue
            }

            if let byLimitId = result["rateLimitsByLimitId"] as? [String: [String: Any]],
               let defaultLimit = byLimitId["codex"] {
                windows.append(contentsOf: parseRateLimitEnvelope(defaultLimit, now: now, limitId: "codex"))
            }
        }

        return dedupeCodexWindows(windows)
    }

    private func parseRateLimitEnvelope(_ envelope: [String: Any], now: Date, limitId: String) -> [QuotaWindow] {
        if let limitPrimary = envelope["primary"] as? [String: Any] {
            let durationMins = limitPrimary["windowDurationMins"] as? Int ?? 0
            let usedPercent = limitPrimary["usedPercent"] as? Double
            let resetsAtTimestamp = limitPrimary["resetsAt"] as? TimeInterval
            let resetDate = resetsAtTimestamp.map { Date(timeIntervalSince1970: $0) }
            let effectiveID: String
            if durationMins == 300 {
                effectiveID = "\(limitId)-five_hour"
            } else if durationMins == 10080 {
                effectiveID = "\(limitId)-weekly"
            } else {
                effectiveID = "\(limitId)-\(durationMins)m"
            }

            return [QuotaWindow(
                id: effectiveID,
                type: WindowType.from(durationMinutes: durationMins),
                durationMinutes: durationMins,
                usedPercent: usedPercent,
                remainingPercent: nil,
                resetsAt: resetDate,
                observedAt: now
            )]
        }

        return []
    }

    private func dedupeCodexWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        var seenIDs = Set<String>()
        var output: [QuotaWindow] = []
        for window in windows where !seenIDs.contains(window.id) {
            seenIDs.insert(window.id)
            output.append(window)
        }
        return output
    }

    private func runCodexCommand(codexURL: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = codexURL
        process.arguments = arguments

        // Codex is a `#!/usr/bin/env node` script. When launched from the GUI
        // (menu bar app), PATH lacks Homebrew's dir, so `env node` fails and the
        // process exits instantly. Inject a PATH that includes common node locations.
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var pathEntries = Set(currentPath.split(separator: ":").map(String.init))
        let candidateDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.nvm/versions/node"
        ]
        for dir in candidateDirs {
            pathEntries.insert(dir)
            if let subdirs = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for sub in subdirs where sub.hasPrefix("v") {
                    pathEntries.insert("\(dir)/\(sub)/bin")
                }
            }
        }
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["PATH"] = pathEntries.joined(separator: ":")

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = Pipe()

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            let state = CodexCommandState(continuation: continuation)
            let outputHandle = stdoutPipe.fileHandleForReading
            let inputHandle = stdinPipe.fileHandleForWriting

            outputHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }

                if state.append(chunk) {
                    handle.readabilityHandler = nil
                    inputHandle.closeFile()
                    if process.isRunning {
                        process.terminate()
                    }
                    state.succeed()
                }
            }

            Task.detached {
                let messages = [
                    #"{"type":"request","id":"0","method":"initialize","params":{"clientInfo":{"name":"ai-quota","version":"1.0.0"},"capabilities":{}}}"#,
                    #"{"type":"request","id":"1","method":"account/read","params":{"refreshToken":false}}"#,
                    #"{"type":"request","id":"2","method":"account/rateLimits/read","params":{}}"#
                ]

                for message in messages {
                    guard !state.isFinished else { return }
                    let bytes = Array((message + "\n").utf8)
                    bytes.withUnsafeBufferPointer { buffer in
                        _ = Darwin.write(inputHandle.fileDescriptor, buffer.baseAddress, buffer.count)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }

                // Give Codex time to flush the final response before sending EOF.
                try? await Task.sleep(for: .seconds(2))
                inputHandle.closeFile()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard state.failIfPending(AppError.codexTimeout) else { return }
                outputHandle.readabilityHandler = nil
                inputHandle.closeFile()
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

private final class CodexCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var resolved = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    var isFinished: Bool {
        lock.withLock { resolved }
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !resolved else { return false }
            data.append(chunk)
            return containsRateLimitResponse
        }
    }

    func succeed() {
        let result: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            guard !resolved, let continuation else { return nil }
            resolved = true
            self.continuation = nil
            return (continuation, data)
        }
        guard let result else { return }
        result.0.resume(returning: result.1)
    }

    @discardableResult
    func failIfPending(_ error: Error) -> Bool {
        let pending: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !resolved, let continuation else { return nil }
            resolved = true
            self.continuation = nil
            return continuation
        }
        pending?.resume(throwing: error)
        return pending != nil
    }

    private var containsRateLimitResponse: Bool {
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.split(separator: "\n").contains { line in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["id"] as? String == "2" else {
                return false
            }
            return object["result"] != nil || object["error"] != nil
        }
    }
}
