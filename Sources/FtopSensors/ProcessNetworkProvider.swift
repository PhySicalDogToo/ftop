import CFtopSys
import Darwin
import Foundation
import FtopCore

struct ProcessNetworkCounter: Sendable, Equatable {
    var sourceID: UInt64
    var pid: Int32
    var uniqueID: UInt64
    var name: String
    var received: UInt64
    var sent: UInt64
    var removed = false
    var initialReceived: UInt64?
    var initialSent: UInt64?
    var initialTimestamp: TimeInterval?
}

struct ProcessNetworkFrame: Sendable {
    var generation: UInt64
    var timestamp: TimeInterval
    var counters: [ProcessNetworkCounter]
}

struct ProcessNetworkIdentity: Hashable, Sendable {
    var pid: Int32
    var uniqueID: UInt64
}

struct ProcessNetworkRate: Sendable {
    var identity: ProcessNetworkIdentity
    var name: String
    var sample: ProcessNetworkSample
}

/// The unit of differencing is one socket source, never a process's sum of
/// currently open sockets. Removing a source cannot subtract its lifetime total.
struct ProcessNetworkRates {
    private var previous: [UInt64: ProcessNetworkCounter] = [:]
    private var timestamp: TimeInterval?

    mutating func reset() { previous = [:]; timestamp = nil }

    mutating func consume(_ frame: ProcessNetworkFrame) -> [ProcessNetworkRate]? {
        guard frame.counters.count <= 16384, frame.timestamp.isFinite,
            Set(frame.counters.map(\.sourceID)).count == frame.counters.count,
            frame.counters.allSatisfy({ $0.sourceID > 0 })
        else { reset(); return nil }
        let old = previous
        let oldTime = timestamp
        previous = Dictionary(uniqueKeysWithValues: frame.counters.map { ($0.sourceID, $0) })
        timestamp = frame.timestamp
        guard let oldTime else { return nil }
        let elapsed = frame.timestamp - oldTime
        // Hardware refresh can be ten seconds. The provider checks how fresh
        // each completed frame is; the differencing window may be longer.
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        var totals: [ProcessNetworkIdentity: (String, Double, Double)] = [:]
        for counter in frame.counters where counter.pid > 0 && counter.uniqueID > 0 {
            let identity = ProcessNetworkIdentity(pid: counter.pid, uniqueID: counter.uniqueID)
            let received: UInt64
            let sent: UInt64
            if let baseline = old[counter.sourceID], baseline.pid == counter.pid, baseline.uniqueID == counter.uniqueID,
                counter.received >= baseline.received, counter.sent >= baseline.sent
            {
                received = counter.received - baseline.received
                sent = counter.sent - baseline.sent
            } else if let initialTime = counter.initialTimestamp, initialTime >= oldTime, initialTime <= frame.timestamp,
                let initialReceived = counter.initialReceived, let initialSent = counter.initialSent,
                counter.received >= initialReceived, counter.sent >= initialSent
            {
                received = counter.received - initialReceived
                sent = counter.sent - initialSent
            } else {
                continue
            }
            let before = totals[identity] ?? (counter.name, 0, 0)
            totals[identity] = (
                counter.name, before.1 + Double(received) / elapsed, before.2 + Double(sent) / elapsed
            )
        }
        return totals.compactMap { identity, total in
            guard total.1.isFinite, total.2.isFinite else { return nil }
            return ProcessNetworkRate(
                identity: identity, name: total.0,
                sample: ProcessNetworkSample(downloadBytesPerSecond: total.1, uploadBytesPerSecond: total.2))
        }
    }
}

enum ProcessNetworkBackendReading {
    case waiting
    case unavailable(String)
    case frame(ProcessNetworkFrame)
}

protocol ProcessNetworkBackend: AnyObject {
    func read() -> ProcessNetworkBackendReading
    func stop()
}

private final class NativeProcessNetworkBackend: ProcessNetworkBackend {
    private var sampler: OpaquePointer?
    private var buffer = [ftop_process_network_counter](repeating: ftop_process_network_counter(), count: 16384)
    private var decodedFrame: ProcessNetworkFrame?

    init?() {
        guard let value = ftop_process_network_create() else { return nil }
        sampler = value
    }

