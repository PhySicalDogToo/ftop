import Foundation
import FtopCore
import Testing

@testable import FtopApp
@testable import FtopSensors

@MainActor
@Suite struct DNSWiFiRulesCoordinatorTests {
    @Test func authorizationDiscardsHotspotRuleAndEveryOldServiceField() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        #expect(coordinator.status.ssid == "Hotspot")

        fixture.network.select("Office", service: "office-service", address: "192.0.2.53")
        // Deliver the same hints as location/service/link callbacks while busy.
        for _ in 0..<4 { fixture.monitor.onChange?() }
        await fixture.runtime.finishAuthorization()
        try await eventually { !coordinator.isBusy }

        let writes = await fixture.runtime.writes
        #expect(writes.count == 1)
        #expect(writes.first?.ssid == "Office")
        #expect(writes.first?.mode == .automatic)
        #expect(writes.first?.observation == fixture.network.beforeWrite)
        #expect(writes.first?.observation.target.serviceID == "office-service")
        #expect(writes.first?.observation.target.manualServers == ["192.0.2.53"])
        #expect(coordinator.status.phase == .active)
        #expect(coordinator.status.ssid == "Office")
        #expect(coordinator.status.matchedSSID == "Office")
        #expect(!coordinator.status.usesDefault)
        #expect(await fixture.runtime.authorizationCount == 1)
    }

    @Test func dnsChangedDuringAuthorizationBecomesTheNewBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        // Same association, different DNS: the tentative policy must not treat
        // this pre-write change as an external modification after our write.
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        let writes = await fixture.runtime.writes
        #expect(writes.count == 1)
        #expect(writes.first?.observation.target.manualServers == ["8.8.8.8"])
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.usesDefault)
        #expect(fixture.coordinator.status.matchedSSID == nil)
    }

    @Test func freshRuleAlreadySatisfiedSkipsWriteAfterAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        fixture.network.select("Office", service: "new-service", address: nil)
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(await fixture.runtime.writes.isEmpty)
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(fixture.coordinator.status.servers == ["192.0.2.1"])
    }

    @Test func serviceChangedOnSameSSIDDuringAuthorizationUsesFreshTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        fixture.network.select("Hotspot", service: "replacement-service", address: "9.9.9.9")
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        let writes = await fixture.runtime.writes
        #expect(writes.count == 1)
        #expect(writes.first?.observation.target.serviceID == "replacement-service")
        #expect(writes.first?.observation.target.locationID == "location-replacement-service")
        #expect(writes.first?.mode == .custom(["114.114.114.114"]))
        #expect(fixture.coordinator.status.ssid == "Hotspot")
        #expect(fixture.coordinator.status.usesDefault)
    }

    @Test func serviceReadyLaterRecoversOnNativeHintWithoutAnotherAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        fixture.network.select("Office", service: "office-service", address: "8.8.8.8")
        fixture.network.ready = false
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .waiting)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(fixture.coordinator.status.servers == ["8.8.8.8"])
        #expect(await fixture.runtime.writes.isEmpty)

        // No SSID or DNS-address change: only the service/IP readiness hint.
        fixture.network.ready = true
        for _ in 0..<3 { fixture.monitor.onChange?() }
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.writes.count == 1)
        #expect(await fixture.runtime.authorizationCount == 1)
    }

    @Test func locationAuthorizationCallbackReadsAndMatchesCurrentConnection() async throws {
        let fixture = try Fixture(permission: .notDetermined)
        defer { fixture.close() }
        fixture.coordinator.start()
        #expect(fixture.coordinator.status.phase == .needsWiFiAccess)
        fixture.network.select("Office", service: "office-service", address: nil)
        fixture.monitor.permission = .authorized
        for _ in 0..<3 { fixture.monitor.onChange?() }
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.monitor.startCount == 1)
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(await fixture.runtime.authorizationCount == 0)
        #expect(await fixture.runtime.writes.isEmpty)
    }

    @Test func unavailableServiceBeforeAnyWriteWaitsWithoutOpeningAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.network.ready = false
        fixture.coordinator.start()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .waiting)
        #expect(await fixture.runtime.authorizationCount == 0)
        fixture.network.ready = true
        fixture.monitor.onChange?()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.writes.count == 1)
    }

    @Test func unverifiedTransactionStillBlocksAutomaticRetries() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.runtime.failApply()
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .blocked)
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .blocked)
        #expect(await fixture.runtime.writes.count == 1)
    }

    @Test func authorizationDeclinedDoesNotPromptAgainOnDuplicateEvents() async throws {
        for code in [DNSChangeError.Code.authorizationCancelled, .permissionDenied] {
            let fixture = try Fixture()
            fixture.coordinator.start()
            try await eventually { await fixture.runtime.authorizationCount == 1 }
            for _ in 0..<3 { fixture.monitor.onChange?() }
            await fixture.runtime.finishAuthorization(error: DNSChangeError(code: code, message: "Fixture declined"))
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.phase == .needsNetworkAuthorization)
            #expect(await fixture.runtime.writes.isEmpty)
            fixture.network.ready = false
            fixture.monitor.onChange?()
            try await eventually { !fixture.coordinator.isBusy }
            #expect(await fixture.runtime.authorizationCount == 1)
            #expect(fixture.coordinator.status.phase == .needsNetworkAuthorization)
            fixture.close()
        }
    }

    @Test func shutdownDuringAuthorizationCannotResumeOrWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        fixture.coordinator.shutdown()
        let previous = fixture.coordinator.status
        fixture.network.select("Office", service: "new-service", address: nil)
        await fixture.runtime.finishAuthorization()
        for _ in 0..<3 { fixture.monitor.onChange?() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fixture.runtime.writes.isEmpty)
        #expect(fixture.coordinator.status == previous)
    }

    @Test func cancelledSaveCannotContinueAfterAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let task = Task { try await fixture.coordinator.save(fixture.configuration) }
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        task.cancel()
        await fixture.runtime.finishAuthorization()
        do {
            _ = try await task.value
            Issue.record("A cancelled save must not report completion")
        } catch is CancellationError {}
        #expect(await fixture.runtime.writes.isEmpty)
        #expect(fixture.coordinator.status.phase != .active)
    }

    @Test func explicitSavePreparesSessionAndRereadsEvenAnInitiallyMatchingRule() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.network.select("Office", service: "office-service", address: nil)
        let task = Task { try await fixture.coordinator.save(fixture.configuration) }
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        await fixture.runtime.finishAuthorization()
        _ = try await task.value
        let writes = await fixture.runtime.writes
        #expect(writes.count == 1)
        #expect(writes.first?.ssid == "Hotspot")
        #expect(writes.first?.mode == .custom(["114.114.114.114"]))
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.usesDefault)
        #expect(fixture.coordinator.status.matchedSSID == nil)
    }

    @Test func reassertsFiveExternalChangesThenKeepsSixthUntilNewConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        for index in 1...6 {
            fixture.network.time = Double(index)
            fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
            let freshBaseline = try fixture.network.observation()
            for _ in 0..<4 { fixture.monitor.onChange?() }
            try await eventually { !fixture.coordinator.isBusy }
            if index <= 5 {
                #expect(fixture.coordinator.status.phase == .active)
                #expect(await fixture.runtime.writes.count == index + 1)
                #expect(await fixture.runtime.writes.last?.observation == freshBaseline)
                #expect(fixture.network.dns().servers == ["114.114.114.114"])
            }
        }
        #expect(fixture.coordinator.status.phase == .blocked)
        #expect(fixture.coordinator.status.servers == ["8.8.8.8"])
        #expect(await fixture.runtime.writes.count == 6)
        fixture.network.time = 120
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .blocked)
        #expect(await fixture.runtime.writes.count == 6)
        fixture.network.select("Office", service: "office-service", address: nil)
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(!fixture.coordinator.status.usesDefault)
    }

    @Test func sparseExternalChangesReassertWithoutPausingAndMetadataDoesNotWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        fixture.network.changeMetadata()
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.writes.count == 1)
        for index in 1...7 {
            fixture.network.time = Double(index * 61)
            fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
            fixture.monitor.onChange?()
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.phase == .active)
            #expect(await fixture.runtime.writes.count == index + 1)
        }
        #expect(await fixture.runtime.authorizationCount == 1)
    }

    @Test func explicitSaveRestartsReassertionsAfterTheLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        for index in 1...6 {
            fixture.network.time = Double(index)
            fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
            fixture.monitor.onChange?()
            try await eventually { !fixture.coordinator.isBusy }
        }
        #expect(fixture.coordinator.status.phase == .blocked)
        let task = Task { try await fixture.coordinator.save(fixture.configuration) }
        try await eventually { await fixture.runtime.authorizationCount == 2 }
        await fixture.runtime.finishAuthorization()
        _ = try await task.value
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.writes.count == 7)
    }

    @Test func expiredSessionPromptsOnceThenUsesFreshNetworkRuleAndTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        await fixture.runtime.expireAuthorization()
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        for _ in 0..<4 { fixture.monitor.onChange?() }
        try await eventually { await fixture.runtime.authorizationCount == 2 }
        #expect(fixture.coordinator.status.phase == .needsNetworkAuthorization)
        #expect(await fixture.runtime.writes.count == 1)

        fixture.network.select("Office", service: "replacement-service", address: "192.0.2.53")
        for _ in 0..<4 { fixture.monitor.onChange?() }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        let writes = await fixture.runtime.writes
        #expect(writes.count == 2)
        #expect(writes.last?.ssid == "Office")
        #expect(writes.last?.mode == .automatic)
        #expect(writes.last?.observation == fixture.network.beforeWrite)
        #expect(writes.last?.observation.target.serviceID == "replacement-service")
        #expect(writes.last?.observation.target.manualServers == ["192.0.2.53"])
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(fixture.coordinator.status.servers == ["192.0.2.1"])
        #expect(await fixture.runtime.authorizationCount == 2)
    }

    @Test func expiredSessionDoesNotPromptWhileDNSAlreadyMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        await fixture.runtime.expireAuthorization()
        fixture.network.changeMetadata()
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.authorizationCount == 1)
        #expect(await fixture.runtime.writes.count == 1)
    }

    @Test func renewedSessionSkipsWriteIfFreshConfigurationAlreadyMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        try await requestRenewal(fixture)
        fixture.network.select("Office", service: "office-service", address: nil)
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(await fixture.runtime.writes.count == 1)
    }

    @Test func renewedSessionWaitsForServiceThenRecoversOnNativeHint() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        try await requestRenewal(fixture)
        fixture.network.select("Office", service: "office-service", address: "8.8.8.8")
        fixture.network.ready = false
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .waiting)
        #expect(fixture.coordinator.status.ssid == "Office")
        #expect(fixture.coordinator.status.matchedSSID == "Office")
        #expect(await fixture.runtime.writes.count == 1)
        fixture.network.ready = true
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .active)
        #expect(await fixture.runtime.writes.count == 2)
        #expect(await fixture.runtime.authorizationCount == 2)
    }

    @Test func renewalCancellationOrFailureSuppressesPromptsUntilExplicitSave() async throws {
        for code in [DNSChangeError.Code.authorizationCancelled, .permissionDenied, .busy, .unavailable] {
            let fixture = try Fixture()
            try await startAuthorized(fixture)
            try await requestRenewal(fixture)
            for _ in 0..<3 { fixture.monitor.onChange?() }
            await fixture.runtime.finishAuthorization(error: DNSChangeError(code: code, message: "Fixture declined"))
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.phase == .needsNetworkAuthorization)
            fixture.network.select("Office", service: "office-service", address: "9.9.9.9")
            for _ in 0..<3 { fixture.monitor.onChange?() }
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.ssid == "Office")
            #expect(fixture.coordinator.status.matchedSSID == "Office")
            #expect(await fixture.runtime.authorizationCount == 2)
            #expect(await fixture.runtime.writes.count == 1)
            let save = Task { try await fixture.coordinator.save(fixture.configuration) }
            try await eventually { await fixture.runtime.authorizationCount == 3 }
            await fixture.runtime.finishAuthorization()
            _ = try await save.value
            #expect(fixture.coordinator.status.phase == .active)
            #expect(await fixture.runtime.writes.count == 2)
            fixture.close()
        }
    }

    @Test func newlyGrantedButUnusableRightsCannotCauseRepeatedPrompts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        try await requestRenewal(fixture)
        await fixture.runtime.failApply(error: DNSChangeError(code: .permissionDenied, message: "Fixture denied again"))
        for _ in 0..<4 { fixture.monitor.onChange?() }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .needsNetworkAuthorization)
        for _ in 0..<4 { fixture.monitor.onChange?() }
        try await eventually { !fixture.coordinator.isBusy }
        #expect(await fixture.runtime.authorizationCount == 2)
        #expect(await fixture.runtime.writes.count == 2)
    }

    @Test func authorizationErrorWithSavedOrUnknownResultCannotRetry() async throws {
        for persistence in [DNSChangeError.Persistence.saved, .unknown] {
            let fixture = try Fixture()
            try await startAuthorized(fixture)
            await fixture.runtime.failApply(
                error: DNSChangeError(code: .permissionDenied, persistence: persistence, message: "Fixture uncertain result"))
            fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
            fixture.monitor.onChange?()
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.phase == .blocked)
            fixture.monitor.onChange?()
            try await eventually { !fixture.coordinator.isBusy }
            #expect(await fixture.runtime.authorizationCount == 1)
            #expect(await fixture.runtime.writes.count == 2)
            fixture.close()
        }
    }

    @Test func shutdownDuringRenewalCannotResumeOrWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        try await requestRenewal(fixture)
        fixture.coordinator.shutdown()
        let previous = fixture.coordinator.status
        await fixture.runtime.finishAuthorization()
        for _ in 0..<3 { fixture.monitor.onChange?() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fixture.runtime.writes.count == 1)
        #expect(fixture.coordinator.status == previous)
    }

    @Test func postWriteReadFailureCannotBeMistakenForNoWriteAuthorizationExpiry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        await fixture.runtime.failConfirmation()
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .blocked)
        #expect(fixture.network.dns().servers == ["114.114.114.114"])
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(await fixture.runtime.authorizationCount == 1)
        #expect(await fixture.runtime.writes.count == 2)
    }

    @Test func renewalNeitherResetsNorDoubleCountsExternalOverrideBudget() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await startAuthorized(fixture)
        for index in 1...5 {
            fixture.network.time = Double(index)
            try await requestRenewal(fixture, expectedCount: index + 1)
            await fixture.runtime.finishAuthorization()
            try await eventually { !fixture.coordinator.isBusy }
            #expect(fixture.coordinator.status.phase == .active)
            #expect(await fixture.runtime.writes.count == index + 1)
        }
        fixture.network.time = 6
        await fixture.runtime.expireAuthorization()
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        fixture.monitor.onChange?()
        try await eventually { !fixture.coordinator.isBusy }
        #expect(fixture.coordinator.status.phase == .blocked)
        #expect(await fixture.runtime.authorizationCount == 6)
        #expect(await fixture.runtime.writes.count == 6)
        #expect(fixture.network.dns().servers == ["8.8.8.8"])
    }

    private func startAuthorized(_ fixture: Fixture) async throws {
        fixture.coordinator.start()
        try await eventually { await fixture.runtime.authorizationCount == 1 }
        await fixture.runtime.finishAuthorization()
        try await eventually { !fixture.coordinator.isBusy }
    }

    private func requestRenewal(_ fixture: Fixture, expectedCount: Int = 2) async throws {
        await fixture.runtime.expireAuthorization()
        fixture.network.select("Hotspot", service: "hotspot-service", address: "8.8.8.8")
        fixture.monitor.onChange?()
        try await eventually { await fixture.runtime.authorizationCount == expectedCount }
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        // Other AppKit suites can synchronously occupy MainActor for a long
        // render/layout pass. Count actual scheduling opportunities rather than
        // expiring the deadline while neither this test nor the coordinator runs.
        for _ in 0..<3_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try #require(await predicate())
    }
}

