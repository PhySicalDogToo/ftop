import AppKit
import FtopCore

/// Presentation shared by the list, its compact form, the card and the control block.
@MainActor
enum ProcessPresentation {
    /// Fixed collector scope, separate from its dynamic diagnostic reasons.
    private static let legacySocketScope =
        "TCP/UDP socket activity, including local and proxy connections. TUN may appear under both app and proxy; totals are not physical-interface throughput. Other userland providers may be unavailable."
    static let socketScope = legacySocketScope + " Only sampled connections are counted; first observations or very short-lived connections may be missed."

    static func localizedNote(_ note: String?) -> String? {
        guard note == socketScope || note == legacySocketScope else { return note }
        return Strings.pick(note ?? socketScope, "TCP/UDP 套接字活动，包含本地与代理连接。TUN 流量可能同时出现在应用和代理下，合计不等于物理网卡吞吐量。部分应用连接可能无法统计。仅统计已采样连接，首次观察或很短暂的连接可能遗漏。")
    }

    static func localizedReason(_ reason: String?) -> String? {
        guard reason == ProcessNetworkStatus.notCollected.reason else { return reason }
        return nil
    }

    static var loadingText: String { Strings.pick("Reading data…", "数据读取中") }

    /// Uses the list's existing reserved row; a status never changes layout geometry.
    static func placeholder(_ list: ProcessList?, sortedBy sort: ProcessSort) -> String {
        sort.isNetwork && list?.networkStatus.isLoading == true ? loadingText : "—"
    }
    struct Figure: Equatable {
        var number: String
        var unit: String
        var text: String { unit.isEmpty ? number : number + (unit == "%" ? "" : " ") + unit }
        static let unavailable = Figure(number: "—", unit: "")
    }

    static func name(_ sort: ProcessSort) -> String {
        switch sort {
        case .cpu: "CPU"
        case .memory: Strings.pick("Memory", "内存")
        case .download: Strings.pick("Download", "下载")
        case .upload: Strings.pick("Upload", "上传")
        }
    }

    static func glyph(_ sort: ProcessSort) -> Glyph {
        switch sort {
        case .cpu: .cpu
        case .memory: .memory
        case .download: .download
        case .upload: .upload
        }
    }

    static func paint(_ sort: ProcessSort) -> Paint {
        switch sort {
        case .cpu: .performance
        case .memory: PanelStyle.pressurePaint(.normal)
        case .download, .upload: .secondary
        }
    }

    static func rate(_ value: Double?) -> Figure {
        guard let value, value.isFinite, value >= 0 else { return .unavailable }
        // Keep the number bounded even for malformed or implausibly large samples.
        let quantity = Format.compactRate(min(value, 999_000_000_000))
        return Figure(number: value >= 999_500_000_000 ? ">999" : quantity.number, unit: quantity.unit)
    }

    static func overflowNote(_ network: ProcessNetworkSample?) -> String? {
        guard let network else { return nil }
        let values: [(ProcessSort, Double)] = [(.download, network.downloadBytesPerSecond), (.upload, network.uploadBytesPerSecond)]
        let lines = values.compactMap { sort, value -> String? in
            guard value.isFinite, value >= 999_500_000_000 else { return nil }
            return name(sort) + ": " + String(value) + " B/s"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func figure(_ entry: ProcessSample, sortedBy sort: ProcessSort, cores: Int) -> Figure {
        figure(cpu: entry.cpuPercent, memory: entry.memoryBytes, usageAvailable: entry.usageAvailable, network: entry.network, sortedBy: sort, cores: cores)
    }

    static func figure(_ member: ProcessMember, sortedBy sort: ProcessSort, cores: Int) -> Figure {
        figure(cpu: member.cpuPercent, memory: member.memoryBytes, usageAvailable: member.usageAvailable, network: member.network, sortedBy: sort, cores: cores)
    }

    private static func figure(cpu: Double, memory: UInt64, usageAvailable: Bool, network: ProcessNetworkSample?, sortedBy sort: ProcessSort, cores: Int) -> Figure {
        switch sort {
        case .cpu:
            return usageAvailable ? Figure(number: Format.processShare(percentOfOneCore: cpu, cores: cores), unit: "%") : .unavailable
        case .memory:
            guard usageAvailable else { return .unavailable }
            let text = Format.processMemory(memory)
            return Figure(number: String(text.dropLast()), unit: String(text.suffix(1)))
        case .download: return rate(network?.downloadBytesPerSecond)
        case .upload: return rate(network?.uploadBytesPerSecond)
        }
    }

    static func emptyReason(_ list: ProcessList?, sortedBy sort: ProcessSort) -> String {
        guard let list else { return Strings.noReading }
        if sort.isNetwork {
            if list.networkStatus.isLoading { return loadingText }
            if list.networkStatus == .notCollected { return Strings.noReading }
            let reason = localizedReason(list.networkStatus.reason) ?? Strings.pick("No process network activity in this sample", "本次采样没有进程网络活动")
            return [reason, localizedNote(list.networkNote)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return Strings.pick("This process ranking is unavailable", "此进程排行暂不可用")
    }
}
