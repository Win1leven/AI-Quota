import Foundation
import Security
import LocalAuthentication
import SQLite3
import CommonCrypto
import CryptoKit

/// Reads only the desktop session cookies needed for the fixed, read-only usage endpoint.
final class ClaudeDesktopUsageService: @unchecked Sendable {
    private let cookieURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cookieURL = homeDirectory.appendingPathComponent("Library/Application Support/Claude/Cookies")
    }

    func fetchUsage() async throws -> Data {
        let cookies = try readCookies()
        var credentials: (String, String)?
        for account in ["Claude", "Claude Key"] {
            guard let password = try loadPassword(account: account) else { continue }
            if let session = try? Self.decryptCookie(cookies.session, password: password, host: ".claude.ai", databaseVersion: cookies.version),
               let organization = try? Self.decryptCookie(cookies.organization, password: password, host: ".claude.ai", databaseVersion: cookies.version) {
                credentials = (session, organization)
                break
            }
        }
        guard let (sessionKey, organizationID) = credentials else { throw DesktopError.unsupportedCookie }
        let request = try Self.request(sessionKey: sessionKey, organizationID: organizationID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw DesktopError.requestFailed }
            switch response.statusCode {
            case 200: return data
            case 401, 403: throw DesktopError.unauthorized
            case 429: throw DesktopError.rateLimited
            default: throw DesktopError.requestFailed
            }
        } catch let error as DesktopError { throw error }
        catch { throw DesktopError.requestFailed }
    }

    static func decryptCookie(_ encrypted: Data, password: Data, host: String, databaseVersion: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              !password.isEmpty else { throw DesktopError.unsupportedCookie }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derivation = password.withUnsafeBytes { passwordBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derivation == kCCSuccess else { throw DesktopError.unsupportedCookie }
        let input = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var size = 0
        let status = input.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, bytes.baseAddress, input.count, &output, output.count, &size)
        }
        guard status == kCCSuccess else { throw DesktopError.unsupportedCookie }
        var plaintext = Data(output.prefix(size))
        if databaseVersion >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.starts(with: digest) else { throw DesktopError.unsupportedCookie }
            plaintext = Data(plaintext.dropFirst(digest.count))
        }
        guard let value = String(data: plaintext, encoding: .utf8), !value.isEmpty else { throw DesktopError.unsupportedCookie }
        return value
    }

    static func request(sessionKey: String, organizationID: String) throws -> URLRequest {
        guard UUID(uuidString: organizationID) != nil, !sessionKey.isEmpty,
              sessionKey.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 && $0 != 44 && $0 != 34 && $0 != 92 }) else {
            throw DesktopError.sessionUnavailable
        }
        let url = URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage?skip_spend=1")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func loadPassword(account: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DesktopError.keychainLocked }
        return data
    }

    private func readCookies() throws -> (session: Data, organization: Data, version: Int) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(cookieURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw DesktopError.sessionUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name, encrypted_value FROM cookies WHERE host_key = '.claude.ai' AND name IN ('sessionKey', 'lastActiveOrg')", -1, &statement, nil) == SQLITE_OK else {
            throw DesktopError.sessionUnavailable
        }
        defer { sqlite3_finalize(statement) }
        var cookies: [String: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameBytes = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0, count < 8192 else { continue }
            cookies[String(cString: nameBytes)] = Data(bytes: bytes, count: count)
        }
        var metadata: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &metadata, nil) == SQLITE_OK else {
            throw DesktopError.unsupportedCookie
        }
        defer { sqlite3_finalize(metadata) }
        guard sqlite3_step(metadata) == SQLITE_ROW, let versionText = sqlite3_column_text(metadata, 0),
              let version = Int(String(cString: versionText)),
              let session = cookies["sessionKey"], let organization = cookies["lastActiveOrg"] else {
            throw DesktopError.sessionUnavailable
        }
        return (session, organization, version)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    enum DesktopError: LocalizedError {
        case sessionUnavailable, keychainLocked, unsupportedCookie, requestFailed, unauthorized, rateLimited
        var errorDescription: String? {
            switch self {
            case .sessionUnavailable: return "Desktop session unavailable. Sign in to Claude desktop and open its usage panel."
            case .keychainLocked: return "Claude desktop session is protected by Keychain. Unlock or allow access, then refresh."
            case .unsupportedCookie: return "Claude desktop cookie format is unsupported. Local quota history remains available."
            case .requestFailed: return "Claude desktop usage request failed. Local quota history remains available."
            case .unauthorized: return "Claude desktop usage access was rejected. Sign in again in Claude desktop."
            case .rateLimited: return "Claude usage requests are rate limited. Wait before refreshing."
            }
        }
    }
}
