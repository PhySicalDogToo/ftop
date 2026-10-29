import AppKit
import FtopCore
import Testing

@testable import FtopUI

private let dnsRulesRenderDirectory =
    ProcessInfo.processInfo.environment["FTOP_DNS_RULES_RENDER_DIR"]

@MainActor
@Suite struct DNSWiFiRulesRenderTests {
    init() { _ = NSApplication.shared }

    @Test func everyStateFitsWideAndCompactSurfaces() throws {
        let previous = Strings.language
        defer { Strings.language = previous }
        for language in [Language.en, .zh] {
            Strings.language = language
            for width in [
                PanelStyle.dnsRulesWidth, PanelStyle.dnsRulesCompactWidth,
            ] {
                for phase in DNSWiFiRulesStatus.Phase.allReferenceCases {
                    let panel = fixture(phase)
                    let content = panel.content
                    let size = content.fittedSize(
                        width: width, maximumHeight: 720)
                    content.window?.setContentSize(size)
                    content.layoutSubtreeIfNeeded()
                    #expect(size.width == width && size.height <= 720)
                    #expect(abs(content.bounds.width - width) < 1)
                    #expect(
                        content.bounds.insetBy(dx: -1, dy: -1).contains(
                            content.phase.convert(
                                content.phase.bounds, to: content)))
                    #expect(
                        content.bounds.insetBy(dx: -1, dy: -1).contains(
                            content.enabled.convert(
                                content.enabled.bounds, to: content)))
                    for view in [
                        content.enabled, content.add, content.useCurrent,
                        content.grant, content.save, content.close,
                        content.defaultRule.mode,
                    ] {
                        #expect(view.bounds.width > 0 && view.bounds.height > 0)
                        #expect(
                            content.bounds.insetBy(dx: -1, dy: -1).contains(
                                view.convert(view.bounds, to: content)))
                    }
                    #expect(
                        content.rulesScroll.contentSize.height
                            >= PanelStyle.dnsRulesRulesMinimumHeight - 2)
                    #expect(content.defaultRule.bounds.width > 0)
                    #expect(content.defaultRule.remove.isHidden)
                    content.defaultRule.syncTextGeometry()
                    for row in content.rows {
                        #expect(row.bounds.width > 0 && row.bounds.height > 0)
                        #expect(row.mode.bounds.width > 0)
                        row.syncTextGeometry()
                    }
                    #expect(!panel.isShown)
                }
            }
        }
    }

    @Test(.enabled(if: dnsRulesRenderDirectory != nil))
    func writeWiFiRuleReferences() throws {
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let previous = Strings.language
        defer { Strings.language = previous }
        let directory = URL(
            fileURLWithPath: dnsRulesRenderDirectory!, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        for language in [Language.en, .zh] {
            Strings.language = language
            for dark in [false, true] {
                for (phase, width) in [
                    (DNSWiFiRulesStatus.Phase.off, PanelStyle.dnsRulesWidth),
                    (.active, PanelStyle.dnsRulesWidth),
                    (.active, PanelStyle.dnsRulesCompactWidth),
                    (.waiting, PanelStyle.dnsRulesCompactWidth),
                    (.needsWiFiAccess, PanelStyle.dnsRulesCompactWidth),
                    (
                        .needsNetworkAuthorization,
                        PanelStyle.dnsRulesCompactWidth
                    ),
                    (.blocked, PanelStyle.dnsRulesCompactWidth),
                    (.applying, PanelStyle.dnsRulesCompactWidth),
                ] {
                    let panel = fixture(phase)
                    let content = panel.content
                    content.window?.appearance = NSAppearance(
                        named: dark ? .darkAqua : .aqua)
                    let size = content.fittedSize(
                        width: width, maximumHeight: 720)
                    content.window?.setContentSize(size)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(
                        content.bitmapImageRepForCachingDisplay(
                            in: content.bounds))
                    content.effectiveAppearance
                        .performAsCurrentDrawingAppearance {
                            content.cacheDisplay(
                                in: content.bounds, to: bitmap)
                        }
                    let data = try composite(
                        bitmap, appearance: content.effectiveAppearance)
                    let name =
                        "dns-rules-\(language.rawValue)-\(dark ? "dark" : "light")-\(phase.rawValue)-\(Int(width)).png"
                    try data.write(to: directory.appending(path: name))
                }
            }
        }
    }

    private func fixture(
        _ phase: DNSWiFiRulesStatus.Phase
    ) -> DNSWiFiRulesPanel {
        let panel = DNSWiFiRulesFixtures.panel()
        let configuration =
            phase == .off
            ? DNSWiFiRulesConfiguration.defaults
            : DNSWiFiRulesFixtures.configuration()
        let message: String
        switch phase {
        case .off:
            message = Strings.pick(
                "Enable automatic switching to use the default DNS rule.",
                "启用自动切换后即可使用默认 DNS 规则。")
        case .waiting:
            message = Strings.pick(
                "Waiting for a connected Wi-Fi network.",
                "正在等待 Wi-Fi 连接。")
        case .needsWiFiAccess:
            message = Strings.pick(
                "Allow Wi-Fi name access. Location is used only for the connected network name.",
                "请允许读取 Wi-Fi 名称；定位权限仅用于当前网络名称。")
        case .needsNetworkAuthorization:
            message = Strings.pick(
                "Authorize this app session before the matching rule can be written.",
                "请授权本次应用运行，才能写入匹配规则。")
        case .blocked:
            message = Strings.pick(
                "Another DNS change was detected. Automatic retries stopped for this connection.",
                "检测到其他 DNS 修改，此连接已停止自动重试。")
        case .applying:
            message = Strings.pick(
                "Writing and verifying the matching rule.",
                "正在写入并验证匹配规则。")
        case .active:
            message = Strings.pick(
                "The current service matches the default DNS rule.",
                "当前网络服务已符合默认 DNS 规则。")
        }
        panel.prepare(
            configuration: configuration,
            status: DNSWiFiRulesStatus(
                phase: phase, ssid: phase == .off ? nil : "Home",
                matchedSSID: phase == .off || phase == .active ? nil : "Home",
                usesDefault: phase == .active,
                servers: phase == .off
                    ? [] : ["1.1.1.1", "2001:db8::53"],
                message: message),
            palette: .sea, busy: phase == .applying)
        return panel
    }

    private func composite(
        _ bitmap: NSBitmapImageRep, appearance: NSAppearance
    ) throws -> Data {
        let result = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: result))
        let image = try #require(bitmap.cgImage)
        let bounds = CGRect(
            x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        appearance.performAsCurrentDrawingAppearance {
            context.cgContext.setFillColor(PanelStyle.controlColor.cgColor)
            context.cgContext.fill(bounds)
            context.cgContext.setBlendMode(.normal)
            context.cgContext.draw(image, in: bounds)
        }
        return try #require(
            result.representation(using: .png, properties: [:]))
    }
}

extension DNSWiFiRulesStatus.Phase {
    fileprivate static let allReferenceCases: [Self] = [
        .off, .waiting, .needsWiFiAccess, .needsNetworkAuthorization,
        .applying, .active, .blocked,
    ]
}
