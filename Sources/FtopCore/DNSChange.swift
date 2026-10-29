import Foundation

public enum DNSManualMode: Sendable, Equatable, Codable {
    case automatic
    case custom([String])

    public var servers: [String] {
        switch self {
        case .automatic: []
        case .custom(let addresses): addresses
        }
    }
}

/// An opaque baseline for one service in one network location. A target must be
/// reread after a network or configuration conflict; it never follows a new service.
public struct DNSEditTarget: Sendable, Equatable {
    public var locationID: String
    public var serviceID: String
    public var serviceName: String
    public var interfaceName: String
    public var manualServers: [String]
    public var configurationToken: Data

    public init(
        locationID: String, serviceID: String, serviceName: String, interfaceName: String,
        manualServers: [String], configurationToken: Data = Data()
    ) {
        self.locationID = locationID
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.interfaceName = interfaceName
        self.manualServers = manualServers
        self.configurationToken = configurationToken
    }
}

public struct DNSChangeRequest: Sendable, Equatable {
    public var target: DNSEditTarget
    public var mode: DNSManualMode
    public init(target: DNSEditTarget, mode: DNSManualMode) {
        self.target = target
        self.mode = mode
    }
}

public struct DNSWriteResult: Sendable, Equatable {
    public var target: DNSEditTarget
    public var state: DNSState
    public var didChange: Bool
    public init(target: DNSEditTarget, state: DNSState, didChange: Bool = true) {
        self.target = target
        self.state = state
        self.didChange = didChange
    }
}

public struct DNSChangeError: LocalizedError, Sendable, Equatable {
    public enum Code: String, Sendable {
        case invalidAddress, emptyAddresses, invalidTarget, noPhysicalService, conflict
        case permissionDenied, authorizationCancelled, busy, unavailable, writeFailed, applyFailed, verificationFailed, externalWriter
    }
    public enum Persistence: String, Sendable {
        case unchanged, saved, unknown
    }
    public var code: Code
    public var persistence: Persistence
    public var currentManualServers: [String]?
    public var message: String
    public var isConflict: Bool { code == .conflict || code == .invalidTarget }
    public var errorDescription: String? { message }

    public init(code: Code, persistence: Persistence = .unchanged, currentManualServers: [String]? = nil, message: String) {
        self.code = code
        self.persistence = persistence
        self.currentManualServers = currentManualServers
        self.message = message
    }
}

/// Strict IP-literal validation. Pure Foundation so both Wi-Fi rule drafts and
/// the writer validate the same input without DNS queries or platform APIs.
public enum DNSAddressList {
    public static func parse(_ text: String) throws -> [String] {
        try validated(text.split { $0.isWhitespace || ",，;；".contains($0) }.map(String.init))
    }

    public static func validated(_ addresses: [String]) throws -> [String] {
        guard !addresses.isEmpty else {
            throw DNSChangeError(code: .emptyAddresses, message: "Enter at least one IPv4 or IPv6 address.")
        }
        var seen = Set<Data>()
        return try addresses.compactMap { address in
            guard let bytes = ipBytes(address) else {
                throw DNSChangeError(code: .invalidAddress, message: "“\(address)” is not an IPv4 or IPv6 address. Do not include a URL, port, or scope suffix.")
            }
            return seen.insert(Data(bytes)).inserted ? address : nil
        }
    }

    /// Compares valid address lists by their bytes, preserving DNS priority while
    /// ignoring duplicate entries and equivalent IPv6 spellings.
    public static func equivalent(_ lhs: [String], _ rhs: [String]) -> Bool {
        func keys(_ addresses: [String]) -> [Data]? {
            var seen = Set<Data>()
            var result: [Data] = []
            for address in addresses {
                guard let bytes = ipBytes(address) else { return nil }
                let key = Data(bytes)
                if seen.insert(key).inserted { result.append(key) }
            }
            return result
        }
        guard let left = keys(lhs), let right = keys(rhs) else { return false }
        return left == right
    }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                part.count == 1 || part.first != "0", let octet = UInt8(part)
            else { return nil }
            result.append(octet)
        }
        return result
    }

    private static func ipBytes(_ value: String) -> [UInt8]? {
        guard !value.isEmpty,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 || $0 == 58
            })
        else { return nil }
        if !value.contains(":") { return ipv4Bytes(value).map { [4] + $0 } }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func words(_ half: String, allowsIPv4: Bool) -> [UInt16]? {
            if half.isEmpty { return [] }
            let parts = half.split(separator: ":", omittingEmptySubsequences: false)
            var result: [UInt16] = []
            for (index, part) in parts.enumerated() {
                if part.contains(".") {
                    guard allowsIPv4, index == parts.count - 1, let bytes = ipv4Bytes(String(part)) else { return nil }
                    result += [UInt16(bytes[0]) << 8 | UInt16(bytes[1]), UInt16(bytes[2]) << 8 | UInt16(bytes[3])]
                } else {
                    guard !part.isEmpty, part.utf8.count <= 4, let word = UInt16(part, radix: 16) else { return nil }
                    result.append(word)
                }
            }
            return result
        }
        guard let left = words(halves[0], allowsIPv4: halves.count == 1),
            let right = halves.count == 2 ? words(halves[1], allowsIPv4: true) : []
        else { return nil }
        let count = left.count + right.count
        guard halves.count == 2 ? count < 8 : count == 8 else { return nil }
        let expanded = left + Array(repeating: UInt16(0), count: 8 - count) + right
        return [6] + expanded.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
    }
}
