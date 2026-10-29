import Foundation
import FtopCore
import Testing

@testable import FtopSensors

@Suite struct DNSStatusMonitorTests {
    @Test func changesCoalesceAndIdenticalReadsDoNotPublishAgain() throws {
        var state = DNSStatusRefreshState()
        let generation = state.start()
        #expect(state.request() == generation)
        #expect(state.request() == nil)
        let current = DNSState(servers: ["192.0.2.53"], source: .systemDefault)
        let first = state.complete(current, generation: generation)
        #expect(first)
        #expect(state.request() == generation)
        let identical = state.complete(current, generation: generation)
        #expect(!identical)
        var changed = current
        changed.primaryInterface = "utun7"
        #expect(state.request() == generation)
        let publishedChange = state.complete(changed, generation: generation)
        #expect(publishedChange)
    }

    @Test func unavailableReadReplacesSuccessAndRecoveryPublishesAgain() {
        var state = DNSStatusRefreshState()
        let generation = state.start()
        let current = DNSState(servers: ["192.0.2.53"], source: .systemDefault)
        _ = state.request()
        let success = state.complete(current, generation: generation)
        #expect(success)
        _ = state.request()
        let failure = state.complete(DNSState(unavailableReason: "fixture read failure"), generation: generation)
        #expect(failure)
        _ = state.request()
        let recovery = state.complete(current, generation: generation)
        #expect(recovery)
    }

    @Test func stoppingRejectsPendingReadsAndReenablingAlwaysPublishesFreshState() {
        var state = DNSStatusRefreshState()
        let old = state.start()
        _ = state.request()
        _ = state.stop()
        #expect(state.request() == nil)
        let current = DNSState(servers: ["192.0.2.53"], source: .systemDefault)
        let stoppedCompletion = state.complete(current, generation: old)
        #expect(!stoppedCompletion)
        let fresh = state.start()
        #expect(fresh != old)
        #expect(state.request() == fresh)
        let staleCompletion = state.complete(current, generation: old)
        #expect(!staleCompletion)
        let freshCompletion = state.complete(current, generation: fresh)
        #expect(freshCompletion)
    }

    @Test func failedRegistrationStillReadsTheCurrentStateWithoutNativeAccess() async {
        let expected = DNSState(servers: ["192.0.2.53"], source: .systemDefault)
        let monitor = DNSStatusMonitor(read: { expected }, listen: { _, _ in nil }, debounce: 0, retryInterval: 60)
        let value = await withCheckedContinuation { continuation in
            monitor.start { current in continuation.resume(returning: current) }
        }
        monitor.stop()
        #expect(value == expected)
    }
}
