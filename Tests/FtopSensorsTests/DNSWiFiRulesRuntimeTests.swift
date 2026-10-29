import Foundation
import FtopCore
import Testing

@testable import FtopSensors

@Suite struct DNSWiFiRulesRuntimeTests {
    @Test func cancellationLatchInvalidatesArmedAndQueuedWork() throws {
        let latch = DNSWiFiRulesCancellation()
        let revision = latch.current()
        try latch.arm(revision)
        try latch.check(revision)
        latch.invalidate()
        #expect(throws: DNSChangeError.self) { try latch.check(revision) }
        #expect(throws: DNSChangeError.self) { try latch.check(latch.current()) }
    }

    @Test func fingerprintsIgnoreDictionaryOrderButIncludeEveryField() throws {
        let first: [String: Any] = [
            "ServerAddresses": ["1.1.1.1"],
            "SearchDomains": ["a.example"],
        ]
        let reordered: [String: Any] = [
            "SearchDomains": ["a.example"],
            "ServerAddresses": ["1.1.1.1"],
        ]
        let changed: [String: Any] = [
            "SearchDomains": ["b.example"],
            "ServerAddresses": ["1.1.1.1"],
        ]
        #expect(
            try DNSWiFiRulesFingerprint.data(first)
                == DNSWiFiRulesFingerprint.data(reordered))
        #expect(
            try DNSWiFiRulesFingerprint.data(first)
                != DNSWiFiRulesFingerprint.data(changed))
    }

    @Test func aFreshRuntimeCannotWriteBeforeAuthorization() async throws {
        let backend = DNSWiFiRulesFakeBackend()
        let runtime = makeRuntime(backend)
        let expected = try await runtime.observation()
        do {
            _ = try await runtime.apply(
                mode: .automatic, expectedSSID: "Office",
                permission: .authorized, expected: expected)
            Issue.record("An unauthorized runtime must not write")
        } catch let error as DNSChangeError {
            #expect(error.code == .permissionDenied)
        }
        #expect(backend.commitCount == 0)
        #expect(backend.interactiveAuthorizations == 0)
    }

    @Test func authorizationIsRetainedAndAWriteIsVerified() async throws {
        let backend = DNSWiFiRulesFakeBackend()
        let runtime = makeRuntime(backend)
        try await runtime.authorize()
        let expected = try await runtime.observation()
        let result = try await runtime.apply(
            mode: .custom(["1.1.1.1", "2001:db8::53"]),
            expectedSSID: "Office", permission: .authorized,
            expected: expected)
        #expect(result.target.manualServers == ["1.1.1.1", "2001:db8::53"])
        #expect(backend.interactiveAuthorizations == 1)
        #expect(backend.commitCount == 1)
        let confirmed = try await runtime.observation(confirming: result.target)
        #expect(confirmed.configurationFingerprint.count > 0)
        #expect(confirmed.hasManualAddressKey)
    }

    @Test func expiredBackgroundAuthorizationNeverPromptsAgain() async throws {
        let backend = DNSWiFiRulesFakeBackend()
        let runtime = makeRuntime(backend)
        try await runtime.authorize()
        backend.silentAuthorizationFails = true
        let expected = try await runtime.observation()
        do {
            _ = try await runtime.apply(
                mode: .automatic, expectedSSID: "Office",
                permission: .authorized, expected: expected)
            Issue.record("Expired authorization must block")
        } catch let error as DNSChangeError {
            #expect(error.code == .permissionDenied)
        }
        #expect(backend.interactiveAuthorizations == 1)
        #expect(backend.commitCount == 0)
    }

    @Test func serviceOrDNSChangesCannotInheritTheVerifiedBaseline() async throws {
        for field in ["servers", "search", "service", "interface", "location"] {
            let backend = DNSWiFiRulesFakeBackend()
            let runtime = makeRuntime(backend)
            try await runtime.authorize()
            let expected = try await runtime.observation()
            let result = try await runtime.apply(
                mode: .automatic, expectedSSID: "Office",
                permission: .authorized, expected: expected)
            switch field {
            case "servers":
                backend.snapshot.configuration?["ServerAddresses"] = ["8.8.8.8"]
            case "search":
                backend.snapshot.configuration?["SearchDomains"] = ["external.example"]
            case "service": backend.snapshot.serviceID = "other-service"
            case "interface": backend.snapshot.interfaceName = "en7"
            default: backend.snapshot.locationID = "other-location"
            }
            do {
                _ = try await runtime.observation(confirming: result.target)
                Issue.record("A changed value must not become our baseline")
            } catch let error as DNSChangeError {
                #expect(error.code == .externalWriter)
                #expect(error.persistence == .unknown)
            }
            #expect(backend.commitCount == 1)
        }
    }

    @Test func stopBetweenStageAndCommitPreventsPersistence() async throws {
        let backend = DNSWiFiRulesFakeBackend()
        let runtime = makeRuntime(backend)
        try await runtime.authorize()
        let expected = try await runtime.observation()
        backend.onStage = { runtime.requestStop() }
        do {
            _ = try await runtime.apply(
                mode: .automatic, expectedSSID: "Office",
                permission: .authorized, expected: expected)
            Issue.record("Stopping must invalidate the commit checkpoint")
        } catch let error as DNSChangeError {
            #expect(error.persistence == .unchanged)
        }
        #expect(backend.commitCount == 0)
    }

    @Test func changedSSIDOrPhysicalInterfaceCannotWrite() async throws {
        for reading in [
            DNSWiFiReading(
                interfaceName: "en0", connected: true,
                permission: .authorized),
            DNSWiFiReading(
                ssid: "Office", interfaceName: "en7", connected: true,
                permission: .authorized),
            DNSWiFiReading(
                ssid: "Other", interfaceName: "en0", connected: true,
                permission: .authorized),
        ] {
            let backend = DNSWiFiRulesFakeBackend()
            let runtime = makeRuntime(backend, reading: reading)
            try await runtime.authorize()
            let expected = try await runtime.observation()
            await #expect(throws: DNSChangeError.self) {
                try await runtime.apply(
                    mode: .automatic, expectedSSID: "Office",
                    permission: .authorized, expected: expected)
            }
            #expect(backend.commitCount == 0)
        }
    }

    private func makeRuntime(
        _ backend: DNSWiFiRulesFakeBackend,
        reading: DNSWiFiReading = DNSWiFiReading(
            ssid: "Office", bssid: "00:11:22:33:44:55",
            interfaceName: "en0", connected: true,
            permission: .authorized)
    ) -> DNSWiFiRulesRuntime {
        DNSWiFiRulesRuntime(
            makeBackend: { backend }, readWiFi: { _ in reading })
    }
}

