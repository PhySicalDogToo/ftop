import Foundation

/// The current default DNS configuration, not the complete set of macOS resolvers.
/// Domain-scoped and interface-scoped resolvers can answer other queries.
public struct DNSState: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        /// Server addresses in State:/Network/Global/DNS.
        case systemDefault
        /// A service's addresses shown only as a reference when Global/DNS is absent.
        case serviceReference
        case unavailable
    }

    public var servers: [String]
    public var source: Source
    /// The primary IPv4 interface and service. IPv6 can use another service.
    public var primaryInterface: String?
    public var primaryServiceID: String?
    public var primaryIPv6Interface: String?
    public var primaryIPv6ServiceID: String?
    /// Identifies the service used for `servers` only when source is serviceReference.
    public var referenceServiceID: String?
    public var services: [DNSServiceDetails]
    public var unavailableReason: String?

    public init(
        servers: [String] = [], source: Source = .unavailable,
        primaryInterface: String? = nil, primaryServiceID: String? = nil,
        primaryIPv6Interface: String? = nil, primaryIPv6ServiceID: String? = nil,
        referenceServiceID: String? = nil, services: [DNSServiceDetails] = [],
        unavailableReason: String? = nil
    ) {
        self.servers = servers
        self.source = source
        self.primaryInterface = primaryInterface
        self.primaryServiceID = primaryServiceID
        self.primaryIPv6Interface = primaryIPv6Interface
        self.primaryIPv6ServiceID = primaryIPv6ServiceID
        self.referenceServiceID = referenceServiceID
        self.services = services
        self.unavailableReason = unavailableReason
    }

    public var primaryServiceName: String? {
        if let primaryServiceID { return services.first { $0.id == primaryServiceID }?.name }
        return services.first { $0.id == primaryIPv6ServiceID }?.name
    }

    public var referenceService: DNSServiceDetails? {
        services.first { $0.id == referenceServiceID }
    }
}

/// The configured and dynamically supplied addresses of one network service.
/// No manual addresses does not establish whether its DNS came from DHCP, VPN,
/// a configuration profile, or another system component.
public struct DNSServiceDetails: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case wifi, ethernet, vpn, other, unknown
    }

    public var id: String
    public var name: String?
    public var interfaceName: String?
    public var kind: Kind
    public var manualServers: [String]
    /// State:/Network/Service/<id>/DNS. This is not a DHCP-only value.
    public var providedServers: [String]

    public init(
        id: String, name: String? = nil, interfaceName: String? = nil,
        kind: Kind = .unknown, manualServers: [String] = [], providedServers: [String] = []
    ) {
        self.id = id
        self.name = name
        self.interfaceName = interfaceName
        self.kind = kind
        self.manualServers = manualServers
        self.providedServers = providedServers
    }
}
