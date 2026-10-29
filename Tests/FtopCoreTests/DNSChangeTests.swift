import Foundation
import Testing

@testable import FtopCore

@Suite struct DNSAddressListTests {
    @Test func acceptsMixedLiteralsAndInputSeparators() throws {
        #expect(
            try DNSAddressList.parse("114.114.114.114，2001:db8::53; ::ffff:192.0.2.53\n1.1.1.1") == ["114.114.114.114", "2001:db8::53", "::ffff:192.0.2.53", "1.1.1.1"])
    }

    @Test func deduplicatesEquivalentIPv6SpellingAndKeepsOrder() throws {
        #expect(try DNSAddressList.parse("2001:db8::53 2001:0db8:0:0:0:0:0:0053 1.1.1.1 1.1.1.1") == ["2001:db8::53", "1.1.1.1"])
    }

    @Test(arguments: [
        "resolver.example", "https://1.1.1.1", "1.1.1.1:53", "[2001:db8::53]:53", "fe80::1%en0", "1.1.1.1\0ignored",
        "256.1.1.1", "01.1.1.1", "1.1.1", "1..1.1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", ":::1",
        "1:2:3:4:5:6:7:8::", "12345::1", "::ffff:192.168.01.1", "192.0.2.1::", " ::1", "::1 ",
    ])
    func rejectsNonLiteralsAndMalformedAddresses(_ value: String) {
        #expect(throws: DNSChangeError.self) { try DNSAddressList.validated([value]) }
    }

    @Test func emptyCustomListIsRejected() {
        #expect(throws: DNSChangeError.self) { try DNSAddressList.parse(" ;, \n") }
    }

    @Test(arguments: ["::", "::1", "1::", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:192.0.2.53", "2001:db8::192.0.2.53", "0.0.0.0", "255.255.255.255"])
    func acceptsFullLiteralForms(_ value: String) throws {
        #expect(try DNSAddressList.validated([value]) == [value])
    }
}
