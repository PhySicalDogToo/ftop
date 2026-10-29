import AppKit
import FtopCore
import Testing

@testable import FtopUI

@MainActor
enum DNSWiFiRulesFixtures {
    static func panel() -> DNSWiFiRulesPanel {
        let panel = DNSWiFiRulesPanel()
        panel.onSaveConfiguration = { $0 }
        panel.onRequestWiFiAccess = {}
        return panel
    }

    static func configuration(
        enabled: Bool = true
    ) -> DNSWiFiRulesConfiguration {
        DNSWiFiRulesConfiguration(
            enabled: enabled,
            defaultMode: .custom(["9.9.9.9", "149.112.112.112"]),
            rules: [
                .init(ssid: "Office", mode: .automatic),
                .init(
                    ssid: "Home",
                    mode: .custom(["1.1.1.1", "2001:db8::53"])),
            ])
    }

    static func status(
        _ phase: DNSWiFiRulesStatus.Phase = .active
    ) -> DNSWiFiRulesStatus {
        DNSWiFiRulesStatus(
            phase: phase, ssid: "Home", matchedSSID: "Home",
            servers: ["1.1.1.1", "2001:db8::53"],
            message: phase == .blocked
                ? "A conflicting DNS change stopped automatic writes."
                : "The current service matches this rule.")
    }
}

@MainActor
@Suite struct DNSWiFiRulesUITests {
    init() { _ = NSApplication.shared }