    deinit { stop() }

    func stop() {
        if let sampler { ftop_process_network_destroy(sampler) }
        sampler = nil
        decodedFrame = nil
    }

    func read() -> ProcessNetworkBackendReading {
        guard let sampler else { return .unavailable("the network observer has stopped") }
        var generation: UInt64 = 0
        var timestamp: Double = 0
        let capacity = Int32(buffer.count)
        let count = ftop_process_network_copy(sampler, &buffer, capacity, &generation, &timestamp)
        guard count >= 0 else {
            switch count {
            case -1: return .waiting
            case -3: return .unavailable("too many socket sources to report safely")
            case -4: return .unavailable("the network observer stopped completing fresh queries")
            default: return .unavailable("macOS did not provide readable socket traffic counters")
            }
        }
        // A completed native generation is immutable. Keep calling copy so its
        // failure/freshness checks run, but decode its rows only once.
        if let decodedFrame, decodedFrame.generation == generation { return .frame(decodedFrame) }
        let rows = buffer.prefix(Int(count)).map { value in
            var value = value
            let name = withUnsafeBytes(of: &value.name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ProcessNetworkCounter(
                sourceID: value.source_id, pid: value.pid, uniqueID: value.process_unique_id, name: name,
                received: value.received_bytes, sent: value.sent_bytes, removed: value.removed != 0,
                initialReceived: value.initial_received_bytes, initialSent: value.initial_sent_bytes,
                initialTimestamp: value.initial_timestamp > 0 ? value.initial_timestamp : nil)
        }
        let frame = ProcessNetworkFrame(generation: generation, timestamp: timestamp, counters: rows)
        decodedFrame = frame
        return .frame(frame)
    }
}

struct ProcessNetworkProcessInfo {
    var identity: ProcessNetworkIdentity
    var name: String
    var appPath: String?
}

/// Called on the hardware sampler queue, but the native observer owns an
/// independent queue and two-second timer. A read copies completed state only.
final class ProcessNetworkProvider {
    static let note =
        "TCP/UDP socket activity, including local and proxy connections. TUN may appear under both app and proxy; totals are not physical-interface throughput. Other userland providers may be unavailable. Only sampled connections are counted; first observations or very short-lived connections may be missed."
    private let makeBackend: () -> (any ProcessNetworkBackend)?
    private let identify: (Int32) -> ProcessNetworkProcessInfo?
    private let currentUniqueID: (Int32) -> UInt64
    private let clock: () -> TimeInterval
    private var backend: (any ProcessNetworkBackend)?
    private var rates = ProcessNetworkRates()
    private var generation: UInt64?
    private var cached: [ProcessNetworkRate]?
    private var cachedTimestamp: TimeInterval?
    private var processMetadata: [ProcessNetworkIdentity: ProcessNetworkProcessInfo] = [:]
    private var active = false
    private var retryAt: TimeInterval = 0
    private var failure = "waiting for two completed network samples"
    private var isLoading = false

    init(
        makeBackend: @escaping () -> (any ProcessNetworkBackend)? = { NativeProcessNetworkBackend() },
        identify: @escaping (Int32) -> ProcessNetworkProcessInfo? = ProcessNetworkProvider.processInfo,
        currentUniqueID: @escaping (Int32) -> UInt64 = { ftop_process_unique_id($0) },
        clock: @escaping () -> TimeInterval = { ftop_process_network_clock() }
    ) {
        self.makeBackend = makeBackend
        self.identify = identify
        self.currentUniqueID = currentUniqueID
        self.clock = clock
    }

    deinit { stop() }

    func start() {
        guard !active else { return }
        active = true
        backend = makeBackend()
        retryAt = clock() + 30
        failure = backend == nil ? "the macOS socket statistics observer is unavailable" : "waiting for two completed network samples"
        isLoading = backend != nil
    }

    func stop() {
        active = false
        teardown()
        isLoading = false
        failure = "per-process network traffic is not being collected"
    }

    private func teardown() {
        backend?.stop()
        backend = nil
        rates.reset()
        generation = nil
        cached = nil
        cachedTimestamp = nil
        processMetadata = [:]
    }

