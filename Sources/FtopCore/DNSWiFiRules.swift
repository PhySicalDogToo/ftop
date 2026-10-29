import Foundation

/// One exact Wi-Fi-name rule. System APIs and permission state stay outside Core.
public struct DNSWiFiRule: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var ssid: String
    public var mode: DNSManualMode

    public init(id: UUID = UUID(), ssid: String, mode: DNSManualMode) {
        self.id = id
        self.ssid = ssid
        self.mode = mode
    }
}

/// The rule selected for one identifiable Wi-Fi. An exact name always wins over
/// the required, non-removable default rule.
public struct DNSWiFiRuleMatch: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case exact(String)
        case defaultRule
    }

    public var source: Source
    public var mode: DNSManualMode

    public init(source: Source, mode: DNSManualMode) {
        self.source = source
        self.mode = mode
    }

    public var matchedSSID: String? {
        guard case .exact(let ssid) = source else { return nil }
        return ssid
    }

    public var usesDefault: Bool { source == .defaultRule }
}

/// Persisted rule intent. Every identifiable Wi-Fi resolves to either one exact
/// rule or the required default rule. An unreadable name is still left unchanged.
public struct DNSWiFiRulesConfiguration: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var defaultMode: DNSManualMode
    public var rules: [DNSWiFiRule]

    /// First launch remains inert until the owner explicitly enables and saves.
    public static let defaults = DNSWiFiRulesConfiguration(
        enabled: false, defaultMode: .automatic, rules: [])

    public init(
        enabled: Bool = true, defaultMode: DNSManualMode = .automatic,
        rules: [DNSWiFiRule] = []
    ) {
        self.enabled = enabled
        self.defaultMode = defaultMode
        self.rules = rules
    }

    public func rule(forSSID ssid: String?) -> DNSWiFiRule? {
        guard let ssid, !ssid.isEmpty else { return nil }
        return rules.first { $0.ssid == ssid }
    }

    public func match(forSSID ssid: String?) -> DNSWiFiRuleMatch? {
        guard let ssid, !ssid.isEmpty else { return nil }
        if let rule = rule(forSSID: ssid) {
            return DNSWiFiRuleMatch(
                source: .exact(rule.ssid), mode: rule.mode)
        }
        return DNSWiFiRuleMatch(source: .defaultRule, mode: defaultMode)
    }

    public func validated() throws -> DNSWiFiRulesConfiguration {
        let validDefault: DNSManualMode
        switch defaultMode {
        case .automatic:
            validDefault = .automatic
        case .custom(let addresses):
            validDefault = .custom(
                try DNSAddressList.validated(addresses))
        }
        var names = Set<String>()
        var identifiers = Set<UUID>()
        let validRules = try rules.map { rule in
            guard !rule.ssid.isEmpty else { throw DNSWiFiRulesValidationError.emptySSID }
            guard rule.ssid.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw DNSWiFiRulesValidationError.invalidSSID
            }
            guard names.insert(rule.ssid).inserted else {
                throw DNSWiFiRulesValidationError.duplicateSSID(rule.ssid)
            }
            guard identifiers.insert(rule.id).inserted else {
                throw DNSWiFiRulesValidationError.duplicateID
            }
            let mode: DNSManualMode
            switch rule.mode {
            case .automatic: mode = .automatic
            case .custom(let addresses): mode = .custom(try DNSAddressList.validated(addresses))
            }
            return DNSWiFiRule(id: rule.id, ssid: rule.ssid, mode: mode)
        }
        return DNSWiFiRulesConfiguration(
            enabled: enabled, defaultMode: validDefault, rules: validRules)
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, defaultMode, rules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.contains(.version) ? values.decode(Int.self, forKey: .version) : 1
        guard version == 1 || version == 2 else {
            throw DNSWiFiRulesValidationError.unsupportedVersion(version)
        }
        enabled = try values.contains(.enabled) ? values.decode(Bool.self, forKey: .enabled) : true
        // Version 1 had no default rule. Migration chooses Automatic, which is the
        // least surprising fallback once the owner installs this explicit feature.
        defaultMode =
            try values.contains(.defaultMode)
            ? values.decode(DNSManualMode.self, forKey: .defaultMode)
            : .automatic
        rules = try values.contains(.rules) ? values.decode([DNSWiFiRule].self, forKey: .rules) : []
        self = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        let configuration = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(configuration.enabled, forKey: .enabled)
        try values.encode(configuration.defaultMode, forKey: .defaultMode)
        try values.encode(configuration.rules, forKey: .rules)
    }
}

public enum DNSWiFiRulesValidationError: LocalizedError, Sendable, Equatable {
    case emptySSID, invalidSSID, duplicateID
    case duplicateSSID(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptySSID: "Enter a Wi-Fi name for every rule."
        case .invalidSSID: "A Wi-Fi name cannot contain a newline, tab, or other control character."
        case .duplicateID: "Two Wi-Fi rules have the same identifier. Remove the duplicate and add it again."
        case .duplicateSSID(let ssid): "The Wi-Fi name \u{201c}\(ssid)\u{201d} appears more than once. Keep one exact-name rule."
        case .unsupportedVersion: "These Wi-Fi DNS rules use an unsupported format. The saved data was not replaced."
        }
    }
}

/// Value-only presentation state shared with the AppKit rules editor.
public struct DNSWiFiRulesStatus: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case off, waiting, needsWiFiAccess, needsNetworkAuthorization, applying,
            active, blocked
    }

    public var phase: Phase
    public var ssid: String?
    public var matchedSSID: String?
    public var usesDefault: Bool
    public var servers: [String]
    public var message: String

    public init(
        phase: Phase = .off, ssid: String? = nil, matchedSSID: String? = nil,
        usesDefault: Bool = false, servers: [String] = [], message: String = ""
    ) {
        self.phase = phase
        self.ssid = ssid
        self.matchedSSID = matchedSSID
        self.usesDefault = usesDefault
        self.servers = servers
        self.message = message
    }
}
