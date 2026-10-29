import FtopCore
import Testing

@testable import FtopSensors

@Suite struct DNSReaderTests {
    @Test func systemDefaultWinsOverManualAndServiceDNS() {
        let state = DNSSelection.state(
            globalServers: ["10.0.0.53", "2001:db8::53"], primaryInterface: "en0", primaryServiceID: "wifi",
            services: [
                DNSServiceDetails(
                    id: "wifi", name: "Wi-Fi", interfaceName: "en0", kind: .wifi,
                    manualServers: ["114.114.114.114"], providedServers: ["192.168.1.1"])
            ])
        #expect(state.source == .systemDefault)
        #expect(state.servers == ["10.0.0.53", "2001:db8::53"])
        #expect(state.referenceServiceID == nil)
        #expect(state.services[0].manualServers == ["114.114.114.114"])
        #expect(state.services[0].providedServers == ["192.168.1.1"])
    }

    @Test func wiredDNSDoesNotRequireAWiFiService() {
        let state = DNSSelection.state(
            globalServers: ["192.0.2.53"], primaryInterface: "en5", primaryServiceID: "wired",
            services: [DNSServiceDetails(id: "wired", name: "USB Ethernet", interfaceName: "en5", kind: .ethernet)])
        #expect(state.source == .systemDefault)
        #expect(state.primaryServiceName == "USB Ethernet")
        #expect(state.primaryInterface == "en5")
    }

    @Test func vpnDefaultAndPhysicalServiceRemainSeparate() {
        let state = DNSSelection.state(
            globalServers: ["10.64.0.1"], primaryInterface: "utun4", primaryServiceID: "vpn",
            services: [
                DNSServiceDetails(id: "wifi", name: "Wi-Fi", interfaceName: "en0", kind: .wifi, providedServers: ["192.168.1.1"]),
                DNSServiceDetails(id: "vpn", name: "Company VPN", interfaceName: "utun4", kind: .vpn, providedServers: ["10.64.0.1"]),
            ])
        #expect(state.servers == ["10.64.0.1"])
        #expect(state.primaryServiceName == "Company VPN")
        #expect(state.services[0].providedServers == ["192.168.1.1"])
    }

    @Test func globalDNSCanBeReadWithoutAnyConfiguredService() {
        let state = DNSSelection.state(globalServers: ["2001:db8::53"], primaryIPv6Interface: "utun3")
        #expect(state.source == .systemDefault)
        #expect(state.servers == ["2001:db8::53"])
        #expect(state.services.isEmpty)
    }

    @Test func missingGlobalUsesExplicitlyLabelledPrimaryServiceReference() {
        let state = DNSSelection.state(
            globalServers: [], primaryServiceID: "wired",
            services: [
                DNSServiceDetails(id: "wifi", providedServers: ["192.168.1.1"]),
                DNSServiceDetails(id: "wired", manualServers: ["1.1.1.1"], providedServers: ["192.0.2.53"]),
            ])
        #expect(state.source == .serviceReference)
        #expect(state.referenceServiceID == "wired")
        #expect(state.servers == ["192.0.2.53"])
    }

    @Test func primaryManualConfigurationIsOnlyAReference() {
        let state = DNSSelection.state(
            globalServers: [], primaryIPv6ServiceID: "v6", services: [DNSServiceDetails(id: "v6", manualServers: ["2001:db8::53"])])
        #expect(state.source == .serviceReference)
        #expect(state.servers == ["2001:db8::53"])
    }

    @Test func disconnectedManualServiceDoesNotInventADefaultResolver() {
        let state = DNSSelection.state(globalServers: [], services: [DNSServiceDetails(id: "inactive", manualServers: ["1.1.1.1"])])
        #expect(state.source == .unavailable)
        #expect(state.servers.isEmpty)
        #expect(state.unavailableReason != nil)
        #expect(state.services[0].manualServers == ["1.1.1.1"])
    }

    @Test func noNetworkReportsUnavailable() {
        let state = DNSSelection.state(globalServers: [])
        #expect(state.source == .unavailable)
        #expect(state.servers.isEmpty)
        #expect(state.primaryServiceID == nil)
        #expect(state.unavailableReason != nil)
    }

    @Test func addressesAreValidatedAndDeduplicatedWithoutDroppingIPv6Scopes() {
        let state = DNSSelection.state(
            globalServers: [
                " 192.0.2.53 ", "192.0.2.53", "2001:db8::53", "2001:0db8:0:0:0:0:0:53", "fe80::1%en0", "fe80::1%en5",
                "resolver.example", "https://192.0.2.53", "192.0.2.53:53", "1.1.1.1\0junk", "fe80::1%", "fe80::1%en0\ninvalid",
            ])
        #expect(state.servers == ["192.0.2.53", "2001:db8::53", "fe80::1%en0", "fe80::1%en5"])
    }

    @Test func invalidGlobalAddressesDoNotMasqueradeAsSystemDefault() {
        let state = DNSSelection.state(globalServers: ["unavailable"], services: [DNSServiceDetails(id: "wired", providedServers: ["192.0.2.53"])])
        #expect(state.source == .serviceReference)
        #expect(state.servers == ["192.0.2.53"])
    }
}
