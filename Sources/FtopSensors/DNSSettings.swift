import Darwin
import Foundation
import FtopCore
import Security
import SystemConfiguration

struct DNSConfigurationSnapshot {
    var locationID: String
    var serviceID: String
    var serviceName: String
    var interfaceName: String
    var protocolExists: Bool
    var protocolEnabled: Bool
    var configuration: [String: Any]?
    var network: [String: Any]

    var manualServers: [String] {
        get throws {
            guard let value = configuration?["ServerAddresses"] else { return [] }
            guard let addresses = value as? [String] else {
                throw DNSChangeError(code: .invalidTarget, message: "The existing DNS addresses cannot be safely edited. Open Network settings instead.")
            }
            return addresses
        }
    }

    var envelope: [String: Any] {
        [
            "version": 1, "location": locationID, "service": serviceID, "name": serviceName, "interface": interfaceName,
            "protocolExists": protocolExists, "protocolEnabled": protocolEnabled,
            "hasConfiguration": configuration != nil, "configuration": configuration ?? [:], "network": network,
        ]
    }

    func target() throws -> DNSEditTarget {
        DNSEditTarget(
            locationID: locationID, serviceID: serviceID, serviceName: serviceName, interfaceName: interfaceName,
            manualServers: try manualServers,
            configurationToken: try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0))
    }

    static func decode(_ target: DNSEditTarget) throws -> DNSConfigurationSnapshot {
        guard !target.configurationToken.isEmpty, target.configurationToken.count <= 1_048_576,
            let value = try? PropertyListSerialization.propertyList(from: target.configurationToken, options: [], format: nil),
            let envelope = value as? [String: Any], envelope["version"] as? Int == 1,
            let location = envelope["location"] as? String, location == target.locationID, !location.isEmpty,
            let service = envelope["service"] as? String, service == target.serviceID, !service.isEmpty,
            let name = envelope["name"] as? String, name == target.serviceName,
            let interface = envelope["interface"] as? String, interface == target.interfaceName, !interface.isEmpty,
            let exists = envelope["protocolExists"] as? Bool, let enabled = envelope["protocolEnabled"] as? Bool,
            let hasConfiguration = envelope["hasConfiguration"] as? Bool,
            let configuration = envelope["configuration"] as? [String: Any],
            let network = envelope["network"] as? [String: Any], !network.isEmpty,
            hasConfiguration || configuration.isEmpty,
            exists || (!enabled && !hasConfiguration && configuration.isEmpty)
        else {
            throw DNSChangeError(
                code: .invalidTarget,
                message:
                    "This DNS operation has no valid baseline. Review the current network service and try again.")
        }
        let snapshot = DNSConfigurationSnapshot(
            locationID: location, serviceID: service, serviceName: name, interfaceName: interface,
            protocolExists: exists, protocolEnabled: enabled, configuration: hasConfiguration ? configuration : nil, network: network)
        guard try snapshot.manualServers == target.manualServers else {
            throw DNSChangeError(
                code: .invalidTarget,
                message:
                    "The DNS baseline no longer matches the current operation. Review the current network service and try again.")
        }
        return snapshot
    }

    func matches(_ other: DNSConfigurationSnapshot) -> Bool {
        NSDictionary(dictionary: envelope).isEqual(to: other.envelope)
    }

    func sameConnection(as other: DNSConfigurationSnapshot) -> Bool {
        var before = network
        var after = other.network
        before.removeValue(forKey: "dns")
        after.removeValue(forKey: "dns")
        return locationID == other.locationID && serviceID == other.serviceID && interfaceName == other.interfaceName
            && NSDictionary(dictionary: before).isEqual(to: after)
    }
}

protocol DNSWriteBackend: AnyObject {
    func current() throws -> DNSConfigurationSnapshot
    func externalWriterRunning() throws -> Bool
    func authorize() throws
    func lock() throws
    func unlock()
    func stage(_ configuration: [String: Any], createProtocol: Bool) throws
    func commit() throws
    func apply() throws
    func reread(_ original: DNSConfigurationSnapshot) throws -> DNSConfigurationSnapshot
    func state() -> DNSState
}

