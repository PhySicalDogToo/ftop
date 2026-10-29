import Foundation

/// Queue-confined demand for the comparatively slow-starting socket observer.
/// Switching away starts one fixed grace period; unrelated sampler restarts do
/// not move its deadline. The scheduler must deliver on the caller's serial queue.
final class ProcessNetworkCollectionController: @unchecked Sendable {
    static let defaultGracePeriod: TimeInterval = 20
    typealias Cancellation = () -> Void
    typealias Scheduler = (TimeInterval, @escaping @Sendable () -> Void) -> Cancellation

    private let clock: () -> TimeInterval
    private let schedule: Scheduler
    private let startProvider: () -> Void
    private let stopProvider: () -> Void
    private let onGraceExpired: () -> Void
    private let gracePeriod: TimeInterval
    private var cancelStop: Cancellation?
    private var stopToken: UInt64 = 0
    private(set) var isCollecting = false
    private(set) var stopDeadline: TimeInterval?

    init(
        gracePeriod: TimeInterval = ProcessNetworkCollectionController.defaultGracePeriod,
        clock: @escaping () -> TimeInterval,
        schedule: @escaping Scheduler,
        start: @escaping () -> Void,
        stop: @escaping () -> Void,
        onGraceExpired: @escaping () -> Void = {}
    ) {
        self.gracePeriod = gracePeriod
        self.clock = clock
        self.schedule = schedule
        self.startProvider = start
        self.stopProvider = stop
        self.onGraceExpired = onGraceExpired
    }

    func update(wanted: Bool, eligible: Bool) {
        guard eligible else { stopImmediately(); return }
        expireIfDue()
        if wanted {
            cancelPendingStop()
            startIfNeeded()
        } else if isCollecting, stopDeadline == nil {
            stopDeadline = clock() + gracePeriod
            stopToken &+= 1
            scheduleStop(after: gracePeriod, token: stopToken)
        }
    }

    /// CLI sampling does not own a visible ranking and therefore has no grace.
    func updateImmediately(wanted: Bool) {
        expireIfDue()
        if wanted {
            cancelPendingStop()
            startIfNeeded()
        } else {
            stopImmediately()
        }
    }

    func stopImmediately() {
        cancelPendingStop()
        guard isCollecting else { return }
        isCollecting = false
        stopProvider()
    }

    private func startIfNeeded() {
        guard !isCollecting else { return }
        isCollecting = true
        startProvider()
    }

    private func cancelPendingStop() {
        stopToken &+= 1
        cancelStop?()
        cancelStop = nil
        stopDeadline = nil
    }

    private func scheduleStop(after delay: TimeInterval, token: UInt64) {
        cancelStop = schedule(delay) { [weak self] in self?.finishStop(token: token) }
    }

    private func expireIfDue() {
        guard let stopDeadline, clock() >= stopDeadline else { return }
        stopImmediately()
        onGraceExpired()
    }

    private func finishStop(token: UInt64) {
        guard token == stopToken, let stopDeadline else { return }
        let remaining = stopDeadline - clock()
        // An early scheduler callback must not shorten the advertised grace.
        if remaining > 0 {
            scheduleStop(after: remaining, token: token)
        } else {
            stopImmediately()
            onGraceExpired()
        }
    }
}