    @Test func openingAnEmptyRulesPanelFiresNoActions() {
        let panel = DNSWiFiRulesPanel()
        var actions = 0
        panel.onSaveConfiguration = {
            actions += 1
            return $0
        }
        panel.onRequestWiFiAccess = { actions += 1 }
        panel.prepare(
            configuration: .defaults, status: .init(), palette: .sea)
        #expect(actions == 0)
        #expect(panel.content.rows.isEmpty)
        #expect(panel.content.enabled.state == .off)
        #expect(panel.content.defaultRule.isDefault)
        #expect(panel.content.defaultRule.remove.isHidden)
        #expect(panel.content.defaultRule.mode.indexOfSelectedItem == 0)
        #expect(
            panel.content.phase.stringValue
                == Strings.pick(
                    "Automatic DNS is off", "自动 DNS 已关闭"))
        #expect(!panel.content.isDirty && !panel.isBusy && !panel.isShown)
    }

    @Test func currentWiFiCreatesAnExactAutomaticRule() throws {
        let panel = DNSWiFiRulesFixtures.panel()
        panel.prepare(
            configuration: .defaults,
            status: DNSWiFiRulesStatus(
                phase: .active, ssid: " Home ", usesDefault: true,
                servers: ["9.9.9.9"]),
            palette: .sea)
        try send(panel.content.useCurrent)
        let row = try #require(panel.content.rows.first)
        #expect(row.ssid.stringValue == " Home ")
        #expect(row.mode.indexOfSelectedItem == 0)
        #expect(panel.content.enabled.state == .on)
        #expect(panel.content.isDirty)
        try send(panel.content.useCurrent)
        #expect(panel.content.rows.count == 1)
    }

    @Test func defaultRuleIsNonRemovableAndExplainsPreferredThenAlternate()
        throws
    {
        let panel = DNSWiFiRulesFixtures.panel()
        panel.prepare(
            configuration: DNSWiFiRulesFixtures.configuration(),
            status: DNSWiFiRulesFixtures.status(), palette: .sea)
        let rule = panel.content.defaultRule
        #expect(rule.isDefault)
        #expect(rule.remove.isHidden)
        #expect(rule.onDelete == nil)
        #expect(rule.mode.indexOfSelectedItem == 1)
        #expect(rule.addresses.string == "9.9.9.9\n149.112.112.112")
        #expect(!rule.priorityHelp.isHidden)
        #expect(
            rule.priorityHelp.stringValue.contains(
                Strings.pick("preferred DNS first", "第一行填写首选 DNS")))
        let draft = try panel.content.draft()
        #expect(
            draft.defaultMode
                == .custom(["9.9.9.9", "149.112.112.112"]))

        panel.prepare(
            configuration: DNSWiFiRulesFixtures.configuration(),
            status: DNSWiFiRulesStatus(
                phase: .active, ssid: "New Wi-Fi", usesDefault: true,
                servers: ["9.9.9.9", "149.112.112.112"]),
            palette: .sea)
        #expect(
            panel.content.identityText.contains(
                Strings.pick("Default DNS", "默认 DNS")))
    }

    @Test func savingParsesCustomIPv4IPv6AndPreservesExactNames() async throws {
        let panel = DNSWiFiRulesFixtures.panel()
        var saved: DNSWiFiRulesConfiguration?
        panel.onSaveConfiguration = {
            saved = $0
            return $0
        }
        panel.prepare(
            configuration: DNSWiFiRulesConfiguration(
                defaultMode: .custom(["9.9.9.9", "149.112.112.112"]),
                rules: [.init(ssid: "Office", mode: .automatic)]),
            status: DNSWiFiRulesFixtures.status(), palette: .sea)
        let row = try #require(panel.content.rows.first)
        row.ssid.stringValue = " Office "
        row.mode.selectItem(at: 1)
        row.addresses.string =
            "1.1.1.1, 2001:db8::53; 2001:0db8:0:0:0:0:0:0053"
        panel.content.changed()
        panel.saveConfiguration()
        try await waitUntil { !panel.isBusy }
        #expect(saved?.rules.first?.ssid == " Office ")
        #expect(
            saved?.rules.first?.mode
                == .custom(["1.1.1.1", "2001:db8::53"]))
        #expect(
            saved?.defaultMode
                == .custom(["9.9.9.9", "149.112.112.112"]))
        #expect(!panel.content.isDirty)
        #expect(!panel.isShown)
    }

    @Test func invalidAndFailedSavesKeepTheDraft() async throws {
        let panel = DNSWiFiRulesFixtures.panel()
        panel.prepare(
            configuration: .defaults,
            status: DNSWiFiRulesFixtures.status(), palette: .sea)
        try send(panel.content.add)
        let row = try #require(panel.content.rows.first)
        row.ssid.stringValue = "Home"
        row.mode.selectItem(at: 1)
        row.addresses.string = "https://invalid.example/dns"
        panel.saveConfiguration()
        #expect(!panel.isBusy)
        #expect(row.addresses.string == "https://invalid.example/dns")
        #expect(!panel.content.notice.isHidden)

        row.addresses.string = "1.1.1.1"
        panel.onSaveConfiguration = { _ in throw FixtureFailure.save }
        panel.saveConfiguration()
        try await waitUntil { !panel.isBusy }
        #expect(panel.content.rows.count == 1)
        #expect(row.ssid.stringValue == "Home")
        #expect(row.addresses.string == "1.1.1.1")
        #expect(panel.content.isDirty)

        panel.content.defaultRule.loadMode(
            .custom(["https://invalid.example/dns"]))
        panel.saveConfiguration()
        #expect(!panel.isBusy)
        #expect(
            panel.content.defaultRule.addresses.string
                == "https://invalid.example/dns")
        #expect(!panel.content.notice.isHidden)
    }

    @Test func disabledIntentAndRuleRemovalAreSavedWithoutChangingTheDraftEarly()
        async throws
    {
        let panel = DNSWiFiRulesFixtures.panel()
        var saved: DNSWiFiRulesConfiguration?
        panel.onSaveConfiguration = {
            saved = $0
            return $0
        }
        let original = DNSWiFiRulesFixtures.configuration()
        panel.prepare(
            configuration: original, status: DNSWiFiRulesFixtures.status(),
            palette: .sea)
        panel.content.enabled.state = .off
        panel.content.changed()
        let last = try #require(panel.content.rows.last)
        try send(last.remove)
        #expect(panel.configuration == original)
        panel.saveConfiguration()
        try await waitUntil { !panel.isBusy }
        #expect(saved?.enabled == false)
        #expect(saved?.rules.map(\.ssid) == ["Office"])
    }

    @Test func busyOperationsPreventDismissalAndDisableEditing() async throws {
        let panel = DNSWiFiRulesPanel()
        let gate = RulesGate()
        panel.onSaveConfiguration = { value in
            await gate.wait()
            return value
        }
        panel.prepare(
            configuration: DNSWiFiRulesFixtures.configuration(),
            status: DNSWiFiRulesFixtures.status(), palette: .sea)
        panel.content.changed()
        panel.saveConfiguration()
        try await waitUntil { gate.calls == 1 }
        #expect(panel.isBusy)
        #expect(!panel.dismiss())
        #expect(!panel.content.enabled.isEnabled)
        #expect(!panel.content.defaultRule.mode.isEnabled)
        #expect(!panel.content.save.isEnabled)
        gate.finish()
        try await waitUntil { !panel.isBusy }
    }

    @Test func transactionErrorsAndWindowBoundsStayActionable() {
        let oldLanguage = Strings.language
        defer { Strings.language = oldLanguage }
        Strings.language = .en
        let saved = DNSChangePresentation.message(
            for: DNSChangeError(
                code: .applyFailed, persistence: .saved,
                currentManualServers: ["223.5.5.5"],
                message: "Apply failed."))
        #expect(saved.contains("Apply failed."))
        #expect(saved.contains("Current manual DNS: 223.5.5.5"))
        #expect(saved.contains("Review the current network service"))
        #expect(!saved.localizedCaseInsensitiveContains("editor"))

        Strings.language = .zh
        let invalid = DNSChangePresentation.message(
            for: DNSChangeError(
                code: .invalidAddress, message: "invalid"))
        #expect(invalid.contains("IPv4 或 IPv6"))

        let visible = NSRect(x: 0, y: 0, width: 700, height: 600)
        let oversized = NSRect(x: -90, y: -70, width: 520, height: 500)
        let fitted = DNSChangePresentation.constrainedFrame(
            oversized, to: visible, padding: PanelStyle.dnsRulesPadding)
        #expect(fitted.minX >= PanelStyle.dnsRulesPadding)
        #expect(fitted.minY >= PanelStyle.dnsRulesPadding)
        #expect(fitted.maxX <= visible.maxX - PanelStyle.dnsRulesPadding)
        #expect(fitted.maxY <= visible.maxY - PanelStyle.dnsRulesPadding)
    }

    private func send(_ button: NSButton) throws {
        let action = try #require(button.action)
        #expect(NSApp.sendAction(action, to: button.target, from: button))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            await Task.yield()
        }
        throw FixtureFailure.timeout
    }

    private enum FixtureFailure: Error { case timeout, save }
}

@MainActor
private final class RulesGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