/// The same verified transaction backend with two event-time safeguards: a
/// retained native authorization right and a fresh Wi-Fi check before every
/// mutation boundary.
protocol DNSWiFiRulesWriteBackend: DNSWriteBackend {
    var beforeMutationCheck: (() throws -> Void)? { get set }
    func authorizeAutomationSession() throws
}

enum DNSChangeTransaction {
    static func save(_ request: DNSChangeRequest, backend: DNSWriteBackend) throws -> DNSWriteResult {
        let baseline = try DNSConfigurationSnapshot.decode(request.target)
        let addresses: [String]
        switch request.mode {
        case .automatic: addresses = []
        case .custom(let values): addresses = try DNSAddressList.validated(values)
        }
        let before = try backend.current()
        guard before.matches(baseline) else { throw conflict() }
        // Automatic must remove the key even if it currently holds an empty array.
        let alreadyMatches = try before.manualServers == addresses && (request.mode != .automatic || before.configuration?["ServerAddresses"] == nil)
        if alreadyMatches {
            return DNSWriteResult(target: try before.target(), state: backend.state(), didChange: false)
        }
        guard try !backend.externalWriterRunning() else {
            throw DNSChangeError(code: .externalWriter, message: "Another DNS writer is active. Quit it before saving to avoid conflicting changes.")
        }
        guard !before.protocolExists || before.protocolEnabled else {
            throw DNSChangeError(code: .invalidTarget, message: "DNS is disabled for this service. Use Network settings instead.")
        }
        try backend.authorize()
        try backend.lock()
        defer { backend.unlock() }
        let locked = try backend.current()
        guard locked.matches(baseline), try !backend.externalWriterRunning() else { throw conflict() }
        var candidate = locked.configuration ?? [:]
        if addresses.isEmpty { candidate.removeValue(forKey: "ServerAddresses") } else { candidate["ServerAddresses"] = addresses }
        try backend.stage(candidate, createProtocol: !locked.protocolExists)
        // Recheck the connection immediately before the single persistent write.
        // This detects address/router/link changes; it cannot identify identical
        // networks or guarantee an unchanged SSID without reading the SSID.
        let staged = try backend.current()
        guard locked.sameConnection(as: staged) else { throw conflict() }
        do { try backend.commit() } catch {
            let current = try? backend.reread(locked)
            if let current,
                current.protocolExists == locked.protocolExists, current.protocolEnabled == locked.protocolEnabled,
                NSDictionary(dictionary: current.configuration ?? [:]).isEqual(to: locked.configuration ?? [:])
            {
                let code = (error as? DNSChangeError)?.code ?? .writeFailed
                throw DNSChangeError(
                    code: code, persistence: .unchanged, currentManualServers: try? current.manualServers,
                    message: "DNS could not be saved; a fresh read confirms the previous values are unchanged. Check permission or reopen Network settings.")
            }
            if let current { throw persistedFailure(.writeFailed, verified: current, candidate: candidate, addresses: addresses) }
            throw DNSChangeError(
                code: .writeFailed, persistence: .unknown,
                message: "The save operation failed and its stored result could not be verified. Check Network settings before retrying.")
        }
        do { try backend.apply() } catch {
            throw persistedFailure(.applyFailed, backend: backend, original: locked, candidate: candidate, addresses: addresses)
        }
        let verified: DNSConfigurationSnapshot
        do { verified = try backend.reread(locked) } catch {
            throw DNSChangeError(
                code: .verificationFailed, persistence: .unknown,
                message: "DNS was committed, but its saved state could not be reread. Check Network settings before retrying.")
        }
        guard NSDictionary(dictionary: verified.configuration ?? [:]).isEqual(to: candidate),
            verified.protocolExists, verified.protocolEnabled, try verified.manualServers == addresses
        else {
            throw persistedFailure(.verificationFailed, verified: verified, candidate: candidate, addresses: addresses)
        }
        guard locked.sameConnection(as: verified) else {
            throw DNSChangeError(
                code: .verificationFailed, persistence: .saved, currentManualServers: addresses,
                message:
                    "DNS was saved for this service, but the connection or network location changed. Review the current service before trying again.")
        }
        return DNSWriteResult(target: try verified.target(), state: backend.state())
    }

