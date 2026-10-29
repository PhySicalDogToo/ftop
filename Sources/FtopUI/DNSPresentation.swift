import AppKit
import FtopCore

/// Shared presentation for verified DNS transactions. It contains no editor and
/// performs no reads or writes.
@MainActor
public enum DNSChangePresentation {
    public static func message(for error: Error) -> String {
        guard let change = error as? DNSChangeError else {
            return String(error.localizedDescription.prefix(320))
        }
        let englishReason =
            change.code == .invalidAddress
            ? "Enter IPv4 or IPv6 addresses only. Do not include a URL, port, or scope suffix."
            : String(change.message.prefix(320))
        var parts = [Strings.chinese ? chineseReason(change) : englishReason]
        switch change.persistence {
        case .unchanged:
            break
        case .saved:
            parts.append(
                Strings.pick(
                    "The configuration was saved, but applying or verifying it did not finish.",
                    "配置已保存，但尚未完成应用或验证。"))
        case .unknown:
            parts.append(
                Strings.pick(
                    "The saved configuration could not be confirmed. Do not assume the old settings were restored.",
                    "无法确认配置是否已保存，请勿假定已恢复原设置。"))
        }
        if let current = change.currentManualServers {
            var shown = current.prefix(2).joined(separator: ", ")
            if current.count > 2 {
                shown += Strings.pick(
                    " (+\(current.count - 2) more)",
                    "（另 \(current.count - 2) 项）")
            }
            parts.append(
                Strings.pick("Current manual DNS: ", "当前手动 DNS：")
                    + (current.isEmpty
                        ? Strings.pick("None", "无") : shown))
        }
        if change.isConflict || change.persistence != .unchanged {
            parts.append(
                Strings.pick(
                    "Review the current network service before trying again.",
                    "请检查当前网络服务后再试。"))
        }
        return parts.joined(separator: "\n")
    }

    static func constrainedFrame(
        _ frame: NSRect, to visible: NSRect, padding: CGFloat
    ) -> NSRect {
        let room = visible.insetBy(dx: padding, dy: padding)
        var result = frame
        result.origin.x = min(
            max(frame.minX, room.minX),
            max(room.minX, room.maxX - frame.width))
        result.origin.y = min(
            max(frame.minY, room.minY),
            max(room.minY, room.maxY - frame.height))
        return result
    }

    private static func chineseReason(_ error: DNSChangeError) -> String {
        switch error.code {
        case .invalidAddress:
            "DNS 地址格式无效。请填写 IPv4 或 IPv6 地址，不含网址、端口或接口后缀。"
        case .emptyAddresses:
            "请至少填写一个 IPv4 或 IPv6 地址。"
        case .invalidTarget, .conflict:
            "网络服务、网络位置或 DNS 设置已经变化。"
        case .noPhysicalService:
            "无法确定唯一可编辑的 Wi-Fi 或以太网服务，请到系统网络设置中选择。"
        case .permissionDenied:
            "系统未允许修改 DNS。"
        case .authorizationCancelled:
            error.persistence == .unchanged
                ? "已取消系统授权，DNS 未更改。"
                : "系统授权已取消。"
        case .busy:
            "另一个 DNS 操作正在进行，请稍后重试。"
        case .unavailable:
            "无法读取当前网络设置。"
        case .writeFailed:
            "无法保存 DNS 配置。"
        case .applyFailed:
            "DNS 配置未能完成应用。"
        case .verificationFailed:
            "无法确认当前 DNS 与规则一致。"
        case .externalWriter:
            "检测到其他 DNS 写入工具正在运行，请先退出该工具再保存。"
        }
    }
}
