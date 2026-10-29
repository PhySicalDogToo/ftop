import Foundation
import FtopCore
import Testing

@testable import FtopSensors

@Suite struct ProcessNetworkProviderTests {
    @Test func initialReadAndFirstBaselineAreLoadingButAnObserverFailureIsUnavailable() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = makeProvider(backend, clock: clock)
        provider.start()
        let waiting = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(waiting.networkStatus.isLoading)
        #expect(waiting.networkStatus.reason == nil)
        #expect(waiting.byDownload.isEmpty)
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        let baseline = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(baseline.networkStatus.isLoading)
        backend.value = .unavailable("fixture failure")
        let failed = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!failed.networkStatus.isLoading)
        #expect(failed.networkStatus.reason == "fixture failure")
        clock.value = 40
        backend.value = .waiting
        let retrying = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(retrying.networkStatus.isLoading)
        provider.stop()
        let stopped = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!stopped.networkStatus.isLoading)
    }

    @Test func repeatedStartPreservesTheObserverBaselineAndAvailableRates() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        var creates = 0
        let provider = ProcessNetworkProvider(
            makeBackend: {
                creates += 1; return backend
            },
            identify: { pid in ProcessNetworkProcessInfo(identity: ProcessNetworkIdentity(pid: pid, uniqueID: 70), name: "fixture", appPath: nil) },
            currentUniqueID: { _ in 70 }, clock: { clock.value })
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("no helper"))
        provider.start()
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        let next = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(next.networkStatus.isAvailable)
        #expect(next.byDownload.first?.network?.downloadBytesPerSecond == 100)
        provider.start()
        let repeated = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(repeated.networkStatus.isAvailable)
        #expect(creates == 1)
        #expect(backend.stops == 0)
        provider.stop()
        provider.start()
        let restarted = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(restarted.networkStatus.isLoading)
        #expect(creates == 2)
        #expect(backend.stops == 1)
    }

    @Test func repeatedStartCannotBypassAnObserverFailureBackoff() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        var creates = 0
        let provider = ProcessNetworkProvider(
            makeBackend: {
                creates += 1; return backend
            },
            identify: { _ in nil }, currentUniqueID: { _ in 0 }, clock: { clock.value })
        provider.start()
        backend.value = .unavailable("fixture failure")
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 20
        provider.start()
        let failed = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!failed.networkStatus.isLoading)
        #expect(failed.networkStatus.reason == "fixture failure")
        #expect(creates == 1)
        clock.value = 40
        backend.value = .waiting
        let retried = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(retried.networkStatus.isLoading)
        #expect(creates == 2)
    }

    @Test func firstFrameIsUnavailableAndStableZeroIsRealZero() throws {
        var rates = ProcessNetworkRates()
        let first = rates.consume(frame(1, 10, [counter(1, received: 100)]))
        #expect(first == nil)
        let nextRows = rates.consume(frame(2, 12, [counter(1, received: 100)]))
        let next = try #require(nextRows?.first)
        #expect(next.sample.downloadBytesPerSecond == 0)
        #expect(next.sample.uploadBytesPerSecond == 0)
    }

    @Test func tenSecondRefreshUsesTheFullWindowAndDoesNotRepeatNewOrRemovedSourceBytes() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = makeProvider(backend, clock: clock)
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100, sent: 100), counter(3, received: 200, sent: 200)]))
        let baseline = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(baseline.networkStatus.isLoading)

        var born = counter(2, received: 1_000_300, sent: 2_000_200)
        born.initialReceived = 1_000_000
        born.initialSent = 2_000_000
        born.initialTimestamp = 15
        var removed = counter(3, received: 500, sent: 500)
        removed.removed = true
        clock.value = 20
        backend.value = .frame(frame(2, 20, [counter(1, received: 1100, sent: 300), born, removed]))
        let longWindow = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(longWindow.networkStatus.isAvailable)
        // Existing: 1000/10, born: 300/10, removed: 300/10.
        #expect(longWindow.byDownload.first?.network?.downloadBytesPerSecond == 160)
        #expect(longWindow.byUpload.first?.network?.uploadBytesPerSecond == 70)

        born.received += 200
        born.sent += 40
        clock.value = 22
        backend.value = .frame(frame(3, 22, [counter(1, received: 1300, sent: 340), born, removed]))
        let following = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(following.networkStatus.isAvailable)
        // Only the two live sources advanced; neither initial nor final bytes repeat.
        #expect(following.byDownload.first?.network?.downloadBytesPerSecond == 200)
        #expect(following.byUpload.first?.network?.uploadBytesPerSecond == 40)
    }

    @Test func aNewSocketCannotHideExistingTrafficOrInjectItsHistory() throws {
        var rates = ProcessNetworkRates()
        _ = rates.consume(frame(1, 10, [counter(1, received: 100)]))
        let sampled = rates.consume(frame(2, 12, [counter(1, received: 300), counter(2, received: 9_000_000)]))
        let rows = try #require(sampled)
        #expect(rows.count == 1)
        #expect(rows.first?.sample.downloadBytesPerSecond == 100)
    }

    @Test func aNewSourceUsesOnlyItsObservedInWindowIncrement() throws {
        var rates = ProcessNetworkRates()
        _ = rates.consume(frame(1, 10, []))
        var source = counter(2, received: 1_000_500)
        source.initialReceived = 1_000_000
        source.initialSent = 0
        source.initialTimestamp = 11
        let sampled = rates.consume(frame(2, 12, [source]))
        let rows = try #require(sampled)
        #expect(rows.first?.sample.downloadBytesPerSecond == 250)
    }

    @Test func removalAndLateFinalCountersNeverSubtractOrRepeatLifetimeTotals() throws {
        var rates = ProcessNetworkRates()
        _ = rates.consume(frame(1, 10, [counter(1, received: 100)]))
        var removed = counter(1, received: 300)
        removed.removed = true
        let finalRows = rates.consume(frame(2, 12, [removed]))
        let final = try #require(finalRows)
        #expect(final.first?.sample.downloadBytesPerSecond == 100)
        removed.received = 340
        let lateRows = rates.consume(frame(3, 14, [removed]))
        let late = try #require(lateRows)
        #expect(late.first?.sample.downloadBytesPerSecond == 20)
        let emptyRows = rates.consume(frame(4, 16, []))
        let empty = try #require(emptyRows)
        #expect(empty.isEmpty)
    }

    @Test func resetsOwnershipChangesAndMalformedFramesRequireFreshBaselines() throws {
        var rates = ProcessNetworkRates()
        _ = rates.consume(frame(1, 10, [counter(1, received: 100)]))
        let resetRows = rates.consume(frame(2, 12, [counter(1, received: 10)]))
        let reset = try #require(resetRows)
        #expect(reset.isEmpty)
        var reused = counter(1, received: 1000)
        reused.uniqueID = 999
        let changedRows = rates.consume(frame(3, 14, [reused]))
        let changed = try #require(changedRows)
        #expect(changed.isEmpty)
        let duplicate = rates.consume(frame(4, 16, [reused, reused]))
        #expect(duplicate == nil)
        let restarted = rates.consume(frame(5, 18, [reused]))
        #expect(restarted == nil)
    }

    @Test func networkRankingSurvivesHelperFailureAndNeverBorrowsUsageByPID() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = makeProvider(backend, clock: clock)
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("helper failed"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        let known = ProcessSample(pid: 7, name: "old-process", cpuPercent: 99, memoryBytes: 999)
        let list = try #require(provider.sample(base: .value(ProcessList(top: [known], coversAllUsers: false))).value)
        #expect(list.networkStatus.isAvailable)
        #expect(list.byDownload.first?.network?.downloadBytesPerSecond == 100)
        #expect(list.byDownload.first?.usageAvailable == false)
        #expect(list.top.first?.network == nil)
        let withoutHelper = try #require(provider.sample(base: .unavailable("helper failed")).value)
        #expect(withoutHelper.byDownload.count == 1)
        #expect(withoutHelper.top.isEmpty)
    }

    @Test func reusedPIDCannotReceiveThePreviousInstancesTraffic() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = ProcessNetworkProvider(
            makeBackend: { backend },
            identify: { pid in ProcessNetworkProcessInfo(identity: ProcessNetworkIdentity(pid: pid, uniqueID: 99), name: "new", appPath: nil) },
            currentUniqueID: { _ in 99 },
            clock: { clock.value })
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("helper failed"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        let list = try #require(provider.sample(base: .unavailable("helper failed")).value)
        #expect(list.byDownload.isEmpty)
        #expect(list.networkStatus.isAvailable)
    }

    @Test func repeatedGenerationIsCachedAndBusyReadRetainsOnlyFreshData() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = makeProvider(backend, clock: clock)
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        _ = provider.sample(base: .unavailable("no helper"))
        let repeated = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(repeated.byDownload.first?.network?.downloadBytesPerSecond == 100)
        backend.value = .waiting
        let busy = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(busy.networkStatus.isAvailable)
        clock.value = 19
        let stale = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!stale.networkStatus.isAvailable)
        #expect(stale.byDownload.isEmpty)
        #expect(backend.stops == 1)
    }

    @Test func failureBacksOffAndExplicitStopPreventsAutomaticRestart() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        var creates = 0
        let provider = ProcessNetworkProvider(
            makeBackend: {
                creates += 1; return backend
            }, identify: { _ in nil }, currentUniqueID: { _ in 0 }, clock: { clock.value })
        provider.start()
        backend.value = .unavailable("fixture unavailable")
        let failed = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!failed.networkStatus.isAvailable)
        clock.value = 39
        _ = provider.sample(base: .unavailable("no helper"))
        #expect(creates == 1)
        clock.value = 40
        backend.value = .waiting
        _ = provider.sample(base: .unavailable("no helper"))
        #expect(creates == 2)
        provider.stop()
        clock.value = 100
        _ = provider.sample(base: .unavailable("no helper"))
        #expect(creates == 2)
    }

    @Test func completeNetworkCandidateSetIsFoldedBeforeTheNinetySixLimit() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = ProcessNetworkProvider(
            makeBackend: { backend },
            identify: { pid in
                ProcessNetworkProcessInfo(
                    identity: ProcessNetworkIdentity(pid: pid, uniqueID: UInt64(pid)), name: "process-\(pid)",
                    appPath: pid <= 100 ? "/Applications/Grouped.app" : nil)
            }, currentUniqueID: { UInt64($0) }, clock: { clock.value })
        var counters = (1...220).map { index in
            ProcessNetworkCounter(sourceID: UInt64(index), pid: Int32(index), uniqueID: UInt64(index), name: "fixture", received: 0, sent: 0)
        }
        provider.start()
        backend.value = .frame(frame(1, 10, counters))
        _ = provider.sample(base: .unavailable("no helper"))
        for index in counters.indices { counters[index].received = index < 100 ? 20 : 100 }
        clock.value = 12
        backend.value = .frame(frame(2, 12, counters))
        let list = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(list.byDownload.count == 96)
        #expect(list.byDownload.first?.appPath == "/Applications/Grouped.app")
        #expect(list.byDownload.first?.network?.downloadBytesPerSecond == 1000)
    }

    @Test func repeatedTicksReuseMetadataWhileEachNewFrameRefreshesIt() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        var metadataReads = 0
        var identityReads = 0
        var appPath = "/Applications/Before.app"
        let provider = ProcessNetworkProvider(
            makeBackend: { backend },
            identify: { pid in
                metadataReads += 1
                return ProcessNetworkProcessInfo(
                    identity: ProcessNetworkIdentity(pid: pid, uniqueID: 70), name: "fixture", appPath: appPath)
            },
            currentUniqueID: { _ in
                identityReads += 1; return 70
            }, clock: { clock.value })
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        _ = provider.sample(base: .unavailable("no helper"))
        #expect(metadataReads == 1)
        #expect(identityReads == 0)
        appPath = "/Applications/After.app"
        clock.value = 12.5
        let currentUsage = ProcessSample(pid: 7, name: "current helper sample", cpuPercent: 77, memoryBytes: 888, appPath: "/Applications/Before.app")
        let repeated = try #require(provider.sample(base: .value(ProcessList(top: [currentUsage], coversAllUsers: false))).value)
        #expect(metadataReads == 1)
        #expect(identityReads == 1)
        #expect(repeated.byDownload.first?.appPath == "/Applications/Before.app")
        #expect(repeated.top.first?.cpuPercent == 77)
        #expect(repeated.top.first?.memoryBytes == 888)
        #expect(repeated.top.first?.network?.downloadBytesPerSecond == 100)
        clock.value = 14
        backend.value = .frame(frame(3, 14, [counter(1, received: 500)]))
        let next = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(metadataReads == 2)
        #expect(next.byDownload.first?.appPath == "/Applications/After.app")
        #expect(next.byDownload.first?.network?.downloadBytesPerSecond == 100)
    }

    @Test func cachedMetadataCannotKeepExitedOrReusedProcessesOnTheList() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        var current: UInt64 = 70
        let provider = ProcessNetworkProvider(
            makeBackend: { backend },
            identify: { pid in
                guard current > 0 else { return nil }
                return ProcessNetworkProcessInfo(identity: ProcessNetworkIdentity(pid: pid, uniqueID: current), name: "fixture", appPath: nil)
            }, currentUniqueID: { _ in current }, clock: { clock.value })
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        let live = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(live.byDownload.count == 1)
        current = 0
        let exited = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(exited.byDownload.isEmpty)
        current = 99
        let reused = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(reused.byDownload.isEmpty)
    }

    @Test func repeatedGenerationCannotExtendTheCompletedSamplesLifetime() throws {
        let backend = FakeNetworkBackend()
        let clock = NetworkTestClock()
        let provider = makeProvider(backend, clock: clock)
        provider.start()
        backend.value = .frame(frame(1, 10, [counter(1, received: 100)]))
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 12
        backend.value = .frame(frame(2, 12, [counter(1, received: 300)]))
        _ = provider.sample(base: .unavailable("no helper"))
        clock.value = 19
        backend.value = .frame(frame(2, 19, [counter(1, received: 300)]))
        let changedTimestamp = try #require(provider.sample(base: .unavailable("no helper")).value)
        #expect(!changedTimestamp.networkStatus.isAvailable)
        #expect(changedTimestamp.byDownload.isEmpty)
        #expect(backend.stops == 1)
    }

    private func frame(_ generation: UInt64, _ timestamp: Double, _ rows: [ProcessNetworkCounter]) -> ProcessNetworkFrame {
        ProcessNetworkFrame(generation: generation, timestamp: timestamp, counters: rows)
    }

    private func counter(_ source: UInt64, received: UInt64, sent: UInt64 = 0) -> ProcessNetworkCounter {
        ProcessNetworkCounter(sourceID: source, pid: 7, uniqueID: 70, name: "fixture", received: received, sent: sent)
    }

    private func makeProvider(_ backend: FakeNetworkBackend, clock: NetworkTestClock) -> ProcessNetworkProvider {
        ProcessNetworkProvider(
            makeBackend: { backend },
            identify: { pid in ProcessNetworkProcessInfo(identity: ProcessNetworkIdentity(pid: pid, uniqueID: 70), name: "fixture", appPath: nil) },
            currentUniqueID: { _ in 70 },
            clock: { clock.value })
    }
}

private final class FakeNetworkBackend: ProcessNetworkBackend {
    var value = ProcessNetworkBackendReading.waiting
    var stops = 0
    func read() -> ProcessNetworkBackendReading { value }
    func stop() { stops += 1 }
}

private final class NetworkTestClock { var value: Double = 10 }