private final class DNSWiFiRulesFakeBackend: DNSWiFiRulesWriteBackend,
    @unchecked Sendable
{
    var snapshot = DNSConfigurationSnapshot(
        locationID: "test-location", serviceID: "test-service",
        serviceName: "Wi-Fi", interfaceName: "en0",
        protocolExists: true, protocolEnabled: true,
        configuration: [
            "ServerAddresses": ["9.9.9.9"],
            "SearchDomains": ["example.test"],
        ],
        network: [
            "globalIPv4": ["PrimaryInterface": "en0"],
            "ipv4": ["Addresses": ["192.0.2.10"], "Router": "192.0.2.1"],
            "link": ["Active": true],
            "dns": ["ServerAddresses": ["9.9.9.9"]],
        ])
    private var persisted: DNSConfigurationSnapshot?
    var beforeMutationCheck: (() throws -> Void)?
    var silentAuthorizationFails = false
    var interactiveAuthorizations = 0
    var commitCount = 0
    var onStage: (() -> Void)?

    func current() throws -> DNSConfigurationSnapshot { snapshot }
    func externalWriterRunning() throws -> Bool { false }
    func authorizeAutomationSession() throws {
        interactiveAuthorizations += 1
    }
    func authorize() throws {
        if silentAuthorizationFails {
            throw DNSChangeError(
                code: .permissionDenied,
                message: "Fixture expired authorization")
        }
    }
    func lock() throws { try beforeMutationCheck?() }
    func unlock() {}
    func stage(
        _ configuration: [String: Any], createProtocol: Bool
    ) throws {
        try beforeMutationCheck?()
        snapshot.configuration = configuration
        snapshot.protocolExists = true
        snapshot.protocolEnabled = true
        onStage?()
    }
    func commit() throws {
        try beforeMutationCheck?()
        commitCount += 1
        persisted = snapshot
    }
    func apply() throws {}
    func reread(
        _ original: DNSConfigurationSnapshot
    ) throws -> DNSConfigurationSnapshot { persisted ?? original }
    func state() -> DNSState {
        DNSState(
            servers: (snapshot.configuration?["ServerAddresses"] as? [String]) ?? [],
            source: .systemDefault)
    }
}
