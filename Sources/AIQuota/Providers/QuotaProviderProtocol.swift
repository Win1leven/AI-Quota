import Foundation

protocol QuotaProviderProtocol: Sendable {
    var id: ProviderID { get }
    var isAvailable: Bool { get }

    func refresh() async throws -> QuotaSnapshot
    func isInstalledAndLoggedIn() async -> Bool
}
