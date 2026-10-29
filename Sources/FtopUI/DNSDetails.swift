import Foundation
import FtopCore

/// The short, read-only snapshot shown by the system tooltip over the Wi-Fi DNS
/// rules entry. The floating panel remains the persistent DNS display.
@MainActor
enum DNSDetails {
    static func tooltip(_ state: DNSState) -> String {
        var lines = [Strings.pick("Current system DNS", "当前系统 DNS")]
        if state.servers.isEmpty {
            lines.append(Strings.pick("Unavailable", "不可用"))
        } else {
            lines.append(contentsOf: state.servers.map(clean))
        }
        lines.append(
            Strings.pick("Source: ", "来源：") + sourceLabel(state.source))
        if state.source == .unavailable,
            let reason = state.unavailableReason, !reason.isEmpty
        {
            lines.append(Strings.pick("Reason: ", "原因：") + clean(reason))
        }
        return lines.joined(separator: "\n")
    }

    static func sourceLabel(_ source: DNSState.Source) -> String {
        switch source {
        case .systemDefault:
            Strings.pick("System default", "系统默认")
        case .serviceReference:
            Strings.pick(
                "Service reference; system default unavailable",
                "服务参考值；系统默认不可用")
        case .unavailable:
            Strings.pick("Unavailable", "不可用")
        }
    }

    private static func clean(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
    }
}
