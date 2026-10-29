import Foundation
import Testing

@testable import FtopCore

@Suite struct DNSStateTests {
    @Test func stateRoundTripsWithoutLosingIPv6OrReferenceSource() throws {
        let service = DNSServiceDetails(
            id: "wired", name: "Ethernet", interfaceName: "en5", kind: .ethernet,
            manualServers: ["1.1.1.1"], providedServers: ["2001:db8::53"])
        let original = DNSState(
            servers: ["2001:db8::53"], source: .serviceReference,
            primaryInterface: "en5", primaryServiceID: "wired", primaryIPv6Interface: "utun4", primaryIPv6ServiceID: "vpn",
            referenceServiceID: "wired", services: [service])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSState.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.referenceService == service)
        #expect(decoded.primaryServiceName == "Ethernet")
    }

    @Test func missingPrimaryServiceHasNoInventedName() {
        let state = DNSState(primaryServiceID: "not-reported", services: [DNSServiceDetails(id: "another", name: "Ethernet")])
        #expect(state.primaryServiceName == nil)
        #expect(state.referenceService == nil)
        #expect(state.source == .unavailable)
        #expect(state.servers.isEmpty)
    }

    @Test func ipv6PrimaryServiceCanSupplyItsName() {
        let state = DNSState(primaryIPv6ServiceID: "v6", services: [DNSServiceDetails(id: "v6", name: "IPv6 service")])
        #expect(state.primaryServiceName == "IPv6 service")
    }
}
