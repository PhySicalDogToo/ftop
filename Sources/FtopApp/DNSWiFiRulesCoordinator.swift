import AppKit
import FtopCore
import FtopSensors
import FtopUI

/// Injectable boundaries keep authorization and network reads out of coordinator tests.
protocol DNSWiFiRulesRunning: Sendable {
    func requestStop()
    func operationRevision() -> UInt64
    func hasAuthorizedSession() async -> Bool
    func authorize(expectedRevision: UInt64?) async throws
    func pause() async
    func observation() async throws -> DNSWiFiRulesObservation
    func observation(confirming target: DNSEditTarget) async throws -> DNSWiFiRulesObservation
    func apply(
        mode: DNSManualMode, expectedSSID: String, permission: DNSWiFiPermission,
        expected: DNSWiFiRulesObservation
    ) async throws -> DNSWriteResult
}

extension DNSWiFiRulesRuntime: DNSWiFiRulesRunning {}

@MainActor
protocol DNSWiFiRulesMonitoring: AnyObject {
    var permission: DNSWiFiPermission { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    func requestAccess()
}

extension DNSWiFiMonitor: DNSWiFiRulesMonitoring {}

/// Connects exact-name Wi-Fi events to the existing verified DNS transaction.
/// Authorization always ends at a new read boundary, never at an old write target.
@MainActor
final class DNSWiFiRulesCoordinator {
    var canMutate: (() -> Bool)?
    var palette: (() -> PaletteID)?
    var onDNSChanged: ((DNSState) -> Void)?

    var isShown: Bool { panel?.isShown == true }
    var isBusy: Bool {
        actions > 0 || evaluation != nil || panel?.isBusy == true
    }

    private let runtime: any DNSWiFiRulesRunning
    private let wifi: any DNSWiFiRulesMonitoring
    private let store: DNSWiFiRulesStore
    private let readWiFi: @Sendable (DNSWiFiPermission) -> DNSWiFiReading
    private let readDNS: @Sendable () -> DNSState
    private let debounce: Duration
    private let clock: @Sendable () -> TimeInterval
    private var configuration = DNSWiFiRulesConfiguration.defaults
    private(set) var status = DNSWiFiRulesStatus()
    private var configurationLoaded = true
    private var policy = DNSWiFiRulePolicy()
    private var panel: DNSWiFiRulesPanel?
    private var evaluation: Task<Void, Never>?
    private var evaluationToken: UUID?
    private var passiveRead: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var actions = 0
    private var pendingEvent = false
    private var stopped = false
    private var authorizationDeclined = false

