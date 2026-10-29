import Foundation
import Testing

@testable import FtopCore

@Suite struct DNSWiFiRulesTests {
    @Test func defaultRuleAlwaysExistsButFirstLaunchIsInert() {
        #expect(!DNSWiFiRulesConfiguration.defaults.enabled)
        #expect(DNSWiFiRulesConfiguration.defaults.defaultMode == .automatic)
        #expect(DNSWiFiRulesConfiguration.defaults.rules.isEmpty)
        #expect(DNSWiFiRulesConfiguration.defaults.rule(forSSID: "Home") == nil)
        #expect(
            DNSWiFiRulesConfiguration.defaults.match(forSSID: "Home")
                == DNSWiFiRuleMatch(
                    source: .defaultRule, mode: .automatic))
    }

    @Test func exactNamesAndNormalizedAddressListsArePreserved() throws {
        let value = try DNSWiFiRulesConfiguration(
            defaultMode: .custom(["9.9.9.9", "149.112.112.112"]),
            rules: [
                .init(
                    ssid: " Home ",
                    mode: .custom([
                        "2001:db8::53", "2001:0db8:0:0:0:0:0:0053",
                        "1.1.1.1", "1.1.1.1",
                    ])),
                .init(ssid: "home", mode: .automatic),
            ]
        ).validated()
        #expect(value.rule(forSSID: " Home ")?.ssid == " Home ")
        #expect(value.rule(forSSID: "HOME") == nil)
        #expect(value.match(forSSID: " Home ")?.source == .exact(" Home "))
        #expect(
            value.match(forSSID: "Other")
                == DNSWiFiRuleMatch(
                    source: .defaultRule,
                    mode: .custom(["9.9.9.9", "149.112.112.112"])))
        #expect(
            value.rules.first?.mode
                == .custom(["2001:db8::53", "1.1.1.1"]))
    }

    @Test func invalidOrDuplicateRulesAreRejected() {
        #expect(throws: DNSWiFiRulesValidationError.self) {
            try DNSWiFiRulesConfiguration(
                rules: [.init(ssid: "", mode: .automatic)]).validated()
        }
        #expect(throws: DNSWiFiRulesValidationError.self) {
            try DNSWiFiRulesConfiguration(
                rules: [.init(ssid: "Bad\nName", mode: .automatic)]).validated()
        }
        #expect(throws: DNSWiFiRulesValidationError.self) {
            try DNSWiFiRulesConfiguration(
                rules: [
                    .init(ssid: "Home", mode: .automatic),
                    .init(ssid: "Home", mode: .custom(["1.1.1.1"])),
                ]).validated()
        }
        #expect(throws: DNSChangeError.self) {
            try DNSWiFiRulesConfiguration(
                defaultMode: .custom(["dns.example"])
            ).validated()
        }
        #expect(throws: DNSChangeError.self) {
            try DNSWiFiRulesConfiguration(
                rules: [
                    .init(ssid: "Home", mode: .custom(["dns.example"]))
                ]).validated()
        }
    }

    @Test func configurationRoundTripsAndRejectsUnknownVersions() throws {
        let value = DNSWiFiRulesConfiguration(
            enabled: false,
            defaultMode: .custom(["9.9.9.9", "149.112.112.112"]),
            rules: [.init(ssid: "Office", mode: .custom(["1.1.1.1"]))])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(DNSWiFiRulesConfiguration.self, from: data) == value)
        #expect(throws: DNSWiFiRulesValidationError.self) {
            try JSONDecoder().decode(
                DNSWiFiRulesConfiguration.self,
                from: Data("{\"version\":99,\"enabled\":true,\"rules\":[]}".utf8))
        }
        let legacy = try JSONDecoder().decode(
            DNSWiFiRulesConfiguration.self,
            from: Data(
                "{\"version\":1,\"enabled\":true,\"rules\":[]}".utf8))
        #expect(legacy.enabled)
        #expect(legacy.defaultMode == .automatic)
    }

    @Test func unmatchedWiFiUsesDefaultAndDisabledConfigurationDoesNotApply() {
        var policy = DNSWiFiRulePolicy()
        let configuration = fixture()
        guard
            case .apply(let fallback) = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Other", servers: ["8.8.8.8"], fingerprint: 1))
        else {
            Issue.record("An unmatched Wi-Fi must use the default rule")
            return
        }
        #expect(fallback.source == .defaultRule)
        #expect(fallback.mode == .automatic)
        policy.reset()
        guard
            case .unchanged(let alreadyAutomatic) = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Other", servers: [], hasKey: false,
                    fingerprint: 1))
        else {
            Issue.record("An already automatic fallback must not write")
            return
        }
        #expect(alreadyAutomatic.source == .defaultRule)
        var disabled = configuration
        disabled.enabled = false
        #expect(
            policy.decide(
                configuration: disabled,
                context: context(ssid: "Home", fingerprint: 1)) == .off)
    }

    @Test func firstMismatchAppliesAndVerifiedMatchBecomesStable() throws {
        var policy = DNSWiFiRulePolicy()
        let configuration = fixture()
        let before = context(
            ssid: "Home", servers: ["9.9.9.9"], fingerprint: 1)
        guard
            case .apply(let rule) = policy.decide(
                configuration: configuration, context: before)
        else {
            Issue.record("Expected the first mismatched rule to apply")
            return
        }
        #expect(rule.source == .exact("Home"))
        #expect(rule.mode == .custom(["1.1.1.1", "2001:db8::53"]))

        let after = context(
            ssid: "Home", servers: ["1.1.1.1", "2001:0db8::53"],
            fingerprint: 2)
        policy.recordApplied(context: after)
        guard
            case .unchanged = policy.decide(
                configuration: configuration, context: after)
        else {
            Issue.record("Expected the verified rule to remain unchanged")
            return
        }
    }

    @Test func automaticRequiresTheManualAddressKeyToBeAbsent() {
        var policy = DNSWiFiRulePolicy()
        let configuration = DNSWiFiRulesConfiguration(
            rules: [.init(ssid: "Office", mode: .automatic)])
        guard
            case .apply = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Office", servers: [], hasKey: true,
                    fingerprint: 1))
        else {
            Issue.record("An empty saved key still needs deletion")
            return
        }
        policy.reset()
        guard
            case .unchanged = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Office", servers: [], hasKey: false,
                    fingerprint: 1))
        else {
            Issue.record("An absent key is already automatic")
            return
        }
    }

    @Test func externalChangeAndFailedWriteBlockOnlyThatAssociation() {
        var policy = DNSWiFiRulePolicy()
        let configuration = fixture()
        let original = context(
            ssid: "Home", servers: ["9.9.9.9"], fingerprint: 1)
        _ = policy.decide(configuration: configuration, context: original)
        guard
            case .blocked(.externalConfigurationChange) = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Home", servers: ["8.8.8.8"], fingerprint: 2))
        else {
            Issue.record("External DNS must stop reassertion")
            return
        }

        policy.reset()
        _ = policy.decide(configuration: configuration, context: original)
        policy.recordFailure(context: original)
        guard
            case .blocked(.writeFailed) = policy.decide(
                configuration: configuration, context: original)
        else {
            Issue.record("A failed write must not retry")
            return
        }

        guard
            case .apply = policy.decide(
                configuration: configuration,
                context: context(
                    ssid: "Home", connection: 2, servers: ["9.9.9.9"],
                    fingerprint: 1))
        else {
            Issue.record("A new association is a new opportunity")
            return
        }
    }

    private func fixture() -> DNSWiFiRulesConfiguration {
        DNSWiFiRulesConfiguration(
            rules: [
                .init(
                    ssid: "Home",
                    mode: .custom(["1.1.1.1", "2001:db8::53"]))
            ])
    }

    private func context(
        ssid: String, connection: UInt8 = 1, servers: [String] = [],
        hasKey: Bool = true, fingerprint: UInt8
    ) -> DNSWiFiRuleContext {
        DNSWiFiRuleContext(
            network: .wifi(
                ssid: ssid, locationID: "location", serviceID: "wifi",
                connectionID: Data([connection])),
            manualServers: servers, hasManualAddressKey: hasKey,
            dnsFingerprint: Data([fingerprint]))
    }
}