@MainActor
private final class Fixture {
    let configuration = DNSWiFiRulesConfiguration(
        defaultMode: .custom(["114.114.114.114"]),
        rules: [DNSWiFiRule(ssid: "Office", mode: .automatic)])
    let network = NetworkFixture()
    let runtime: RuntimeFixture
    let monitor = MonitorFixture()
    let coordinator: DNSWiFiRulesCoordinator
    private let defaults: UserDefaults
    private let domain = "dev.ftop.tests.dns-coordinator.\(UUID())"

    init(permission: DNSWiFiPermission = .authorized) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        let store = DNSWiFiRulesStore(defaults: defaults)
        try store.save(configuration)
        runtime = RuntimeFixture(network: network)
        monitor.permission = permission
        let network = self.network
        coordinator = DNSWiFiRulesCoordinator(
            runtime: runtime, wifi: monitor, store: store,
            readWiFi: { network.read($0) }, readDNS: { network.dns() },
            debounce: .zero, clock: { network.time })
    }

    func close() {
        coordinator.shutdown()
        defaults.removePersistentDomain(forName: domain)
    }
}

@MainActor
private final class MonitorFixture: DNSWiFiRulesMonitoring {
    var permission = DNSWiFiPermission.authorized
    var onChange: (() -> Void)?
    var startCount = 0
    func start() { startCount += 1 }
    func stop() {}
    func requestAccess() {}
}