    private static func conflict() -> DNSChangeError {
        DNSChangeError(
            code: .conflict,
            message:
                "The service, network location, connection, or DNS settings changed. Review the current service before trying again.")
    }

    private static func persistedFailure(
        _ code: DNSChangeError.Code, backend: DNSWriteBackend, original: DNSConfigurationSnapshot, candidate: [String: Any], addresses: [String]
    ) -> DNSChangeError {
        guard let verified = try? backend.reread(original) else {
            return DNSChangeError(
                code: code, persistence: .unknown, message: "DNS was committed, but the saved state could not be verified. Check Network settings before retrying.")
        }
        return persistedFailure(code, verified: verified, candidate: candidate, addresses: addresses)
    }

    private static func persistedFailure(
        _ code: DNSChangeError.Code, verified: DNSConfigurationSnapshot, candidate: [String: Any], addresses: [String]
    ) -> DNSChangeError {
        let current = try? verified.manualServers
        let saved = current == addresses && NSDictionary(dictionary: verified.configuration ?? [:]).isEqual(to: candidate)
        return DNSChangeError(
            code: code, persistence: saved ? .saved : .unknown, currentManualServers: current,
            message: saved
                ? "DNS was saved, but applying it to the running system could not be confirmed. Check Network settings; the saved change was not rolled back."
                : "The saved DNS differs from this request, possibly because another app changed it. The current values were not overwritten again.")
    }
}

final class DNSNativeBackend: DNSWiFiRulesWriteBackend {
    private var preferences: SCPreferences
    private var authorization: AuthorizationRef?
    private var lockedService: SCNetworkService?
    private var holdsLock = false
    private var retainedSession = false
    var beforeMutationCheck: (() throws -> Void)?

    init() throws {
        guard let preferences = SCPreferencesCreate(nil, "dev.ftop.dns.edit" as CFString, nil) else { throw Self.failure(.unavailable) }
        self.preferences = preferences
    }

    deinit {
        if holdsLock { _ = SCPreferencesUnlock(preferences) }
        if let authorization { AuthorizationFree(authorization, []) }
    }

    func current() throws -> DNSConfigurationSnapshot {
        if !holdsLock { SCPreferencesSynchronize(preferences) }
        let snapshot = try capture(preferences: preferences)
        if holdsLock { lockedService = SCNetworkServiceCopy(preferences, snapshot.serviceID as CFString) }
        return snapshot
    }

