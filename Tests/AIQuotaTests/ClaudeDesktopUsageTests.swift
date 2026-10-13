import Foundation
import Testing
@testable import AIQuota

struct ClaudeDesktopUsageTests {
    private var encrypted: Data {
        let hex = "763130cba8d8b3b813f784aae46dea9258b58b3d19f5f789dc4778df01527afd73e93ef2273e166b323b586230da419bf5ebe63dde394476b84a59551c180af211045e"
        return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    @Test func decryptsHostBoundChromiumCookie() throws {
        // Independent OpenSSL fixture; entirely synthetic and not from any real account.
        let value = try ClaudeDesktopUsageService.decryptCookie(encrypted, password: Data("test-password".utf8), host: ".claude.ai", databaseVersion: 24)
        #expect(value == "synthetic-session")
        #expect(throws: (any Error).self) {
            try ClaudeDesktopUsageService.decryptCookie(encrypted, password: Data("wrong-password".utf8), host: ".claude.ai", databaseVersion: 24)
        }
        #expect(throws: (any Error).self) {
            try ClaudeDesktopUsageService.decryptCookie(encrypted, password: Data("test-password".utf8), host: "another.host", databaseVersion: 24)
        }
    }

    @Test func requestIsRestrictedAndRejectsHeaderInjection() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let request = try ClaudeDesktopUsageService.request(sessionKey: "synthetic-session", organizationID: id)
        #expect(request.url?.absoluteString == "https://claude.ai/api/organizations/\(id)/usage?skip_spend=1")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=synthetic-session")
        for bad in ["abc\r\nInjected: true", "abc;other=value", ""] {
            #expect(throws: (any Error).self) { try ClaudeDesktopUsageService.request(sessionKey: bad, organizationID: id) }
        }
        #expect(throws: (any Error).self) { try ClaudeDesktopUsageService.request(sessionKey: "synthetic", organizationID: "../../outside") }
    }
}
