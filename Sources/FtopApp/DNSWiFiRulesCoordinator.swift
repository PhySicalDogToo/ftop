import AppKit
import FtopCore
import FtopSensors
import FtopUI

/// Connects exact-name Wi-Fi events to the existing verified DNS transaction.
/// There is no timer, reassertion loop, proxy adapter, or helper process.
@MainActor
final class DNSWiFiRulesCoordinator {
    var canMutate: (() -> Bool)?
    var palette: (() -> PaletteID)?
    var onDNSChanged: ((DNSState) -> Void)?

    var isShown: Bool { panel?.isShown == true }
    var isBusy: Bool {
        actions > 0 || evaluation != nil || panel?.isBusy == true
    }

    private let runtime = DNSWiFiRulesRuntime()
    private let wifi = DNSWiFiMonitor()
    private let store = DNSWiFiRulesStore()
    private var configuration = DNSWiFiRulesConfiguration.defaults
    private var status = DNSWiFiRulesStatus()
    private var configurationLoaded = true
    private var policy = DNSWiFiRulePolicy()
    private var panel: DNSWiFiRulesPanel?
    private var evaluation: Task<Void, Never>?
    private var evaluationToken: UUID?
    private var passiveRead: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var actions = 0
    private var pendingEvent = false

    init() {
        do {
            configuration = try store.load()
            status = initialStatus(configuration)
        } catch {
            configurationLoaded = false
            status = DNSWiFiRulesStatus(
                phase: .blocked,
                message: Strings.pick(
                    "Saved Wi-Fi DNS rules could not be read. Their original data is retained; review and save a new rule set.",
                    "已保存的 Wi-Fi DNS 规则无法读取，原数据已保留；请检查后保存新的规则。"
                ))
        }
        wifi.onChange = { [weak self] in self?.networkChanged() }
    }

    func start() {
        guard configurationLoaded, rulesActive else {
            wifi.stop()
            refreshPassive()
            return
        }
        wifi.start()
        if wifi.permission == .authorized {
            requestEvaluation()
        } else {
            status = needsWiFiAccessStatus()
            changed()
        }
    }

    func show() {
        if panel?.isShown != true {
            let view = DNSWiFiRulesPanel()
            view.onSaveConfiguration = { [weak self] draft in
                guard let self else { throw CancellationError() }
                return try await save(draft)
            }
            view.onRequestWiFiAccess = { [weak self] in
                try await self?.requestWiFiAccess()
            }
            panel = view
        }
        panel?.present(
            configuration: configuration, status: status,
            palette: palette?() ?? .sea, busy: actions > 0 || evaluation != nil)
        refreshPassive()
    }

    func shutdown() {
        epoch &+= 1
        pendingEvent = false
        evaluation?.cancel()
        evaluation = nil
        evaluationToken = nil
        passiveRead?.cancel()
        passiveRead = nil
        runtime.requestStop()
        wifi.stop()
        Task { [runtime] in await runtime.pause() }
    }

    private var rulesActive: Bool {
        configuration.enabled
    }

    private func save(
        _ draft: DNSWiFiRulesConfiguration
    ) async throws -> DNSWiFiRulesConfiguration {
        guard actions == 0, evaluation == nil else {
            throw failure(
                "Wait for the current automatic DNS operation to finish.",
                "请等待当前自动 DNS 操作完成。")
        }
        let saved = try draft.validated()
        actions += 1
        changed()
        defer {
            actions -= 1
            changed()
            if pendingEvent { requestEvaluation() }
        }

        epoch &+= 1
        pendingEvent = false
        runtime.requestStop()
        await runtime.pause()
        policy.reset()
        try store.save(saved)
        configuration = saved
        configurationLoaded = true

        guard rulesActive else {
            wifi.stop()
            let dns = await Task.detached(priority: .utility) { DNSReader.read() }
                .value
            status = DNSWiFiRulesStatus(
                phase: .off, servers: dns.servers,
                message: Strings.pick(
                    "No automatic DNS rule is active. Existing service DNS is unchanged.",
                    "没有启用的自动 DNS 规则，当前网络服务 DNS 保持不变。"))
            return saved
        }

        wifi.start()
        guard wifi.permission == .authorized else {
            status = needsWiFiAccessStatus()
            if wifi.permission == .notDetermined { wifi.requestAccess() }
            return saved
        }
        do {
            if !(await runtime.hasAuthorizedSession()) {
                status = DNSWiFiRulesStatus(
                    phase: .needsNetworkAuthorization,
                    ssid: status.ssid, servers: status.servers,
                    message: Strings.pick(
                        "Authorize this app session so future Wi-Fi switches can apply without preparing a writer at that moment.",
                        "请授权本次应用运行，以便以后切换 Wi-Fi 时直接应用规则。"))
                changed()
                let revision = runtime.operationRevision()
                try await runtime.authorize(expectedRevision: revision)
            }
        } catch {
            status = DNSWiFiRulesStatus(
                phase: .needsNetworkAuthorization,
                ssid: status.ssid, servers: status.servers,
                message: Strings.pick(
                    "Rules were saved, but network authorization was not granted. Use Save & Apply to try again.",
                    "规则已保存，但未获得网络授权；请再次点“保存并应用”重试。"))
            return saved
        }
        await evaluate()
        return saved
    }