    func authorize() throws {
        if retainedSession {
            try checkRetainedAuthorization(interactionAllowed: false)
            return
        }
        var authorization: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw DNSChangeError(
                code: status == errAuthorizationCanceled ? .authorizationCancelled : .permissionDenied,
                message: "macOS did not authorize this network change. No DNS was saved. Use an administrator account or Network settings.")
        }
        self.authorization = authorization
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "dev.ftop.dns.edit" as CFString, nil, authorization) else {
            throw Self.failure(.permissionDenied)
        }
        self.preferences = preferences
    }

    /// Establish a native SystemConfiguration right once for the current app
    /// process. Later Wi-Fi events only check the retained right and never open
    /// their own background authentication prompt.
    func authorizeAutomationSession() throws {
        try authorize()
        try checkRetainedAuthorization(interactionAllowed: true)
        try lock()
        unlock()
        retainedSession = true
    }

    private func checkRetainedAuthorization(interactionAllowed: Bool) throws {
        guard let authorization else {
            throw DNSChangeError(
                code: .permissionDenied,
                message: "Authorize automatic DNS for this app session."
            )
        }
        let status: OSStatus =
            "system.services.systemconfiguration.network".withCString { name in
                var item = AuthorizationItem(
                    name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { pointer in
                    var rights = AuthorizationRights(count: 1, items: pointer)
                    let flags: AuthorizationFlags =
                        interactionAllowed
                        ? [.interactionAllowed, .extendRights] : []
                    return AuthorizationCopyRights(
                        authorization, &rights, nil, flags, nil)
                }
            }
        guard status == errAuthorizationSuccess else {
            throw DNSChangeError(
                code: status == errAuthorizationCanceled
                    ? .authorizationCancelled : .permissionDenied,
                message:
                    "Automatic DNS authorization is unavailable or expired. Open Wi-Fi DNS Rules and save again to authorize it."
            )
        }
    }

    func lock() throws {
        try beforeMutationCheck?()
        if retainedSession {
            try checkRetainedAuthorization(interactionAllowed: false)
        }
        guard SCPreferencesLock(preferences, false) else { throw Self.failure(.busy) }
        holdsLock = true
        SCPreferencesSynchronize(preferences)
    }

    func unlock() {
        if holdsLock { _ = SCPreferencesUnlock(preferences) }
        holdsLock = false
    }

    func stage(_ configuration: [String: Any], createProtocol: Bool) throws {
        try beforeMutationCheck?()
        if retainedSession {
            try checkRetainedAuthorization(interactionAllowed: false)
        }
        guard let service = lockedService else { throw Self.failure(.writeFailed) }
        if createProtocol, !SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS) { throw Self.failure(.writeFailed) }
        guard let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
            SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary)
        else { throw Self.failure(.writeFailed) }
    }

    func commit() throws {
        try beforeMutationCheck?()
        if retainedSession {
            try checkRetainedAuthorization(interactionAllowed: false)
        }
        guard SCPreferencesCommitChanges(preferences) else { throw Self.failure(.writeFailed) }
    }

    func apply() throws {
        guard SCPreferencesApplyChanges(preferences) else { throw Self.failure(.applyFailed) }
    }

    func reread(_ original: DNSConfigurationSnapshot) throws -> DNSConfigurationSnapshot {
        guard let fresh = SCPreferencesCreate(nil, "dev.ftop.dns.verify" as CFString, nil) else { throw Self.failure(.unavailable) }
        return try capture(preferences: fresh, serviceID: original.serviceID)
    }

    func state() -> DNSState { DNSReader.read() }

    func externalWriterRunning() throws -> Bool {
        let estimated = Int(proc_listallpids(nil, 0))
        guard estimated > 0, estimated < 32768 else { throw Self.processCheckFailure() }
        var capacity = min(32768, estimated + 128)
        for _ in 0..<2 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            guard count > 0 else { throw Self.processCheckFailure() }
            guard count < capacity else { capacity = min(32768, capacity * 2); continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            for pid in pids.prefix(count) where pid > 0 {
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
                let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if URL(fileURLWithPath: executable).lastPathComponent == "WiFiDNSSwitcher" { return true }
            }
            return false
        }
        throw Self.processCheckFailure()
    }

    private static func processCheckFailure() -> DNSChangeError {
        DNSChangeError(code: .unavailable, message: "Other DNS tools could not be checked safely. Use Network settings instead.")
    }

    private func capture(preferences: SCPreferences, serviceID explicitID: String? = nil) throws -> DNSConfigurationSnapshot {
        guard let current = SCNetworkSetCopyCurrent(preferences), let location = SCNetworkSetGetSetID(current) as String?,
            let services = SCNetworkSetCopyServices(current) as? [SCNetworkService],
            let store = SCDynamicStoreCreate(nil, "dev.ftop.dns.edit" as CFString, nil, nil),
            let records = SCDynamicStoreCopyMultiple(
                store, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
                ["State:/Network/Service/[^/]+/(IPv4|IPv6|DNS)", "State:/Network/Interface/[^/]+/Link"] as CFArray) as? [String: Any]
        else { throw Self.failure(.unavailable) }
        func record(_ key: String) -> [String: Any] { records[key] as? [String: Any] ?? [:] }
        let v4 = record("State:/Network/Global/IPv4")
        let v6 = record("State:/Network/Global/IPv6")
        let physical = services.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service),
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                type == (kSCNetworkInterfaceTypeIEEE80211 as String) || type == (kSCNetworkInterfaceTypeEthernet as String)
            else { return false }
            return true
        }
        func interfaceName(_ service: SCNetworkService) -> String? {
            SCNetworkServiceGetInterface(service).flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
        }
        func active(_ service: SCNetworkService) -> Bool {
            guard let id = SCNetworkServiceGetServiceID(service) as String?, let bsd = interfaceName(service) else { return false }
            let addresses = ["IPv4", "IPv6"].flatMap { record("State:/Network/Service/\(id)/\($0)")["Addresses"] as? [String] ?? [] }
            return !addresses.isEmpty && record("State:/Network/Interface/\(bsd)/Link")["Active"] as? Bool != false
        }
        let selected: SCNetworkService?
        if let explicitID {
            selected = physical.first { SCNetworkServiceGetServiceID($0) as String? == explicitID }
        } else {
            let candidates = physical.filter(active)
            let primaryIDs = [v4["PrimaryService"] as? String, v6["PrimaryService"] as? String].compactMap { $0 }
            selected =
                primaryIDs.compactMap { id in candidates.first { SCNetworkServiceGetServiceID($0) as String? == id } }.first
                ?? (candidates.count == 1 ? candidates[0] : nil)
        }
        guard let service = selected, let id = SCNetworkServiceGetServiceID(service) as String?, let bsd = interfaceName(service) else {
            throw DNSChangeError(
                code: .noPhysicalService,
                message: "A single current Wi-Fi or Ethernet service could not be identified. Use Network settings to select the service explicitly.")
        }
        let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
        let configuration = dns.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
        let primaryFields = ["PrimaryService", "PrimaryInterface", "Router"]
        func primary(_ value: [String: Any]) -> [String: Any] { value.filter { primaryFields.contains($0.key) } }
        return DNSConfigurationSnapshot(
            locationID: location, serviceID: id, serviceName: SCNetworkServiceGetName(service) as String? ?? bsd, interfaceName: bsd,
            protocolExists: dns != nil, protocolEnabled: dns.map(SCNetworkProtocolGetEnabled) ?? false, configuration: configuration,
            network: [
                "globalIPv4": primary(v4), "globalIPv6": primary(v6),
                "ipv4": record("State:/Network/Service/\(id)/IPv4"), "ipv6": record("State:/Network/Service/\(id)/IPv6"),
                "link": record("State:/Network/Interface/\(bsd)/Link"), "dns": record("State:/Network/Service/\(id)/DNS"),
            ])
    }

    private static func failure(_ fallback: DNSChangeError.Code) -> DNSChangeError {
        let status = SCError()
        if status == errAuthorizationCanceled {
            return DNSChangeError(code: .authorizationCancelled, message: "Network authorization was cancelled. No new DNS was saved.")
        }
        if status == kSCStatusAccessError {
            return DNSChangeError(code: .permissionDenied, message: "macOS did not authorize the network change. Use an administrator account or Network settings.")
        }
        if status == kSCStatusPrefsBusy || status == kSCStatusLocked {
            return DNSChangeError(code: .busy, message: "Network settings are being changed by another app. Try again after it finishes.")
        }
        if status == kSCStatusStale {
            return DNSChangeError(
                code: .conflict,
                message:
                    "Network preferences changed. Review the current service before trying again.")
        }
        return DNSChangeError(code: fallback, message: "The network configuration operation failed (\(status)). Check Network settings before retrying.")
    }
}