    init(
        runtime: any DNSWiFiRulesRunning = DNSWiFiRulesRuntime(),
        wifi: any DNSWiFiRulesMonitoring = DNSWiFiMonitor(),
        store: DNSWiFiRulesStore = DNSWiFiRulesStore(),
        readWiFi: @escaping @Sendable (DNSWiFiPermission) -> DNSWiFiReading = DNSWiFiReader.read,
        readDNS: @escaping @Sendable () -> DNSState = DNSReader.read,
        debounce: Duration = .milliseconds(350),
        clock: (@Sendable () -> TimeInterval)? = nil
    ) {
        self.runtime = runtime
        self.wifi = wifi
        self.store = store
        self.readWiFi = readWiFi
        self.readDNS = readDNS
        self.debounce = debounce
        // ContinuousClock includes system sleep, so old contention cannot remain
        // inside a 60-second window after the Mac wakes. Wall-clock edits do not
        // affect this budget either.
        let origin = ContinuousClock.now
        self.clock =
            clock ?? {
                let elapsed = origin.duration(to: .now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
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
        stopped = false
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
        if rulesActive, wifi.permission == .authorized { requestEvaluation() } else { refreshPassive() }
    }

    func shutdown() {
        stopped = true
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

    func save(
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
        passiveRead?.cancel()
        authorizationDeclined = false
        pendingEvent = false
        runtime.requestStop()
        await runtime.pause()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        policy.reset()
        try store.save(saved)
        configuration = saved
        configurationLoaded = true

        guard rulesActive else {
            wifi.stop()
            let dns = await Task.detached(priority: .utility) { [readDNS] in readDNS() }
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
        await evaluate(prepareSession: true)
        if Task.isCancelled || stopped {
            pendingEvent = false
            runtime.requestStop()
            await runtime.pause()
            throw CancellationError()
        }
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
        guard !stopped else { return }
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
        guard !stopped, configurationLoaded, rulesActive else { return }
        passiveRead?.cancel()
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
            try? await Task.sleep(for: debounce)
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

    private func evaluate(prepareSession: Bool = false) async {
        guard !stopped, configurationLoaded, rulesActive else { return }
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

        let token = epoch
        var didAuthorize = false
        var needsAuthorization = false
        // At most one authorization per evaluation. Its continuation starts with
        // new Wi-Fi, service, connection, DNS and policy inputs, not recursion.
        for _ in 0..<2 {
            guard isCurrent(token) else { return }
            let previousPolicy = policy
            var context: DNSWiFiRuleContext?
            var enteredTransaction = false
            var writeReturned = false
            var requestingAuthorization = false
            do {
                if needsAuthorization {
                    didAuthorize = true
                    // Release the expired native session, including any staged
                    // preferences. The continuation below reads everything anew.
                    runtime.requestStop()
                    await runtime.pause()
                    guard isCurrent(token) else { return }
                    status.phase = .needsNetworkAuthorization
                    status.message = Strings.pick(
                        "Waiting for macOS network authorization. DNS will be rechecked afterward.",
                        "等待 macOS 网络授权，完成后会重新检查当前网络与 DNS。")
                    changed()
                    let revision = runtime.operationRevision()
                    requestingAuthorization = true
                    try await runtime.authorize(expectedRevision: revision)
                    requestingAuthorization = false
                    guard isCurrent(token) else { return }
                }
                let permission = wifi.permission
                guard permission == .authorized else {
                    status = needsWiFiAccessStatus()
                    changed()
                    return
                }
                let (reading, dns) = await Task.detached(priority: .utility) { [readWiFi, readDNS] in
                    (readWiFi(permission), readDNS())
                }.value
                guard isCurrent(token) else { return }
                // Publish a complete new presentation together. Never pair a fresh
                // SSID with the preceding association's rule or error.
                status = snapshotStatus(reading, dns: dns)
                if authorizationDeclined {
                    status.phase = .needsNetworkAuthorization
                    status.message = authorizationMessage
                    changed()
                    return
                }
                guard reading.connected, let ssid = reading.ssid else {
                    let disconnected = reading.connectionKnown && !reading.connected
                    _ = policy.decide(
                        at: clock(),
                        configuration: configuration,
                        context: DNSWiFiRuleContext(
                            network: disconnected ? .disconnected : .unknownSSID))
                    changed()
                    return
                }

                let observation = try await runtime.observation()
                guard isCurrent(token) else { return }
                guard observation.target.interfaceName == reading.interfaceName else {
                    _ = policy.decide(
                        at: clock(),
                        configuration: configuration,
                        context: DNSWiFiRuleContext(network: .nonWiFi))
                    changed()
                    return
                }

                let before = makeContext(reading, observation)
                context = before
                // A tentative decision must not establish an external-change
                // baseline while an administrator sheet is still outstanding.
                var candidatePolicy = policy
                let decision = candidatePolicy.decide(
                    at: clock(),
                    configuration: configuration, context: before)
                let requiresSession: Bool
                switch decision {
                case .apply: requiresSession = true
                case .unchanged: requiresSession = prepareSession
                default: requiresSession = false
                }
                if requiresSession, await !runtime.hasAuthorizedSession() {
                    guard isCurrent(token) else { return }
                    guard !didAuthorize else {
                        throw DNSChangeError(code: .permissionDenied, message: authorizationMessage)
                    }
                    needsAuthorization = true
                    // Discard every tentative value above. No failed-write record,
                    // stale rule or pre-authorization target reaches apply().
                    continue
                }
                guard isCurrent(token) else { return }
                policy = candidatePolicy
                switch decision {
                case .off:
                    status = initialStatus(configuration)
                case .waiting:
                    break
                case .blocked(let reason):
                    let match = configuration.match(forSSID: ssid)
                    status = DNSWiFiRulesStatus(
                        phase: .blocked, ssid: ssid,
                        matchedSSID: match?.matchedSSID,
                        usesDefault: match?.usesDefault == true,
                        servers: dns.servers,
                        message: blockedMessage(reason))
                case .unchanged(let match):
                    policy.recordApplied(context: before)
                    status = activeStatus(
                        ssid: ssid, match: match, servers: dns.servers,
                        changed: false)
                case .apply(let match):
                    status = DNSWiFiRulesStatus(
                        phase: .applying, ssid: ssid,
                        matchedSSID: match.matchedSSID,
                        usesDefault: match.usesDefault,
                        servers: dns.servers,
                        message: match.usesDefault
                            ? Strings.pick(
                                "Applying and verifying the default DNS rule…",
                                "正在应用并验证默认 DNS 规则…")
                            : Strings.pick(
                                "Applying and verifying this Wi-Fi rule…",
                                "正在应用并验证此 Wi-Fi 规则…"))
                    changed()

                    enteredTransaction = true
                    let result = try await runtime.apply(
                        mode: match.mode, expectedSSID: ssid,
                        permission: permission, expected: observation)
                    writeReturned = true
                    guard isCurrent(token) else { return }
                    let after = try await runtime.observation(
                        confirming: result.target)
                    let fresh = await Task.detached(priority: .utility) { [readWiFi] in
                        readWiFi(permission)
                    }.value
                    guard isCurrent(token) else { return }
                    let completed = makeContext(fresh, after)
                    guard completed.network == before.network else {
                        status = snapshotStatus(fresh, dns: result.state)
                        pendingEvent = true
                        changed()
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
                guard isCurrent(token) else { return }
                if enteredTransaction, !writeReturned, !didAuthorize,
                    let change = error as? DNSChangeError,
                    change.code == .permissionDenied, change.persistence == .unchanged
                {
                    // A retained object is not proof of valid credentials. Only
                    // a confirmed no-write denial may reopen authorization, once.
                    // Do not spend the policy budget or retain this stale target.
                    policy = previousPolicy
                    needsAuthorization = true
                    continue
                }
                let authorizationRejected =
                    (error as? DNSChangeError).map {
                        $0.persistence == .unchanged
                            && ($0.code == .permissionDenied || $0.code == .authorizationCancelled)
                    } == true
                if requestingAuthorization || (!writeReturned && authorizationRejected) {
                    authorizationDeclined = true
                    runtime.requestStop()
                    await runtime.pause()
                    guard isCurrent(token) else { return }
                    status = DNSWiFiRulesStatus(
                        phase: .needsNetworkAuthorization,
                        ssid: status.ssid,
                        matchedSSID: status.matchedSSID,
                        usesDefault: status.usesDefault,
                        servers: status.servers,
                        message: authorizationRejected
                            ? authorizationMessage
                            : errorMessage(error) + "\n"
                                + Strings.pick(
                                    "Use Save & Apply to try authorization again.",
                                    "请点“保存并应用”重新授权。"))
                } else if !enteredTransaction,
                    let change = error as? DNSChangeError,
                    change.code == .noPhysicalService
                {
                    // An association may precede DHCP/service readiness. Native
                    // service/IP/link notifications will request another fresh read.
                    status.phase = .waiting
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
            return
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        !stopped && !Task.isCancelled && token == epoch && rulesActive && wifi.permission == .authorized
    }

    private var authorizationMessage: String {
        Strings.pick(
            "Network authorization was not granted. Rules remain saved; use Save & Apply to authorize this app session.",
            "未获得网络授权。规则已保存；请再次点“保存并应用”授权本次运行。")
    }

    private func snapshotStatus(_ reading: DNSWiFiReading, dns: DNSState) -> DNSWiFiRulesStatus {
        let match = reading.connected ? configuration.match(forSSID: reading.ssid) : nil
        return DNSWiFiRulesStatus(
            phase: .waiting, ssid: reading.ssid,
            matchedSSID: match?.matchedSSID, usesDefault: match?.usesDefault == true,
            servers: dns.servers,
            message: Strings.pick(
                "Waiting for network readiness. Network changes will recheck DNS.",
                "等待网络就绪，DNS 保持不变；网络信息更新后会重新检查。"))
    }

    private func refreshPassive() {
        guard panel?.isShown == true, actions == 0, evaluation == nil else { return }
        passiveRead?.cancel()
        let token = epoch
        let permission = wifi.permission
        passiveRead = Task { [weak self, readWiFi, readDNS] in
            let (reading, dns) = await Task.detached(priority: .utility) { [readWiFi, readDNS] in
                (
                    readWiFi(permission), readDNS()
                )
            }.value
            guard !Task.isCancelled, let self, !stopped, token == epoch,
                actions == 0, evaluation == nil
            else { return }
            status = initialStatus(configuration)
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
                        "The default DNS rule was applied and verified.",
                        "默认 DNS 规则已应用并验证。")
                    : Strings.pick(
                        "The exact Wi-Fi DNS rule was applied and verified.",
                        "精确 Wi-Fi DNS 规则已应用并验证。")
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
            phase: .needsWiFiAccess,
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
                "DNS changed over 5 times in 60 s. Keeping external DNS until reconnect or Save & Apply.",
                "60 秒内 DNS 被改写超过 5 次，已保留外部设置；重连或重新保存规则可恢复。")
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
