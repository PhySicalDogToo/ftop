import AppKit
import FtopCore
import Testing

@testable import FtopUI

@MainActor
@Suite struct DNSDetailsTests {
    @Test func dnsRowFitsOpensRulesDirectlyAndWritesNothing() throws {
        let oldLanguage = Strings.language
        defer { Strings.language = oldLanguage }
        let dns = DNSState(
            servers: ["114.114.114.114", "2001:4860:4860::8888"],
            source: .systemDefault)

        for language in [Language.en, .zh] {
            Strings.language = language
            let face = ControlFace(
                state: .init(config: Config(), dns: dns))
            let closed = face.fittingSize
            #expect(face.dnsRowFrame == nil)
            face.expand()
            face.frame = NSRect(origin: .zero, size: face.fittingSize)
            let row = try #require(face.dnsRowFrame)
            #expect(face.bounds.contains(row))
            #expect(face.hasDNSToolTip)
            #expect(
                face.fittingSize.height
                    == closed.height + PanelStyle.controlListRow * 8
                    + PanelStyle.controlListGap)

            let title = Strings.pick("Wi-Fi DNS rules", "Wi-Fi DNS 规则")
            let value = Strings.pick("Open…", "打开…") + "  ›"
            let titleWidth = (title as NSString).size(
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: PanelStyle.controlTitleSize,
                        weight: .medium)
                ]).width
            let valueWidth = (value as NSString).size(
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: PanelStyle.controlValueSize)
                ]).width
            #expect(
                titleWidth + valueWidth
                    < row.width - PanelStyle.controlPadding * 2)

            var actions: [ControlFace.Action] = []
            var writes = 0
            face.onAction = { actions.append($0) }
            face.onChange = { _, _, _ in writes += 1 }
            #expect(
                face.activate(at: CGPoint(x: row.midX, y: row.midY)))
            #expect(actions == [.configureDNSRules])
            #expect(writes == 0)
            #expect(face.dnsTooltipText.contains("114.114.114.114"))
            #expect(face.dnsTooltipText.contains("2001:4860:4860::8888"))
            #expect(
                face.dnsTooltipText.contains(
                    Strings.pick(
                        "Source: System default", "来源：系统默认")))
            face.collapse()
            #expect(face.dnsRowFrame == nil)
            #expect(!face.hasDNSToolTip)
            #expect(face.fittingSize == closed)
        }
    }

    @Test func tooltipKeepsFullAddressesAndSanitizesControlCharacters() {
        let oldLanguage = Strings.language
        Strings.language = .en
        defer { Strings.language = oldLanguage }
        let ipv6 = "2001:4860:4860:0000:0000:0000:0000:8888"
        let tooltip = DNSDetails.tooltip(
            DNSState(
                servers: ["114.114.114.114", ipv6],
                source: .serviceReference,
                unavailableReason: "ignored\ntext"))
        #expect(tooltip.contains("Current system DNS"))
        #expect(tooltip.contains("114.114.114.114"))
        #expect(tooltip.contains(ipv6))
        #expect(
            tooltip.contains(
                "Source: Service reference; system default unavailable"))
        #expect(!tooltip.contains("ignored"))

        let unavailable = DNSDetails.tooltip(
            DNSState(unavailableReason: "System\nDNS\tunavailable"))
        #expect(unavailable.contains("Unavailable"))
        #expect(unavailable.contains("Reason: System DNS unavailable"))
        #expect(!unavailable.contains("\t"))
    }
}
