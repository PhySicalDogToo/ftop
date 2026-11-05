import Foundation

/// One event-time snapshot for deciding whether a matching rule needs a write.
/// Fingerprints cover connection identity and the complete saved DNS dictionary.
public struct DNSWiFiRuleContext: Sendable, Equatable {
    public enum Network: Sendable, Equatable {
        case wifi(ssid: String, locationID: String, serviceID: String, connectionID: Data)
        case unknownSSID, disconnected, nonWiFi
    }

    public var network: Network
    public var manualServers: [String]
    public var hasManualAddressKey: Bool
    public var dnsFingerprint: Data

    public init(
        network: Network, manualServers: [String] = [], hasManualAddressKey: Bool = false,
        dnsFingerprint: Data = Data()
    ) {
        self.network = network
        self.manualServers = manualServers
        self.hasManualAddressKey = hasManualAddressKey
        self.dnsFingerprint = dnsFingerprint
    }
}

public enum DNSWiFiRuleDecision: Sendable, Equatable {
    public enum WaitingReason: Sendable, Equatable { case unknownSSID, disconnected, nonWiFi, incompleteSnapshot }
    public enum BlockedReason: Sendable, Equatable { case externalConfigurationChange, invalidConfiguration, writeFailed }

    case off
    case waiting(WaitingReason)
    case blocked(BlockedReason)
    case apply(DNSWiFiRuleMatch)
    case unchanged(DNSWiFiRuleMatch)
}

/// Event-driven reassertion with a rolling contention budget. Only observed
/// address changes away from the selected rule count; verified own writes and
/// unrelated DNS fields do not. Time is injected, never read from the system.
public struct DNSWiFiRulePolicy: Sendable {
    public static let reassertionWindow: TimeInterval = 60
    public static let maximumReassertions = 5

    private struct Connection: Sendable, Equatable {
        var ssid: String
        var locationID: String
        var serviceID: String
        var identifier: Data
    }

    private struct Observation: Sendable {
        var connection: Connection
        var context: DNSWiFiRuleContext
    }

    private var observation: Observation?
    private var blockedConnection: Connection?
    private var blockedReason: DNSWiFiRuleDecision.BlockedReason?
    private var externalChangeTimes: [TimeInterval] = []
    public var externalChangeCount: Int { externalChangeTimes.count }

    public init() {}

    public mutating func reset() {
        observation = nil
        blockedConnection = nil
        blockedReason = nil
        externalChangeTimes = []
    }

    public mutating func decide(
        at now: TimeInterval, configuration: DNSWiFiRulesConfiguration, context: DNSWiFiRuleContext
    ) -> DNSWiFiRuleDecision {
        guard configuration.enabled else {
            reset()
            return .off
        }
        let valid: DNSWiFiRulesConfiguration
        do { valid = try configuration.validated() } catch { return .blocked(.invalidConfiguration) }
        guard now.isFinite else { return .blocked(.invalidConfiguration) }

        let connection: Connection
        switch context.network {
        case .unknownSSID: return .waiting(.unknownSSID)
        case .disconnected:
            reset()
            return .waiting(.disconnected)
        case .nonWiFi: return .waiting(.nonWiFi)
        case .wifi(let ssid, let locationID, let serviceID, let identifier):
            guard !ssid.isEmpty else { return .waiting(.unknownSSID) }
            guard !locationID.isEmpty, !serviceID.isEmpty, !identifier.isEmpty,
                !context.dnsFingerprint.isEmpty
            else { return .waiting(.incompleteSnapshot) }
            connection = Connection(
                ssid: ssid, locationID: locationID, serviceID: serviceID,
                identifier: identifier)
        }

        guard let match = valid.match(forSSID: connection.ssid) else {
            return .blocked(.invalidConfiguration)
        }
        if blockedConnection == connection, let blockedReason { return .blocked(blockedReason) }
        if observation?.connection != connection {
            observation = nil
            externalChangeTimes = []
            blockedConnection = nil
            blockedReason = nil
        }

        let matches: Bool
        switch match.mode {
        case .automatic:
            matches = !context.hasManualAddressKey
        case .custom(let addresses):
            matches = DNSAddressList.equivalent(addresses, context.manualServers)
        }

        externalChangeTimes.removeAll { now - $0 >= Self.reassertionWindow || $0 > now }
        if let previous = observation?.context,
            previous.dnsFingerprint != context.dnsFingerprint, !matches,
            previous.hasManualAddressKey != context.hasManualAddressKey
                || !(previous.manualServers == context.manualServers
                    || DNSAddressList.equivalent(previous.manualServers, context.manualServers))
        {
            externalChangeTimes.append(now)
            if externalChangeTimes.count > Self.maximumReassertions {
                blockedConnection = connection
                blockedReason = .externalConfigurationChange
                return .blocked(.externalConfigurationChange)
            }
        }
        // Adopting this read deduplicates repeated notifications. It is still an
        // immutable transaction baseline: a subsequent race must fail validation.
        observation = Observation(connection: connection, context: context)
        return matches ? .unchanged(match) : .apply(match)
    }

    public mutating func recordApplied(context: DNSWiFiRuleContext) {
        guard let connection = connection(in: context),
            blockedConnection != connection, !context.dnsFingerprint.isEmpty
        else { return }
        observation = Observation(
            connection: connection, context: context)
    }

    public mutating func recordFailure(context: DNSWiFiRuleContext) {
        guard let connection = connection(in: context), observation?.connection == connection
        else { return }
        blockedConnection = connection
        blockedReason = .writeFailed
    }

    private func connection(in context: DNSWiFiRuleContext) -> Connection? {
        guard
            case .wifi(let ssid, let location, let service, let identifier) =
                context.network,
            !ssid.isEmpty, !location.isEmpty, !service.isEmpty, !identifier.isEmpty
        else { return nil }
        return Connection(
            ssid: ssid, locationID: location, serviceID: service,
            identifier: identifier)
    }
}