    func sample(base: Reading<ProcessList>) -> Reading<ProcessList> {
        if active, backend == nil, clock() >= retryAt {
            backend = makeBackend()
            retryAt = clock() + 30
            if backend != nil {
                failure = "waiting for two completed network samples"
                isLoading = true
            }
        }
        if let backend {
            switch backend.read() {
            case .waiting:
                if let cachedTimestamp, clock() - cachedTimestamp > 6 { fail("the network observer stopped completing fresh queries") }
            case .unavailable(let reason): fail(reason)
            case .frame(let frame):
                let now = clock()
                guard frame.timestamp.isFinite, now >= frame.timestamp, now - frame.timestamp <= 6,
                    frame.counters.count <= 16384, frame.generation > 0
                else { fail("invalid or stale socket traffic counters"); return merged(base: base, rows: nil) }
                if generation != frame.generation {
                    guard Set(frame.counters.map(\.sourceID)).count == frame.counters.count,
                        frame.counters.allSatisfy({ $0.sourceID > 0 })
                    else { fail("invalid or stale socket traffic counters"); return merged(base: base, rows: nil) }
                    if let generation, frame.generation < generation { rates.reset() }
                    generation = frame.generation
                    processMetadata = [:]
                    cached = rates.consume(frame)
                    cachedTimestamp = frame.timestamp
                    failure = "waiting for two completed network samples"
                    isLoading = cached == nil
                } else if cachedTimestamp != frame.timestamp {
                    // Reusing a generation must never extend the cached sample's
                    // lifetime by presenting a different completion time.
                    fail("invalid or stale socket traffic counters")
                    return merged(base: base, rows: nil)
                }
            }
        }
        return merged(base: base, rows: cached)
    }

    private func fail(_ reason: String) {
        teardown()
        retryAt = clock() + 30
        failure = reason
        isLoading = false
    }

    private func merged(base: Reading<ProcessList>, rows: [ProcessNetworkRate]?) -> Reading<ProcessList> {
        var list = base.value ?? ProcessList(top: [], coversAllUsers: false)
        list.networkNote = Self.note
        guard let rows else {
            list.networkStatus = isLoading ? .loading : .unavailable(failure)
            list.byDownload = []
            list.byUpload = []
            return .value(list)
        }
        let entries = rows.compactMap { row -> ProcessSample? in
            let process: ProcessNetworkProcessInfo
            if let cached = processMetadata[row.identity] {
                // Metadata lives for one completed generation, but liveness and
                // process identity are still checked on every hardware tick.
                guard currentUniqueID(row.identity.pid) == row.identity.uniqueID else {
                    processMetadata.removeValue(forKey: row.identity)
                    return nil
                }
                process = cached
            } else {
                guard let fresh = identify(row.identity.pid), fresh.identity == row.identity else { return nil }
                processMetadata[row.identity] = fresh
                process = fresh
            }
            return ProcessSample(
                pid: row.identity.pid, name: process.name, cpuPercent: 0, memoryBytes: 0,
                appPath: process.appPath, network: row.sample, usageAvailable: false)
        }
        // Fold the complete observed candidate set before applying either limit.
        let down = ProcessSample.folded(entries, by: .download)
        let up = ProcessSample.folded(entries, by: .upload)
        list.byDownload = Array(down.prefix(96))
        list.byUpload = Array(up.prefix(96))
        list.networkStatus = .available
        let networks = Dictionary(uniqueKeysWithValues: down.compactMap { value in value.appPath.map { ($0, value.network) } })
        func attaching(_ values: [ProcessSample]) -> [ProcessSample] {
            values.map { value in
                var result = value
                result.network = value.appPath.flatMap { networks[$0] ?? nil }
                return result
            }
        }
        list.top = attaching(list.top)
        list.byMemory = attaching(list.byMemory)
        return .value(list)
    }

    private static func processInfo(_ pid: Int32) -> ProcessNetworkProcessInfo? {
        let unique = ftop_process_unique_id(pid)
        guard unique > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let app = length > 0 ? ProcessSample.appPath(ofExecutable: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) : nil
        guard ftop_process_unique_id(pid) == unique else { return nil }
        return ProcessNetworkProcessInfo(
            identity: ProcessNetworkIdentity(pid: pid, uniqueID: unique),
            name: name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, appPath: app)
    }
}
