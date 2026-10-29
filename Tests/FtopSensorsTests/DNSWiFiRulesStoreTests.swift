import Foundation
import FtopCore
import Testing

@testable import FtopSensors

@Suite struct DNSWiFiRulesStoreTests {
    @Test func firstLoadIsInertAndDoesNotWrite() throws {
        try fixture { defaults, key, store in
            let loaded = try store.load()
            #expect(loaded == .defaults)
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test func validRulesRoundTrip() throws {
        try fixture { defaults, key, store in
            let configuration = DNSWiFiRulesConfiguration(
                enabled: true,
                defaultMode: .custom(["9.9.9.9", "149.112.112.112"]),
                rules: [
                    .init(
                        ssid: "Home",
                        mode: .custom(["1.1.1.1", "2001:db8::53"]))
                ])
            try store.save(configuration)
            #expect(defaults.data(forKey: key) != nil)
            #expect(try store.load() == configuration)
        }
    }

    @Test func versionOneDataMigratesToANonRemovableAutomaticDefault() throws {
        try fixture { defaults, key, store in
            defaults.set(
                Data(
                    "{\"version\":1,\"enabled\":true,\"rules\":[]}".utf8),
                forKey: key)
            let loaded = try store.load()
            #expect(loaded.enabled)
            #expect(loaded.defaultMode == .automatic)
            #expect(loaded.match(forSSID: "New Wi-Fi")?.usesDefault == true)
        }
    }

    @Test func invalidSaveAndDamagedDataPreservePreviousBytes() throws {
        try fixture { defaults, key, store in
            let original = DNSWiFiRulesConfiguration(
                rules: [.init(ssid: "Home", mode: .automatic)])
            try store.save(original)
            let previous = defaults.data(forKey: key)
            #expect(throws: DNSWiFiRulesValidationError.self) {
                try store.save(
                    .init(rules: [
                        .init(ssid: "Home", mode: .automatic),
                        .init(ssid: "Home", mode: .automatic),
                    ]))
            }
            #expect(defaults.data(forKey: key) == previous)

            let damaged = Data("not json".utf8)
            defaults.set(damaged, forKey: key)
            #expect(throws: DNSWiFiRulesStoreError.self) { try store.load() }
            #expect(defaults.data(forKey: key) == damaged)
        }
    }

    @Test func retiredAutomationKeyIsNeverReadOrMigrated() throws {
        let suite = "dev.ftop.tests.dns-wifi-rules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("legacy".utf8), forKey: "DNSAutomation.v1")
        let store = DNSWiFiRulesStore(defaults: defaults)
        #expect(try store.load() == .defaults)
        #expect(defaults.object(forKey: DNSWiFiRulesStore.defaultKey) == nil)
    }

    private func fixture(
        _ body: (UserDefaults, String, DNSWiFiRulesStore) throws -> Void
    ) throws {
        let suite = "dev.ftop.tests.dns-wifi-rules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "fixture.rules"
        try body(
            defaults, key,
            DNSWiFiRulesStore(defaults: defaults, key: key))
    }
}
