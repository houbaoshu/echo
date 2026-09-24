import Foundation

@MainActor final class NativeMemorySecrets: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func write(_ value: String, account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values[account] = nil }
}