private actor RuntimeFixture: DNSWiFiRulesRunning {
    struct Write: Sendable {
        var ssid: String
        var mode: DNSManualMode
        var observation: DNSWiFiRulesObservation
    }
    let network: NetworkFixture
    private let cancellation = DNSWiFiRulesCancellation()
    private var completion: CheckedContinuation<Void, any Error>?
    private var authorized = false
    private var credentialsExpired = false
    private var applyFailure: DNSChangeError?
    private var confirmationFails = false
    private(set) var authorizationCount = 0
    private(set) var writes: [Write] = []

    init(network: NetworkFixture) { self.network = network }
    nonisolated func requestStop() { cancellation.invalidate() }
    nonisolated func operationRevision() -> UInt64 { cancellation.current() }
    func hasAuthorizedSession() -> Bool { authorized }
    func authorize(expectedRevision: UInt64?) async throws {
        authorizationCount += 1
        let revision = expectedRevision ?? cancellation.current()
        try await withCheckedThrowingContinuation { completion = $0 }
        try cancellation.arm(revision)
        credentialsExpired = false
        authorized = true
    }
    func finishAuthorization(error: DNSChangeError? = nil) {
        if let error { completion?.resume(throwing: error) } else { completion?.resume() }
        completion = nil
    }
    func pause() { cancellation.invalidate(); authorized = false }
    func expireAuthorization() { credentialsExpired = true }
    func failConfirmation() { confirmationFails = true }
    func failApply(
        error: DNSChangeError = DNSChangeError(code: .verificationFailed, persistence: .unknown, message: "Fixture uncertain write")
    ) { applyFailure = error }
    func observation() throws -> DNSWiFiRulesObservation { try network.observation() }
    func observation(confirming target: DNSEditTarget) throws -> DNSWiFiRulesObservation {
        if confirmationFails {
            throw DNSChangeError(code: .permissionDenied, message: "Fixture post-write read denied")
        }
        return try network.observation()
    }
    func apply(
        mode: DNSManualMode, expectedSSID: String, permission: DNSWiFiPermission,
        expected: DNSWiFiRulesObservation
    ) throws -> DNSWriteResult {
        try cancellation.check(cancellation.current())
        #expect(authorized)
        if credentialsExpired {
            throw DNSChangeError(code: .permissionDenied, message: "Fixture expired authorization; no write")
        }
        #expect(expected == (try network.observation()))
        #expect(expectedSSID == network.read(permission).ssid)
        writes.append(Write(ssid: expectedSSID, mode: mode, observation: expected))
        if let applyFailure { throw applyFailure }
        network.apply(mode)
        return DNSWriteResult(target: try network.observation().target, state: network.dns())
    }
}

