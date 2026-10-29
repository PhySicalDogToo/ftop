import Foundation
import FtopCore

/// Persists only user-authored rules. The retired automation key is deliberately
/// not migrated so old inactive defaults cannot start changing DNS unexpectedly.
public struct DNSWiFiRulesStore {
    public static let defaultKey = "DNSWiFiRules.v2"
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = DNSWiFiRulesStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> DNSWiFiRulesConfiguration {
        guard let value = defaults.object(forKey: key) else { return .defaults }
        guard let data = value as? Data else {
            throw DNSWiFiRulesStoreError.invalidStoredData
        }
        do {
            return try JSONDecoder().decode(
                DNSWiFiRulesConfiguration.self, from: data
            ).validated()
        } catch {
            throw DNSWiFiRulesStoreError.invalidStoredData
        }
    }

    /// Validate and encode before replacing the single key. A failed readback
    /// restores the previous value where possible.
    public func save(_ configuration: DNSWiFiRulesConfiguration) throws {
        let configuration = try configuration.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard
            try JSONDecoder().decode(
                DNSWiFiRulesConfiguration.self, from: data) == configuration
        else { throw DNSWiFiRulesStoreError.saveFailed }

        let previous = defaults.object(forKey: key)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            throw DNSWiFiRulesStoreError.saveFailed
        }
    }
}

public enum DNSWiFiRulesStoreError: LocalizedError, Sendable {
    case invalidStoredData, saveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            "Saved Wi-Fi DNS rules could not be read. Their original data was retained."
        case .saveFailed:
            "The Wi-Fi DNS rules could not be verified after saving. The previous value was restored where possible."
        }
    }
}
