import Foundation
import Testing
@testable import AIQuota

struct CodexTransportTests {
    @Test func successfulResponseIsKeptWhenHelperExitsImmediately() async throws {
        let fixture = try ServerFixture(requireHandshake: true, delay: 0.1, exitAfterResponse: true)
        defer { fixture.remove() }
        let sample = try await CodexQuotaProvider(executableURL: fixture.script).refresh()
        #expect(sample.primaryWindow?.usedPercent == 25)
    }

    @Test func helperFailureIsReportedAsExitRatherThanTimeout() async throws {
        let fixture = try ServerFixture(requireHandshake: false, delay: 0, immediateExit: true)
        defer { fixture.remove() }
        do {
            _ = try await CodexQuotaProvider(executableURL: fixture.script).refresh()
            Issue.record("Expected helper exit")
        } catch {
            #expect(error.localizedDescription == AppError.codexProcessExited.errorDescription)
        }
    }
    @Test func waitsForInitializationAndSendsInitializedNotification() async throws {
        let fixture = try ServerFixture(requireHandshake: true, delay: 0.1)
        defer { fixture.remove() }
        let sample = try await CodexQuotaProvider(executableURL: fixture.script).refresh()
        #expect(sample.primaryWindow?.usedPercent == 25)
    }

    @Test func keepsInputOpenUntilDelayedQuotaResponse() async throws {
        let fixture = try ServerFixture(requireHandshake: false, delay: 6)
        defer { fixture.remove() }
        let sample = try await CodexQuotaProvider(executableURL: fixture.script).refresh()
        #expect(sample.primaryWindow?.usedPercent == 25)
        #expect(Date().timeIntervalSince(sample.observedAt) < 2)
    }
}

private struct ServerFixture {
    let root: URL
    let script: URL
    init(requireHandshake: Bool, delay: Double, exitAfterResponse: Bool = false, immediateExit: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Codex transport \(UUID())")
        script = root.appendingPathComponent("server.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shell = #"""
        #!/bin/sh
        if [ "\#(immediateExit ? "1" : "0")" = "1" ]; then exit 3; fi
        initialized=0
        pending=""
        parent=$$
        while IFS= read -r line; do
            case "$line" in
                *'"method":"initialize"'*)
                    printf '%s\n' '{"id":"0","result":{}}'
                    ;;
                *'"method":"initialized"'*) initialized=1 ;;
                *'"method":"account/rateLimits/read"'*)
                    if [ "\#(requireHandshake ? "1" : "0")" = "1" ] && [ "$initialized" = "0" ]; then
                        printf '%s\n' '{"id":"2","error":{"message":"Not initialized"}}'
                    else
                        (
                            sleep \#(delay)
                            printf '%s\n' '{"id":"2","result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1900000000}}}}'
                            if [ "\#(exitAfterResponse ? "1" : "0")" = "1" ]; then kill -TERM "$parent"; fi
                        ) &
                        pending=$!
                    fi
                    ;;
            esac
        done
        if [ -n "$pending" ]; then kill "$pending" 2>/dev/null || true; fi
        """#
        try Data(shell.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
