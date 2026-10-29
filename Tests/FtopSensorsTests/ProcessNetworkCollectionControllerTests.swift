import Foundation
import Testing

@testable import FtopSensors

@Suite struct ProcessNetworkCollectionControllerTests {
    @Test func cpuOnlyNeverStartsAnObserverOrAGraceTimer() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: false, eligible: true)
        fixture.scheduler.advance(to: 100)
        fixture.controller.update(wanted: false, eligible: true)
        #expect(fixture.starts == 0)
        #expect(fixture.stops == 0)
        #expect(fixture.scheduler.tasks.isEmpty)
        #expect(!fixture.controller.isCollecting)
    }

    @Test func leavingNetworkKeepsReadingUntilExactlyTwentySeconds() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        #expect(fixture.controller.stopDeadline == 20)
        fixture.scheduler.advance(to: 19.999)
        #expect(fixture.controller.isCollecting)
        #expect(fixture.stops == 0)
        #expect(fixture.expirations == 0)
        fixture.scheduler.advance(to: 20)
        #expect(!fixture.controller.isCollecting)
        #expect(fixture.controller.stopDeadline == nil)
        #expect(fixture.stops == 1)
        #expect(fixture.expirations == 1)
        fixture.scheduler.advance(to: 40)
        #expect(fixture.stops == 1)
        #expect(fixture.expirations == 1)
    }

    @Test func repeatedCPUAndMemoryOrIntervalRestartsDoNotExtendTheDeadline() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        for time in [1.0, 5, 12, 19] {
            fixture.scheduler.advance(to: time)
            fixture.controller.update(wanted: false, eligible: true)
            #expect(fixture.controller.stopDeadline == 20)
        }
        #expect(fixture.scheduler.tasks.count == 1)
        fixture.scheduler.advance(to: 20)
        #expect(fixture.stops == 1)
        #expect(!fixture.controller.isCollecting)
    }

    @Test func returningToEitherNetworkSortKeepsTheSameObserver() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        fixture.scheduler.advance(to: 19)
        fixture.controller.update(wanted: true, eligible: true)
        #expect(fixture.controller.stopDeadline == nil)
        fixture.scheduler.advance(to: 30)
        #expect(fixture.controller.isCollecting)
        #expect(fixture.starts == 1)
        #expect(fixture.stops == 0)
        #expect(fixture.expirations == 0)
        fixture.controller.update(wanted: false, eligible: true)
        #expect(fixture.controller.stopDeadline == 50)
        fixture.scheduler.advance(to: 50)
        #expect(fixture.stops == 1)
    }

    @Test func anAlreadyEnqueuedCancelledTimerCannotStopAReturnedOrNewReader() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        let cancelled = fixture.scheduler.tasks[0]
        fixture.scheduler.advance(to: 10)
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        fixture.scheduler.now = 20
        cancelled.callback()
        #expect(fixture.controller.isCollecting)
        #expect(fixture.controller.stopDeadline == 30)
        #expect(fixture.stops == 0)
        fixture.scheduler.advance(to: 30)
        #expect(fixture.stops == 1)
    }

    @Test func hideOrSamplerStopCancelsGraceAndStopsImmediately() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        fixture.scheduler.advance(to: 5)
        fixture.controller.stopImmediately()
        #expect(!fixture.controller.isCollecting)
        #expect(fixture.controller.stopDeadline == nil)
        #expect(fixture.stops == 1)
        fixture.scheduler.advance(to: 40)
        #expect(fixture.stops == 1)
        #expect(fixture.expirations == 0)
        fixture.controller.update(wanted: true, eligible: true)
        #expect(fixture.starts == 2)
    }

    @Test func menuBarOnlyOrDisabledProcessModuleStopsWithoutGrace() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        fixture.controller.update(wanted: true, eligible: false)
        #expect(!fixture.controller.isCollecting)
        #expect(fixture.controller.stopDeadline == nil)
        #expect(fixture.stops == 1)
        fixture.controller.update(wanted: false, eligible: false)
        fixture.scheduler.advance(to: 40)
        #expect(fixture.starts == 1)
        #expect(fixture.stops == 1)
        #expect(fixture.expirations == 0)
    }

    @Test func CLITrueIsIdempotentAndCLIFalseStopsImmediately() {
        let fixture = CollectionFixture()
        fixture.controller.updateImmediately(wanted: true)
        fixture.controller.updateImmediately(wanted: true)
        #expect(fixture.starts == 1)
        fixture.controller.updateImmediately(wanted: false)
        #expect(!fixture.controller.isCollecting)
        #expect(fixture.stops == 1)
        #expect(fixture.scheduler.tasks.isEmpty)
        #expect(fixture.expirations == 0)
    }

    @Test func earlyCallbacksRescheduleTheRemainderAndNeverShortenGrace() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        fixture.scheduler.now = 10
        fixture.scheduler.tasks[0].callback()
        #expect(fixture.controller.isCollecting)
        #expect(fixture.scheduler.tasks.last?.deadline == 20)
        fixture.scheduler.advance(to: 20)
        #expect(fixture.stops == 1)
        #expect(fixture.expirations == 1)
    }

    @Test func returningAfterTheDeadlineCannotRescueAnExpiredBaseline() {
        let fixture = CollectionFixture()
        fixture.controller.update(wanted: true, eligible: true)
        fixture.controller.update(wanted: false, eligible: true)
        // The callback may already be queued behind a busy sampler operation.
        fixture.scheduler.now = 20
        fixture.controller.update(wanted: true, eligible: true)
        #expect(fixture.stops == 1)
        #expect(fixture.starts == 2)
        #expect(fixture.expirations == 1)
        #expect(fixture.controller.isCollecting)
        #expect(fixture.controller.stopDeadline == nil)
        fixture.scheduler.advance(to: 30)
        #expect(fixture.stops == 1)
    }
}

private final class CollectionFixture {
    let scheduler = CollectionTestScheduler()
    var starts = 0
    var stops = 0
    var expirations = 0
    lazy var controller = ProcessNetworkCollectionController(
        clock: { [scheduler] in scheduler.now },
        schedule: { [scheduler] delay, callback in scheduler.schedule(after: delay, callback: callback) },
        start: { [unowned self] in starts += 1 },
        stop: { [unowned self] in stops += 1 },
        onGraceExpired: { [unowned self] in expirations += 1 })
}

private final class CollectionTestScheduler {
    final class Task {
        let deadline: TimeInterval
        let callback: @Sendable () -> Void
        var cancelled = false
        var delivered = false
        init(deadline: TimeInterval, callback: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.callback = callback
        }
    }

    var now: TimeInterval = 0
    var tasks: [Task] = []

    func schedule(after delay: TimeInterval, callback: @escaping @Sendable () -> Void) -> () -> Void {
        let task = Task(deadline: now + delay, callback: callback)
        tasks.append(task)
        return { task.cancelled = true }
    }

    func advance(to time: TimeInterval) {
        now = time
        while let task = tasks.first(where: { !$0.cancelled && !$0.delivered && $0.deadline <= time }) {
            task.delivered = true
            task.callback()
        }
    }
}
