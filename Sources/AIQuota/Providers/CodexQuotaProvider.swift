import Foundation

final class CodexQuotaProvider: QuotaProviderProtocol, @unchecked Sendable {
    let id = ProviderID.codex
    private let executableOverride: URL?

    init(executableURL: URL? = nil) { executableOverride = executableURL }

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
        if let executableOverride { return executableOverride.path }
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
        let rawData = try await runCodexCommand(codexURL: codexURL, arguments: ["app-server", "--listen", "stdio://"])
        let now = Date()
        let windows = try parseWindows(from: rawData, now: now)
        return QuotaSnapshot(
            provider: .codex,
            windows: windows,
            observedAt: now,
            receivedAt: Date(),
            freshness: windows.isEmpty ? .unavailable : .live,
            source: .codexCLI
        )
    }

    func parseWindows(from data: Data, now: Date) throws -> [QuotaWindow] {
        guard let rawString = String(data: data, encoding: .utf8) else { return [] }

        var windows: [QuotaWindow] = []
        for line in rawString.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let responseID = (json["id"] as? String) ?? (json["id"] as? NSNumber)?.stringValue
            guard responseID == "2" else { continue }
            if let error = json["error"] as? [String: Any] {
                throw AppError.codexApiError(error["message"] as? String ?? "Quota request failed")
            }
            guard let result = json["result"] as? [String: Any] else { continue }
            if let byLimitID = result["rateLimitsByLimitId"] as? [String: [String: Any]],
               let codex = byLimitID["codex"] {
                windows.append(contentsOf: parseRateLimitEnvelope(codex, now: now, limitId: "codex"))
            } else if let legacy = result["rateLimits"] as? [String: Any] {
                windows.append(contentsOf: parseRateLimitEnvelope(legacy, now: now, limitId: "codex"))
            }
        }
        return dedupeCodexWindows(windows)
    }

    private func parseRateLimitEnvelope(_ envelope: [String: Any], now: Date, limitId: String) -> [QuotaWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let value = envelope[key] as? [String: Any],
                  let duration = value["windowDurationMins"] as? Int, duration > 0,
                  let used = (value["usedPercent"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { return nil }
            let reset = (value["resetsAt"] as? NSNumber)?.doubleValue
            return QuotaWindow(
                id: "\(limitId)-\(duration)m",
                type: WindowType.from(durationMinutes: duration),
                durationMinutes: duration,
                usedPercent: used,
                remainingPercent: nil,
                resetsAt: reset.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                observedAt: now
            )
        }
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
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let state = CodexCommandState(continuation: continuation)
            let output = stdoutPipe.fileHandleForReading
            let input = stdinPipe.fileHandleForWriting
            let queue = DispatchQueue(label: "com.aiquota.codex.transport")
            let reader = DispatchSource.makeReadSource(fileDescriptor: output.fileDescriptor, queue: queue)
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            let flags = fcntl(output.fileDescriptor, F_GETFL)
            _ = fcntl(output.fileDescriptor, F_SETFL, flags | O_NONBLOCK)

            @Sendable func cleanUp() {
                reader.setEventHandler {}
                reader.cancel()
                input.closeFile()
                if process.isRunning { process.terminate() }
            }

            reader.setCancelHandler { output.closeFile() }

            @Sendable func fail(_ error: AppError) {
                if state.failIfPending(error) { cleanUp() }
            }

            @Sendable func send(_ message: String) {
                guard !state.isFinished else { return }
                let bytes = Array(message.utf8)
                let count = bytes.withUnsafeBufferPointer {
                    Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count != bytes.count { fail(.codexProcessExited) }
            }

            reader.setEventHandler {
                guard !state.isFinished else { return }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while !state.isFinished {
                    let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                    if count == 0 { fail(.codexProcessExited); return }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN { fail(.codexProcessExited) }
                        return
                    }
                    if state.append(Data(buffer.prefix(count))) {
                        if state.succeed() { cleanUp() }
                        return
                    }
                    if let result = state.takeInitializationResult() {
                        switch result {
                        case .success:
                            send(#"{"method":"initialized"}"# + "\n" +
                                #"{"id":"1","method":"account/read","params":{"refreshToken":false}}"# + "\n" +
                                #"{"id":"2","method":"account/rateLimits/read","params":{}}"# + "\n")
                        case .failure(let error): fail(error)
                        }
                    }
                }
            }
            reader.resume()
            queue.async {
                do { try process.run() }
                catch { fail(.codexProcessExited); return }
                send(#"{"id":"0","method":"initialize","params":{"clientInfo":{"name":"ai-quota","version":"1.0.0"},"capabilities":{}}}"# + "\n")
                // All reads, writes, EOF and cleanup use the same queue. stdin stays open.
                queue.asyncAfter(deadline: .now() + 18) { fail(.codexTimeout) }
            }
        }
    }
}

private final class CodexCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var resolved = false
    private var initializationHandled = false

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

    @discardableResult
    func succeed() -> Bool {
        let result: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            guard !resolved, let continuation else { return nil }
            resolved = true
            self.continuation = nil
            return (continuation, data)
        }
        guard let result else { return false }
        result.0.resume(returning: result.1)
        return true
    }

    func takeInitializationResult() -> Result<Void, AppError>? {
        lock.withLock {
            guard !resolved, !initializationHandled,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      ((object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue) == "0" else { continue }
                if object["error"] != nil {
                    initializationHandled = true
                    return .failure(.codexParseFailed("Initialization was rejected"))
                }
                if object["result"] != nil {
                    initializationHandled = true
                    return .success(())
                }
            }
            return nil
        }
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
                  ((object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue) == "2" else {
                return false
            }
            return object["result"] != nil || object["error"] != nil
        }
    }
}