    private func requestWiFiAccess() async throws {
        switch wifi.permission {
        case .authorized:
            requestEvaluation()
        case .notDetermined:
            status = needsWiFiAccessStatus()
            changed()
            wifi.requestAccess()
        case .denied, .restricted:
            status = needsWiFiAccessStatus()
            changed()
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func networkChanged() {
        if wifi.permission != .authorized {
            status = needsWiFiAccessStatus()
            changed()
            return
        }
        requestEvaluation()
    }

    /// Coalesce a burst of link/SSID/BSSID notifications. Unlike polling, this
    /// schedules exactly one fresh evaluation for the observed event burst.
    private func requestEvaluation() {
        guard configurationLoaded, rulesActive else { return }
        guard actions == 0, evaluation == nil else {
            pendingEvent = true
            return
        }
        pendingEvent = false
        let token = epoch
        let taskToken = UUID()
        evaluationToken = taskToken
        evaluation = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, token == epoch else {
                if evaluationToken == taskToken {
                    evaluation = nil
                    evaluationToken = nil
                    changed()
                }
                return
            }
            await evaluate()
            guard evaluationToken == taskToken else { return }
            evaluation = nil
            evaluationToken = nil
            changed()
            if pendingEvent { requestEvaluation() }
        }
        changed()
    }

    private func evaluate() async {
        guard configurationLoaded, rulesActive else { return }
        guard canMutate?() ?? true else {
            status.message = Strings.pick(
                "Automatic DNS is waiting for the app update to finish.",
                "自动 DNS 正在等待应用更新完成。")
            changed()
            return
        }
        guard wifi.permission == .authorized else {
            status = needsWiFiAccessStatus()
            changed()
            return
        }

        var context: DNSWiFiRuleContext?
        do {
            let permission = wifi.permission
            let reading = await Task.detached(priority: .utility) {
                DNSWiFiReader.read(permission: permission)
            }.value
            guard reading.connected, let ssid = reading.ssid else {
                let disconnected = reading.connectionKnown && !reading.connected
                _ = policy.decide(
                    configuration: configuration,
                    context: DNSWiFiRuleContext(
                        network: disconnected ? .disconnected : .unknownSSID))
                let dns = await Task.detached(priority: .utility) {
                    DNSReader.read()
                }.value
                status = DNSWiFiRulesStatus(
                    phase: .waiting, ssid: nil, servers: dns.servers,
                    message: Strings.pick(
                        "Waiting for one identifiable connected Wi-Fi. DNS is unchanged.",
                        "正在等待可识别名称的 Wi-Fi，DNS 保持不变。"))
                changed()
                return
            }

            let observation = try await runtime.observation()
            guard observation.target.interfaceName == reading.interfaceName else {
                _ = policy.decide(
                    configuration: configuration,
                    context: DNSWiFiRuleContext(network: .nonWiFi))
                let dns = await Task.detached(priority: .utility) {
                    DNSReader.read()
                }.value
                status = DNSWiFiRulesStatus(
                    phase: .waiting, ssid: ssid, servers: dns.servers,
                    message: Strings.pick(
                        "The current physical service is not this Wi-Fi. DNS is unchanged.",
                        "当前物理网络服务不是此 Wi-Fi，DNS 保持不变。"))
                changed()
                return
            }

            let before = makeContext(reading, observation)
            context = before
            switch policy.decide(
                configuration: configuration, context: before)
            {
            case .off:
                status = initialStatus(configuration)
            case .waiting:
                status = DNSWiFiRulesStatus(
                    phase: .waiting, ssid: ssid,
                    message: Strings.pick(
                        "Waiting for a complete Wi-Fi and network-service snapshot. DNS is unchanged.",
                        "正在等待完整的 Wi-Fi 与网络服务信息，DNS 保持不变。"))
            case .blocked(let reason):
                let match = configuration.match(forSSID: ssid)
                status = DNSWiFiRulesStatus(
                    phase: .blocked, ssid: ssid,
                    matchedSSID: match?.matchedSSID,
                    usesDefault: match?.usesDefault == true,
                    servers: status.servers,
                    message: blockedMessage(reason))
            case .unchanged(let match):
                let dns = await Task.detached(priority: .utility) {
                    DNSReader.read()
                }.value
                policy.recordApplied(context: before)
                status = activeStatus(
                    ssid: ssid, match: match, servers: dns.servers,
                    changed: false)
            case .apply(let match):
                status = DNSWiFiRulesStatus(
                    phase: .applying, ssid: ssid,
                    matchedSSID: match.matchedSSID,
                    usesDefault: match.usesDefault,
                    servers: status.servers,
                    message: match.usesDefault
                        ? Strings.pick(
                            "Applying and verifying the default DNS rule…",
                            "正在应用并验证默认 DNS 规则…")
                        : Strings.pick(
                            "Applying and verifying this Wi-Fi rule…",
                            "正在应用并验证此 Wi-Fi 规则…"))
                changed()

                if await !runtime.hasAuthorizedSession() {
                    status.phase = .needsNetworkAuthorization
                    status.message = Strings.pick(
                        "Authorize this app session to change the current network service.",
                        "请授权本次应用运行修改当前网络服务。")
                    changed()
                    let revision = runtime.operationRevision()
                    try await runtime.authorize(expectedRevision: revision)
                }
                let result = try await runtime.apply(
                    mode: match.mode, expectedSSID: ssid,
                    permission: permission, expected: observation)
                let after = try await runtime.observation(
                    confirming: result.target)
                let fresh = await Task.detached(priority: .utility) {
                    DNSWiFiReader.read(permission: permission)
                }.value
                let completed = makeContext(fresh, after)
                guard completed.network == before.network else {
                    pendingEvent = true
                    return
                }
                policy.recordApplied(context: completed)
                status = activeStatus(
                    ssid: ssid, match: match,
                    servers: result.state.servers,
                    changed: result.didChange)
                onDNSChanged?(result.state)
            }
            changed()
        } catch {
            if let change = error as? DNSChangeError,
                change.code == .permissionDenied
                    || change.code == .authorizationCancelled
            {
                runtime.requestStop()
                await runtime.pause()
                status = DNSWiFiRulesStatus(
                    phase: .needsNetworkAuthorization,
                    ssid: status.ssid,
                    matchedSSID: status.matchedSSID,
                    usesDefault: status.usesDefault,
                    servers: status.servers,
                    message: Strings.pick(
                        "Network authorization was not granted. Rules remain saved; use Save & Apply to authorize this app session.",
                        "未获得网络授权。规则已保存；请再次点“保存并应用”授权本次运行。"))
            } else {
                if let context { policy.recordFailure(context: context) }
                status = DNSWiFiRulesStatus(
                    phase: .blocked, ssid: status.ssid,
                    matchedSSID: status.matchedSSID,
                    usesDefault: status.usesDefault,
                    servers: status.servers,
                    message: errorMessage(error))
            }
            changed()
        }
    }

    private func refreshPassive() {
        guard panel?.isShown == true else { return }
        passiveRead?.cancel()
        let token = epoch
        let permission = wifi.permission
        passiveRead = Task { [weak self] in
            let (reading, dns) = await Task.detached(priority: .utility) {
                (
                    DNSWiFiReader.read(permission: permission),
                    DNSReader.read()
                )
            }.value
            guard !Task.isCancelled, let self, token == epoch else { return }
            status.ssid = reading.ssid
            status.servers = dns.servers
            if rulesActive, permission != .authorized {
                status = needsWiFiAccessStatus(servers: dns.servers)
            }
            changed()
        }
    }

    private func makeContext(
        _ reading: DNSWiFiReading,
        _ observation: DNSWiFiRulesObservation
    ) -> DNSWiFiRuleContext {
        guard reading.connected, let ssid = reading.ssid,
            reading.interfaceName == observation.target.interfaceName
        else { return DNSWiFiRuleContext(network: .unknownSSID) }
        var association = observation.connectionID
        association.append(0)
        association.append(contentsOf: (reading.bssid ?? "").utf8)
        return DNSWiFiRuleContext(
            network: .wifi(
                ssid: ssid, locationID: observation.target.locationID,
                serviceID: observation.target.serviceID,
                connectionID: association),
            manualServers: observation.target.manualServers,
            hasManualAddressKey: observation.hasManualAddressKey,
            dnsFingerprint: observation.configurationFingerprint)
    }

    private func activeStatus(
        ssid: String, match: DNSWiFiRuleMatch, servers: [String], changed: Bool
    ) -> DNSWiFiRulesStatus {
        DNSWiFiRulesStatus(
            phase: .active, ssid: ssid,
            matchedSSID: match.matchedSSID,
            usesDefault: match.usesDefault,
            servers: servers,
            message: changed
                ? match.usesDefault
                    ? Strings.pick(
                        "The default DNS rule was applied and verified. Future writes occur only on Wi-Fi events.",
                        "默认 DNS 规则已应用并验证；以后只在 Wi-Fi 事件发生时写入。")
                    : Strings.pick(
                        "The exact rule was applied and verified. Future writes occur only on Wi-Fi events.",
                        "精确 Wi-Fi 规则已应用并验证；以后只在 Wi-Fi 事件发生时写入。")
                : match.usesDefault
                    ? Strings.pick(
                        "The current service already matches the default DNS rule. No write was needed.",
                        "当前网络服务已符合默认 DNS 规则，无需写入。")
                    : Strings.pick(
                        "The current service already matches the exact rule. No write was needed.",
                        "当前网络服务已符合精确 Wi-Fi 规则，无需写入。"))
    }

    private func initialStatus(
        _ configuration: DNSWiFiRulesConfiguration
    ) -> DNSWiFiRulesStatus {
        if !configuration.enabled {
            return DNSWiFiRulesStatus(
                phase: .off,
                message: Strings.pick(
                    "Automatic switching is off. Existing DNS is unchanged.",
                    "自动切换已关闭，现有 DNS 保持不变。"))
        }
        return DNSWiFiRulesStatus(
            phase: .waiting,
            message: Strings.pick(
                "Waiting for a Wi-Fi event. Exact rules override the default DNS rule.",
                "正在等待 Wi-Fi 事件；精确规则优先于默认 DNS 规则。"))
    }

    private func needsWiFiAccessStatus(
        servers: [String] = []
    ) -> DNSWiFiRulesStatus {
        DNSWiFiRulesStatus(
            phase: .needsWiFiAccess, ssid: status.ssid,
            servers: servers.isEmpty ? status.servers : servers,
            message: Strings.pick(
                "macOS location permission is used only to read the connected Wi-Fi name. No DNS is changed without it.",
                "macOS 定位权限仅用于读取当前 Wi-Fi 名称；没有该权限不会修改 DNS。"))
    }

    private func blockedMessage(
        _ reason: DNSWiFiRuleDecision.BlockedReason
    ) -> String {
        switch reason {
        case .externalConfigurationChange:
            Strings.pick(
                "DNS changed outside ftop on this connection. Automatic writes stopped; save the rules again after reviewing the current settings.",
                "此连接的 DNS 被外部修改，自动写入已停止；请检查当前设置后重新保存规则。")
        case .invalidConfiguration:
            Strings.pick(
                "The saved rule set is invalid. Review and save it again.",
                "已保存规则无效，请检查后重新保存。")
        case .writeFailed:
            Strings.pick(
                "The last write could not be verified. Automatic retries are stopped for this connection.",
                "上次写入无法确认；此连接不会自动重试。")
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if error is DNSChangeError {
            return DNSChangePresentation.message(for: error) + "\n"
                + String(error.localizedDescription.prefix(300))
        }
        return String(error.localizedDescription.prefix(500))
    }

    private func changed() {
        panel?.refresh(
            configuration: configuration, status: status,
            palette: palette?() ?? .sea,
            busy: actions > 0 || evaluation != nil)
    }

    private func failure(_ english: String, _ chinese: String) -> NSError {
        NSError(
            domain: "dev.ftop.dns.wifi-rules", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: Strings.pick(english, chinese)
            ])
    }
}
