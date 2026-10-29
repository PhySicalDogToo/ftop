import Darwin
import Foundation
import FtopCore
import SystemConfiguration

/// Reads DNS configuration without looking up an SSID, requesting permission,
/// resolving a hostname, or changing any network setting.
public enum DNSReader {
    public static func read() -> DNSState {
        guard let store = SCDynamicStoreCreate(nil, "dev.ftop.dns" as CFString, nil, nil) else {
            return DNSState(unavailableReason: "SystemConfiguration is unavailable")
        }
        let keys = ["State:/Network/Global/DNS", "State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
        let patterns = ["State:/Network/Service/[^/]+/DNS", "Setup:/Network/Service/[^/]+/DNS"]
        guard let records = SCDynamicStoreCopyMultiple(store, keys as CFArray, patterns as CFArray) as? [String: Any] else {
            return DNSState(unavailableReason: "SystemConfiguration did not provide DNS state")
        }

        func record(_ key: String) -> [String: Any] { records[key] as? [String: Any] ?? [:] }
        func addresses(_ record: [String: Any]) -> [String] {
            record[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
        }
        let ipv4 = record(keys[1])
        let ipv6 = record(keys[2])
        let primaryInterfaceKey = kSCDynamicStorePropNetPrimaryInterface as String
        let primaryServiceKey = kSCDynamicStorePropNetPrimaryService as String
        let primaryID = ipv4[primaryServiceKey] as? String
        let primaryIPv6ID = ipv6[primaryServiceKey] as? String
        let primaryInterface = ipv4[primaryInterfaceKey] as? String
        let primaryIPv6Interface = ipv6[primaryInterfaceKey] as? String

        var configured: [String: SCNetworkService] = [:]
        var orderedIDs: [String] = []
        if let preferences = SCPreferencesCreate(nil, "dev.ftop.dns" as CFString, nil),
            let current = SCNetworkSetCopyCurrent(preferences),
            let services = SCNetworkSetCopyServices(current) as? [SCNetworkService]
        {
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
                configured[id] = service
            }
            orderedIDs = (SCNetworkSetGetServiceOrder(current) as? [String] ?? []).filter { configured[$0] != nil }
            orderedIDs += configured.keys.filter { !orderedIDs.contains($0) }.sorted()
        }
        // Network Extension services can have dynamic DNS without a preferences entry.
        let dynamicIDs = records.keys.compactMap { key -> String? in
            let pieces = key.split(separator: "/")
            guard pieces.count == 5, pieces[0] == "State:", pieces[1] == "Network", pieces[2] == "Service", pieces[4] == "DNS" else { return nil }
            return String(pieces[3])
        }
        for id in ([primaryID, primaryIPv6ID].compactMap { $0 } + dynamicIDs.sorted()) where !orderedIDs.contains(id) {
            orderedIDs.append(id)
        }

        let details = orderedIDs.map { id -> DNSServiceDetails in
            let service = configured[id]
            let interface = service.flatMap(SCNetworkServiceGetInterface)
            let configuredBSD = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
            let bsd = configuredBSD ?? (id == primaryID ? primaryInterface : nil) ?? (id == primaryIPv6ID ? primaryIPv6Interface : nil)
            let type = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            return DNSServiceDetails(
                id: id, name: service.flatMap { SCNetworkServiceGetName($0) as String? },
                interfaceName: bsd, kind: kind(of: type),
                manualServers: addresses(record("Setup:/Network/Service/\(id)/DNS")),
                providedServers: addresses(record("State:/Network/Service/\(id)/DNS")))
        }
        return DNSSelection.state(
            globalServers: addresses(record(keys[0])), primaryInterface: primaryInterface, primaryServiceID: primaryID,
            primaryIPv6Interface: primaryIPv6Interface, primaryIPv6ServiceID: primaryIPv6ID, services: details)
    }

    private static func kind(of type: String?) -> DNSServiceDetails.Kind {
        guard let type else { return .unknown }
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
        if type == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
        if type == (kSCNetworkInterfaceTypeIPSec as String) || type == (kSCNetworkInterfaceTypeL2TP as String) || type == "VPN" { return .vpn }
        return .other
    }
}

/// Pure selection seam. Fixtures exercise resolver priority without system access.
enum DNSSelection {
    static func state(
        globalServers: [String], primaryInterface: String? = nil, primaryServiceID: String? = nil,
        primaryIPv6Interface: String? = nil, primaryIPv6ServiceID: String? = nil, services: [DNSServiceDetails] = []
    ) -> DNSState {
        let cleaned = services.map { service in
            var value = service
            value.manualServers = validServers(service.manualServers)
            value.providedServers = validServers(service.providedServers)
            return value
        }
        var state = DNSState(
            primaryInterface: primaryInterface, primaryServiceID: primaryServiceID,
            primaryIPv6Interface: primaryIPv6Interface, primaryIPv6ServiceID: primaryIPv6ServiceID, services: cleaned)
        let global = validServers(globalServers)
        if !global.isEmpty {
            state.servers = global
            state.source = .systemDefault
            return state
        }
        // Prefer a primary service, even if only its manual configuration is known.
        // Otherwise only a service with dynamic DNS can supply a reference.
        let primary = [primaryServiceID, primaryIPv6ServiceID].compactMap { id in
            cleaned.first { $0.id == id && (!$0.providedServers.isEmpty || !$0.manualServers.isEmpty) }
        }
        if let reference = primary.first ?? cleaned.first(where: { !$0.providedServers.isEmpty }) {
            state.servers = reference.providedServers.isEmpty ? reference.manualServers : reference.providedServers
            state.source = .serviceReference
            state.referenceServiceID = reference.id
        } else {
            state.unavailableReason = "No system default DNS addresses were reported"
        }
        return state
    }

    private static func validServers(_ values: [String]) -> [String] {
        var seen = Set<Data>()
        return values.compactMap { value in
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = addressKey(candidate), seen.insert(key).inserted else { return nil }
            return candidate
        }
    }

    private static func addressKey(_ value: String) -> Data? {
        let parts = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty,
            host.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 || $0 == 58 })
        else { return nil }
        var scope = ""
        if parts.count == 2 {
            scope = String(parts[1])
            guard host.contains(":"), !scope.isEmpty, scope.utf8.count <= 32,
                scope.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
                })
            else { return nil }
        }
        var ipv4 = in_addr()
        if String(host).withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return Data([4]) + withUnsafeBytes(of: ipv4) { Data($0) }
        }
        var ipv6 = in6_addr()
        if String(host).withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return Data([6]) + withUnsafeBytes(of: ipv6) { Data($0) } + Data(scope.utf8)
        }
        return nil
    }
}
