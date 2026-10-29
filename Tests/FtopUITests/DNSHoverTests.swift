import AppKit
import FtopCore
import Testing

@testable import FtopUI

@MainActor
@Suite struct DNSHoverTests {
    @Test func shortHoverKeepsTheEstablishedHeight() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chip = ChipWindow.presentation("114.114.114.114", above: NSPoint(x: 700, y: 400), visibleFrame: visible)
        #expect(chip.text == "114.114.114.114")
        #expect(chip.frame.height == PanelStyle.chipMinHeight)
        #expect(chip.omittedLines == 0)
        #expect(chip.frame.size.width <= PanelStyle.chipMaxWidth)
        #expect(NSRect(origin: .zero, size: chip.frame.size).contains(chip.textFrame))
    }

    @Test func completeIPv6AddressesWrapOnNarrowScreens() {
        let address = "fe80:0000:0000:0000:ffff:ffff:ffff:ffff%en123456"
        let text = "DNS\nSource: System default\n114.114.114.114\n\(address)"
        let visible = NSRect(x: -360, y: 80, width: 180, height: 700)
        let chip = ChipWindow.presentation(text, above: NSPoint(x: -190, y: 350), visibleFrame: visible)
        #expect(chip.text == text)
        #expect(chip.text.contains(address))
        #expect(chip.omittedLines == 0)
        #expect(chip.frame.height > PanelStyle.chipMinHeight * 3)
        #expect(visible.insetBy(dx: PanelStyle.chipScreenInset, dy: PanelStyle.chipScreenInset).contains(chip.frame))
        #expect(NSRect(origin: .zero, size: chip.frame.size).contains(chip.textFrame))
    }

    @Test func eightIPv6AddressesFitWithoutLosingAnyAddress() {
        let addresses = (1...8).map { "2001:0db8:ffff:ffff:ffff:ffff:ffff:\(String($0, radix: 16))" }
        let text = (["DNS", "Source: System default"] + addresses).joined(separator: "\n")
        let visible = NSRect(x: 0, y: 0, width: 1024, height: 600)
        let chip = ChipWindow.presentation(text, above: NSPoint(x: 512, y: 300), visibleFrame: visible)
        #expect(chip.text == text)
        #expect(chip.omittedLines == 0)
        #expect(chip.frame.height > PanelStyle.chipMinHeight)
        #expect(chip.frame.width <= PanelStyle.chipMaxWidth)
        #expect(visible.insetBy(dx: PanelStyle.chipScreenInset, dy: PanelStyle.chipScreenInset).contains(chip.frame))
    }

    @Test func chipStaysOnScreenAtEveryEdgeAndOnOffsetDisplays() {
        let text = "DNS\n来源：系统默认\n2001:4860:4860:0000:0000:0000:0000:8888\n114.114.114.114"
        for visible in [NSRect(x: 0, y: 24, width: 1440, height: 850), NSRect(x: -1280, y: -300, width: 1280, height: 720)] {
            let usable = visible.insetBy(dx: PanelStyle.chipScreenInset, dy: PanelStyle.chipScreenInset)
            for x in [visible.minX, visible.midX, visible.maxX] {
                for y in [visible.minY, visible.midY, visible.maxY] {
                    let chip = ChipWindow.presentation(text, above: NSPoint(x: x, y: y), visibleFrame: visible)
                    #expect(usable.contains(chip.frame))
                    #expect(chip.text == text)
                    #expect(chip.omittedLines == 0)
                }
            }
        }
    }

    @Test func heightOverflowReportsHowManyWholeLinesWereOmitted() {
        let oldLanguage = Strings.language
        defer { Strings.language = oldLanguage }
        let lines = ["DNS", "Source: System default"] + (1...20).map { "2001:db8::\($0)" }
        let visible = NSRect(x: 0, y: 0, width: 600, height: 120)
        for language in [Language.en, .zh] {
            Strings.language = language
            let chip = ChipWindow.presentation(lines.joined(separator: "\n"), above: NSPoint(x: 300, y: 60), visibleFrame: visible)
            #expect(chip.omittedLines > 0)
            let displayed = chip.text.components(separatedBy: "\n")
            #expect(displayed.dropLast().elementsEqual(lines.prefix(lines.count - chip.omittedLines)))
            #expect(displayed.last?.contains(String(chip.omittedLines)) == true)
            #expect(displayed.last?.contains(Strings.pick("more lines", "行未显示")) == true)
            #expect(visible.insetBy(dx: PanelStyle.chipScreenInset, dy: PanelStyle.chipScreenInset).contains(chip.frame))
            #expect(NSRect(origin: .zero, size: chip.frame.size).contains(chip.textFrame))
        }
    }
}
