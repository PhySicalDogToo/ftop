import Testing

@testable import FtopSensors

@Suite struct DNSWiFiTests {
    @Test func missingPermissionNeverUsesAName() {
        for permission in [
            DNSWiFiPermission.notDetermined, .denied, .restricted,
        ] {
            let value = DNSWiFiReader.selected(
                ssid: "Office", interfaceName: "en0", connected: true,
                permission: permission)
            #expect(value.ssid == nil && !value.connected)
            #expect(!value.connectionKnown)
        }
    }

    @Test func unavailableNamesStayUnknownOnConnectedWiFi() {
        for name in [nil, "", "<redacted>"] {
            let value = DNSWiFiReader.selected(
                ssid: name, interfaceName: "en0", connected: true,
                permission: .authorized)
            #expect(value.connected && value.ssid == nil)
            #expect(value.connectionKnown)
        }
    }

    @Test func exactSSIDInterfaceAndAccessPointArePreserved() {
        let value = DNSWiFiReader.selected(
            ssid: " Home ", bssid: "00:11:22:33:44:55",
            interfaceName: "en7", connected: true,
            permission: .authorized)
        #expect(value.ssid == " Home " && value.interfaceName == "en7")
        #expect(value.bssid == "00:11:22:33:44:55")
    }

    @Test func uncertainAssociationCannotConfirmADisconnect() {
        let unknown = DNSWiFiReader.selected(
            ssid: "Home", interfaceName: nil, connected: true,
            permission: .authorized)
        #expect(!unknown.connected && !unknown.connectionKnown)
        let disconnected = DNSWiFiReader.selected(
            ssid: nil, interfaceName: "en0", connected: false,
            permission: .authorized)
        #expect(!disconnected.connected && disconnected.connectionKnown)
    }
}
