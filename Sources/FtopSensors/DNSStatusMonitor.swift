import Foundation
import FtopCore
import SystemConfiguration

/// Observes DNS independently of hardware sampling. Reads happen on a utility
/// queue; there are no lookups, location requests, authorization or writes.
public final class DNSStatusMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ftop.dns.status", qos: .utility)
    private let lock = NSLock()
    private var refreshState = DNSStatusRefreshState()
    private let read: @Sendable () -> DNSState
    private let listen: @Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any DNSStatusObservation)?
    private let debounce: TimeInterval
    private let retryInterval: TimeInterval
    private var observation: (any DNSStatusObservation)?
    private var retry: DispatchSourceTimer?
    private var handler: (@Sendable (DNSState) -> Void)?

    public convenience init() {
        self.init(read: DNSReader.read, listen: DNSDynamicStoreObservation.create, debounce: 0.15, retryInterval: 60)
    }

    init(
        read: @escaping @Sendable () -> DNSState,
        listen: @escaping @Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> (any DNSStatusObservation)?,
        debounce: TimeInterval, retryInterval: TimeInterval
    ) {
        self.read = read
        self.listen = listen
        self.debounce = max(0, debounce)
        self.retryInterval = max(1, retryInterval)
    }

    deinit {
        observation?.stop()
        retry?.cancel()
    }

    /// Restarts the observation and immediately reads a fresh state. `handler`
    /// runs on this monitor's queue, only when the complete DNS state changes.
    public func start(_ handler: @escaping @Sendable (DNSState) -> Void) {
        let generation = lock.withLock { refreshState.start() }
        queue.async { [weak self] in
            guard let self, isCurrent(generation) else { return }
            clearObservation()
            self.handler = handler
            installObservation()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, isCurrent(generation) else { return }
                // A notification registration failure falls back to a current
                // read and retries registration, without retaining stale DNS.
                if observation == nil { installObservation() }
                refresh()
            }
            retry = timer
            timer.resume()
            scheduleRefresh(delay: 0)
        }
    }

    /// Invalidates pending/in-flight reads immediately. Stopping never changes
    /// system DNS; the owner clears its displayed state separately.
    public func stop() {
        let generation = lock.withLock { refreshState.stop() }
        queue.async { [weak self] in
            guard let self, lock.withLock({ refreshState.generation == generation }) else { return }
            clearObservation()
            handler = nil
        }
    }

    /// For wake or another lifecycle hint. Bursts share one delayed read.
    public func refresh() { scheduleRefresh(delay: debounce) }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { refreshState.isCurrent(generation) }
    }

    private func scheduleRefresh(delay: TimeInterval) {
        guard let generation = lock.withLock({ refreshState.request() }) else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, isCurrent(generation) else { return }
            let current = read()
            guard lock.withLock({ refreshState.complete(current, generation: generation) }) else { return }
            handler?(current)
        }
    }

    private func installObservation() {
        observation = listen(queue) { [weak self] in self?.refresh() }
    }

    private func clearObservation() {
        observation?.stop()
        observation = nil
        retry?.cancel()
        retry = nil
    }
}

/// Pure lifecycle/coalescing seam. An unavailable read replaces a previously
/// valid result, and stale completions cannot repopulate a stopped display.
struct DNSStatusRefreshState {
    private(set) var generation: UInt64 = 0
    private var running = false
    private var pending = false
    private var previous: DNSState?

    mutating func start() -> UInt64 {
        generation &+= 1
        running = true
        pending = false
        previous = nil
        return generation
    }

    mutating func stop() -> UInt64 {
        generation &+= 1
        running = false
        pending = false
        previous = nil
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool { running && self.generation == generation }

    mutating func request() -> UInt64? {
        guard running, !pending else { return nil }
        pending = true
        return generation
    }

    mutating func complete(_ current: DNSState, generation: UInt64) -> Bool {
        guard isCurrent(generation), pending else { return false }
        pending = false
        guard previous != current else { return false }
        previous = current
        return true
    }
}

protocol DNSStatusObservation: AnyObject { func stop() }

private final class DNSDynamicStoreCallback: @unchecked Sendable {
    let notify: @Sendable () -> Void
    init(_ notify: @escaping @Sendable () -> Void) { self.notify = notify }
}

private final class DNSDynamicStoreObservation: DNSStatusObservation {
    private let store: SCDynamicStore
    private init(_ store: SCDynamicStore) { self.store = store }

    static func create(queue: DispatchQueue, notify: @escaping @Sendable () -> Void) -> (any DNSStatusObservation)? {
        let callback = DNSDynamicStoreCallback(notify)
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                // The context above always supplies this callback object.
                let retained = Unmanaged<DNSDynamicStoreCallback>.fromOpaque(pointer).retain()
                return UnsafeRawPointer(retained.toOpaque())
            },
            release: { pointer in
                Unmanaged<DNSDynamicStoreCallback>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        guard
            let store = SCDynamicStoreCreate(
                nil, "dev.ftop.dns.status" as CFString,
                { _, _, info in
                    guard let info else { return }
                    Unmanaged<DNSDynamicStoreCallback>.fromOpaque(info).takeUnretainedValue().notify()
                }, &context)
        else { return nil }
        let keys = ["State:/Network/Global/DNS", "State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
        let patterns = [
            "State:/Network/Service/[^/]+/(DNS|IPv4|IPv6)",
            "Setup:/Network/Service/[^/]+(/.*)?", "Setup:/Network/Global/.*",
            "State:/Network/Interface/[^/]+/Link",
        ]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray),
            SCDynamicStoreSetDispatchQueue(store, queue)
        else { return nil }
        return DNSDynamicStoreObservation(store)
    }

    func stop() { _ = SCDynamicStoreSetDispatchQueue(store, nil) }
    deinit { stop() }
}