/// Shared only through this lock; no real Wi-Fi, DNS, or authorization is used.
private final class NetworkFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var ssid = "Hotspot"
    private var service = "hotspot-service"
    private var address: String? = "9.9.9.9"
    private var isReady = true
    private var writtenBaseline: DNSWiFiRulesObservation?
    private var now: TimeInterval = 0
    private var metadataRevision = 0
    var time: TimeInterval {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }
    func changeMetadata() { lock.withLock { metadataRevision += 1 } }
    var beforeWrite: DNSWiFiRulesObservation? { lock.withLock { writtenBaseline } }
    var ready: Bool {
        get { lock.withLock { isReady } }
        set { lock.withLock { isReady = newValue } }
    }
    func select(_ ssid: String, service: String, address: String?) {
        lock.withLock {
            self.ssid = ssid; self.service = service; self.address = address
        }
    }
    func read(_ permission: DNSWiFiPermission) -> DNSWiFiReading {
        lock.withLock {
            DNSWiFiReading(
                ssid: ssid, bssid: ssid, interfaceName: "en0", connected: true,
                permission: permission)
        }
    }
    func dns() -> DNSState {
        lock.withLock { DNSState(servers: [address ?? "192.0.2.1"], source: .systemDefault) }
    }
    func observation() throws -> DNSWiFiRulesObservation {
        try lock.withLock {
            guard isReady else {
                throw DNSChangeError(code: .noPhysicalService, message: "Fixture waiting")
            }
            return observationLocked()
        }
    }
    private func observationLocked() -> DNSWiFiRulesObservation {
        DNSWiFiRulesObservation(
            target: DNSEditTarget(
                locationID: "location-\(service)", serviceID: service, serviceName: "Wi-Fi",
                interfaceName: "en0", manualServers: address.map { [$0] } ?? [],
                configurationToken: Data("token-\(service)-\(address ?? "automatic")-\(metadataRevision)".utf8)),
            connectionID: Data(service.utf8),
            configurationFingerprint: Data("\(address ?? "automatic")-\(metadataRevision)".utf8),
            hasManualAddressKey: address != nil)
    }
    func apply(_ mode: DNSManualMode) {
        lock.withLock {
            writtenBaseline = observationLocked(); address = mode.servers.first
        }
    }
}
