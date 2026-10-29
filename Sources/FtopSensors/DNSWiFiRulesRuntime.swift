import Foundation
import FtopCore

public struct DNSWiFiRulesObservation: Sendable, Equatable {
    public var target: DNSEditTarget
    public var connectionID: Data
    public var configurationFingerprint: Data
    public var hasManualAddressKey: Bool
}

/// Synchronous native calls cannot be cancelled midway. This latch invalidates
/// every remaining pre-commit checkpoint before an actor message can run.
final class DNSWiFiRulesCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var armed = false

    func invalidate() {
        lock.withLock {
            revision &+= 1
            armed = false
        }
    }

    func current() -> UInt64 { lock.withLock { revision } }

    func arm(_ expected: UInt64) throws {
        try lock.withLock {
            guard revision == expected else { throw stopped() }
            armed = true
        }
    }

    func check(_ expected: UInt64, requiresArmed: Bool = true) throws {
        guard
            lock.withLock({
                revision == expected && (!requiresArmed || armed)
            })
        else { throw stopped() }
    }

    private func stopped() -> DNSChangeError {
        DNSChangeError(
            code: .conflict,
            message:
                "Automatic DNS stopped or its rules changed before the transaction completed."
        )
    }
}

/// One retained native authorization session and serialized event-driven writes.
/// It never polls and never reads or modifies proxy software.
public actor DNSWiFiRulesRuntime {
    private var backend: (any DNSWiFiRulesWriteBackend)?
    private let cancellation = DNSWiFiRulesCancellation()
    private let makeBackend: @Sendable () throws -> any DNSWiFiRulesWriteBackend
    private let readWiFi: @Sendable (DNSWiFiPermission) -> DNSWiFiReading

    public init() {
        makeBackend = { try DNSNativeBackend() }
        readWiFi = DNSWiFiReader.read
    }

    init(
        makeBackend: @escaping @Sendable () throws -> any DNSWiFiRulesWriteBackend,
        readWiFi: @escaping @Sendable (DNSWiFiPermission) -> DNSWiFiReading
    ) {
        self.makeBackend = makeBackend
        self.readWiFi = readWiFi
    }

    public nonisolated func requestStop() { cancellation.invalidate() }
    public nonisolated func operationRevision() -> UInt64 {
        cancellation.current()
    }

    public func hasAuthorizedSession() -> Bool { backend != nil }

    /// Called from a persisted enabled intent or an explicit Save & Apply action.
    /// The system may present its native administrator authorization sheet.
    public func authorize(expectedRevision: UInt64? = nil) throws {
        backend = nil
        let revision = expectedRevision ?? cancellation.current()
        let session = try makeBackend()
        try cancellation.check(revision, requiresArmed: false)
        try session.authorizeAutomationSession()
        try cancellation.arm(revision)
        backend = session
    }

    public func pause() {
        cancellation.invalidate()
        backend = nil
    }

    public func observation() throws -> DNSWiFiRulesObservation {
        try Self.observation(makeBackend().current())
    }

    /// A post-write result becomes a baseline only if a fresh preferences session
    /// still sees the exact verified service and complete DNS dictionary.
    public func observation(
        confirming target: DNSEditTarget
    ) throws -> DNSWiFiRulesObservation {
        let verified = try DNSConfigurationSnapshot.decode(target)
        let current = try makeBackend().current()
        guard current.locationID == verified.locationID,
            current.serviceID == verified.serviceID,
            current.interfaceName == verified.interfaceName,
            try Self.configurationFingerprint(current)
                == Self.configurationFingerprint(verified)
        else {
            throw DNSChangeError(
                code: .externalWriter, persistence: .unknown,
                currentManualServers: try? current.manualServers,
                message:
                    "The service or its DNS configuration changed after verification. Automatic writes stopped without adopting those values."
            )
        }
        return try Self.observation(current)
    }

    public func apply(
        mode: DNSManualMode, expectedSSID: String,
        permission: DNSWiFiPermission,
        expected: DNSWiFiRulesObservation
    ) throws -> DNSWriteResult {
        guard let backend else {
            throw DNSChangeError(
                code: .permissionDenied,
                message: "Authorize automatic DNS for this app session."
            )
        }
        let revision = cancellation.current()
        try cancellation.check(revision)
        try backend.authorize()
        let reading = readWiFi(permission)
        guard reading.connected, reading.ssid == expectedSSID,
            reading.interfaceName == expected.target.interfaceName
        else {
            throw DNSChangeError(
                code: .conflict,
                message:
                    "The Wi-Fi connection changed before its DNS rule could be applied."
            )
        }

        let cancellation = self.cancellation
        let readWiFi = self.readWiFi
        let target = expected.target
        backend.beforeMutationCheck = {
            try cancellation.check(revision)
            let fresh = readWiFi(permission)
            guard fresh.connected, fresh.ssid == expectedSSID,
                fresh.interfaceName == target.interfaceName
            else {
                throw DNSChangeError(
                    code: .conflict,
                    message: "Wi-Fi changed immediately before saving DNS."
                )
            }
        }
        defer { backend.beforeMutationCheck = nil }

        let result = try DNSChangeTransaction.save(
            DNSChangeRequest(target: target, mode: mode), backend: backend)
        do {
            try backend.beforeMutationCheck?()
        } catch {
            throw DNSChangeError(
                code: .conflict,
                persistence: result.didChange ? .saved : .unchanged,
                currentManualServers: result.target.manualServers,
                message:
                    "DNS finished saving, but the Wi-Fi connection changed. The result was not written again."
            )
        }
        return result
    }

    private static func observation(
        _ value: DNSConfigurationSnapshot
    ) throws -> DNSWiFiRulesObservation {
        var connection = value.network
        connection.removeValue(forKey: "dns")
        connection.removeValue(forKey: "globalIPv4")
        connection.removeValue(forKey: "globalIPv6")
        connection["location"] = value.locationID
        connection["service"] = value.serviceID
        connection["interface"] = value.interfaceName
        return DNSWiFiRulesObservation(
            target: try value.target(),
            connectionID: try DNSWiFiRulesFingerprint.data(connection),
            configurationFingerprint: try configurationFingerprint(value),
            hasManualAddressKey: value.configuration?["ServerAddresses"] != nil)
    }

    private static func configurationFingerprint(
        _ value: DNSConfigurationSnapshot
    ) throws -> Data {
        try DNSWiFiRulesFingerprint.data(
            [
                "protocolExists": value.protocolExists,
                "protocolEnabled": value.protocolEnabled,
                "hasConfiguration": value.configuration != nil,
                "configuration": value.configuration ?? [:],
            ] as [String: Any])
    }
}

/// Stable property-list encoding. Dictionary order cannot look like an external
/// DNS edit.
enum DNSWiFiRulesFingerprint {
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: canonical(value),
            options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func canonical(_ value: Any) throws -> Any {
        switch value {
        case let string as String: ["string": string]
        case let number as NSNumber: ["number": number]
        case let data as Data: ["data": data.base64EncodedString()]
        case let date as Date: ["date": date.timeIntervalSinceReferenceDate]
        case let array as [Any]: ["array": try array.map(canonical)]
        case let dictionary as [String: Any]:
            ["dictionary": try dictionary.mapValues(canonical)]
        default:
            throw DNSChangeError(
                code: .unavailable,
                message:
                    "The network configuration cannot be compared safely."
            )
        }
    }
}
