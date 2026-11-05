import Foundation
import Testing

@testable import FtopCore

@Suite struct DNSWiFiReassertionTests {
    private let configuration = DNSWiFiRulesConfiguration(defaultMode: .automatic)

    @Test func firstFiveOverridesReassertAndSixthDefersUntilNewConnection() {
        var policy = DNSWiFiRulePolicy()
        let target = context()
        let external = context(servers: ["8.8.8.8"], fingerprint: 1)
        #expect(isUnchanged(policy.decide(at: 0, configuration: configuration, context: target)))
        for index in 1...6 {
            let decision = policy.decide(at: Double(index), configuration: configuration, context: external)
            #expect(policy.externalChangeCount == index)
            if index <= 5 {
                #expect(isApply(decision))
                policy.recordApplied(context: target)
            } else {
                #expect(decision == .blocked(.externalConfigurationChange))
            }
        }
        // Waiting or passing time does not restart a connection already yielded.
        #expect(policy.decide(at: 100, configuration: configuration, context: external) == .blocked(.externalConfigurationChange))
        #expect(policy.decide(at: 100, configuration: configuration, context: DNSWiFiRuleContext(network: .unknownSSID)) == .waiting(.unknownSSID))
        #expect(policy.decide(at: 101, configuration: configuration, context: external) == .blocked(.externalConfigurationChange))
        #expect(isApply(policy.decide(at: 102, configuration: configuration, context: context(connection: 2, servers: ["8.8.8.8"], fingerprint: 1))))
        #expect(policy.externalChangeCount == 0)
    }

    @Test func rollingWindowExpiresOldEventsAtSixtySeconds() {
        var policy = DNSWiFiRulePolicy()
        let target = context()
        let external = context(servers: ["8.8.8.8"], fingerprint: 1)
        _ = policy.decide(at: 0, configuration: configuration, context: target)
        for index in 0..<5 {
            #expect(isApply(policy.decide(at: Double(index), configuration: configuration, context: external)))
            policy.recordApplied(context: target)
        }
        #expect(policy.externalChangeCount == 5)
        #expect(isApply(policy.decide(at: 60, configuration: configuration, context: external)))
        #expect(policy.externalChangeCount == 5)
        policy.recordApplied(context: target)
        #expect(isApply(policy.decide(at: 121, configuration: configuration, context: external)))
        #expect(policy.externalChangeCount == 1)
    }

    @Test func repeatedNotificationsAndOwnWritesDoNotUseTheBudget() {
        var policy = DNSWiFiRulePolicy()
        let target = context()
        let external = context(servers: ["8.8.8.8"], fingerprint: 1)
        _ = policy.decide(at: 0, configuration: configuration, context: target)
        for _ in 0..<20 {
            #expect(isApply(policy.decide(at: 1, configuration: configuration, context: external)))
        }
        #expect(policy.externalChangeCount == 1)
        policy.recordApplied(context: target)
        for index in 2...20 {
            #expect(isUnchanged(policy.decide(at: Double(index), configuration: configuration, context: target)))
        }
        #expect(policy.externalChangeCount == 1)
        #expect(isApply(policy.decide(at: 21, configuration: configuration, context: external)))
        #expect(policy.externalChangeCount == 2)
    }

    @Test func unrelatedConfigurationChangesNeverCountEvenOnAMismatch() {
        for addresses in [[], ["8.8.8.8"]] {
            var policy = DNSWiFiRulePolicy()
            for fingerprint in UInt8(0)..<20 {
                let reading = context(servers: addresses, fingerprint: fingerprint)
                let decision = policy.decide(at: Double(fingerprint), configuration: configuration, context: reading)
                #expect(addresses.isEmpty ? isUnchanged(decision) : isApply(decision))
            }
            #expect(policy.externalChangeCount == 0)
        }
    }

    @Test func automaticEmptyKeyReintroductionsCountAndResetClearsBudget() {
        var policy = DNSWiFiRulePolicy()
        let target = context()
        var emptyKey = context(fingerprint: 1)
        emptyKey.hasManualAddressKey = true
        _ = policy.decide(at: 0, configuration: configuration, context: target)
        for index in 1...6 {
            let decision = policy.decide(at: Double(index), configuration: configuration, context: emptyKey)
            if index <= 5 {
                #expect(isApply(decision))
                policy.recordApplied(context: target)
            } else {
                #expect(decision == .blocked(.externalConfigurationChange))
            }
        }
        policy.reset()
        #expect(isApply(policy.decide(at: 7, configuration: configuration, context: emptyKey)))
        #expect(policy.externalChangeCount == 0)
    }

    @Test func equivalentCustomAddressesDoNotCountButPriorityChangesDo() {
        var policy = DNSWiFiRulePolicy()
        let configuration = DNSWiFiRulesConfiguration(defaultMode: .custom(["2001:db8::53", "1.1.1.1"]))
        let target = context(servers: ["2001:db8::53", "1.1.1.1"])
        _ = policy.decide(at: 0, configuration: configuration, context: target)
        #expect(isUnchanged(policy.decide(at: 1, configuration: configuration, context: context(servers: ["2001:0db8::53", "1.1.1.1", "1.1.1.1"], fingerprint: 1))))
        #expect(policy.externalChangeCount == 0)
        #expect(isApply(policy.decide(at: 2, configuration: configuration, context: context(servers: ["1.1.1.1", "2001:db8::53"], fingerprint: 2))))
        #expect(policy.externalChangeCount == 1)
    }

    @Test func failedWritesStillBlockWithoutSpendingAllFiveAttempts() {
        var policy = DNSWiFiRulePolicy()
        let external = context(servers: ["8.8.8.8"], fingerprint: 1)
        _ = policy.decide(at: 0, configuration: configuration, context: context())
        _ = policy.decide(at: 1, configuration: configuration, context: external)
        policy.recordFailure(context: external)
        #expect(policy.decide(at: 2, configuration: configuration, context: external) == .blocked(.writeFailed))
        #expect(policy.externalChangeCount == 1)
        _ = policy.decide(at: 3, configuration: configuration, context: DNSWiFiRuleContext(network: .disconnected))
        #expect(isApply(policy.decide(at: 4, configuration: configuration, context: external)))
        #expect(policy.externalChangeCount == 0)
    }

    private func context(connection: UInt8 = 1, servers: [String] = [], fingerprint: UInt8 = 0) -> DNSWiFiRuleContext {
        DNSWiFiRuleContext(
            network: .wifi(ssid: "Other", locationID: "location", serviceID: "wifi", connectionID: Data([connection])),
            manualServers: servers, hasManualAddressKey: !servers.isEmpty, dnsFingerprint: Data([fingerprint]))
    }
    private func isApply(_ decision: DNSWiFiRuleDecision) -> Bool {
        if case .apply = decision { return true }; return false
    }
    private func isUnchanged(_ decision: DNSWiFiRuleDecision) -> Bool {
        if case .unchanged = decision { return true }; return false
    }
}
