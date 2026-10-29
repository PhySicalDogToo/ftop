import Foundation
import FtopCore
import FtopSensors

struct SmokeEvent: Sendable {
    let phase: String
    let state: String
    let time: TimeInterval
}

enum SmokeFailure: Error { case timeout(String), unexpected(String) }

final class SmokeRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [SmokeEvent] = []

    func receive(_ snapshot: Snapshot, phase: String) {
        let status = snapshot.processes.value?.networkStatus
        let state: String
        if status?.isAvailable == true { state = "available" }
        else if status?.isLoading == true { state = "loading" }
        else if status == .notCollected { state = "stopped" }
        else { state = "unavailable" }
        condition.lock()
        events.append(SmokeEvent(phase: phase, state: state, time: ProcessInfo.processInfo.systemUptime))
        condition.broadcast()
        condition.unlock()
    }

    func wait(_ phase: String, state: String? = nil, seconds: TimeInterval, after: TimeInterval = 0) throws -> SmokeEvent {
        condition.lock()
        defer { condition.unlock() }
        let until = Date().addingTimeInterval(seconds)
        while true {
            if let event = events.first(where: { $0.phase == phase && $0.time >= after && (state == nil || $0.state == state) }) { return event }
            guard condition.wait(until: until) else { throw SmokeFailure.timeout(phase) }
        }
    }
}

@main struct RetentionSmoke {
    static func main() {
        do { try run() } catch {
            let result = ["success": false, "error": String(describing: error)] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            exit(1)
        }
    }

    static func run() throws {
        let recorder = SmokeRecorder()
        let sampler = SystemSampler()
        defer { sampler.stop() }
        func start(_ phase: String, wanted: Bool, interval: TimeInterval = 0.5) {
            sampler.start(interval: interval, modules: [.processes], processNetwork: wanted) { recorder.receive($0, phase: phase) }
        }

        let begin = ProcessInfo.processInfo.systemUptime
        start("cold", wanted: true)
        let coldFirst = try recorder.wait("cold", seconds: 3)
        guard coldFirst.state == "loading" else { throw SmokeFailure.unexpected("cold did not load") }
        let initialReady = try recorder.wait("cold", state: "available", seconds: 12)
        start("cpu-warm", wanted: false)
        guard try recorder.wait("cpu-warm", seconds: 3).state == "available" else { throw SmokeFailure.unexpected("grace did not retain") }
        Thread.sleep(forTimeInterval: 3)
        start("warm-return", wanted: true)
        guard try recorder.wait("warm-return", seconds: 3).state == "available" else { throw SmokeFailure.unexpected("warm return restarted baseline") }

        let departure = ProcessInfo.processInfo.systemUptime
        start("cpu-expire", wanted: false)
        guard try recorder.wait("cpu-expire", seconds: 3).state == "available" else { throw SmokeFailure.unexpected("second grace did not retain") }
        let expired = try recorder.wait("cpu-expire", state: "stopped", seconds: 23)
        let elapsed = expired.time - departure
        guard elapsed >= 19.8 && elapsed < 21 else { throw SmokeFailure.unexpected("grace deadline outside tolerance") }
        start("cold-return", wanted: true)
        guard try recorder.wait("cold-return", seconds: 3).state == "loading" else { throw SmokeFailure.unexpected("expired source reused") }
        _ = try recorder.wait("cold-return", state: "available", seconds: 12)
        let slowStart = ProcessInfo.processInfo.systemUptime
        start("slow-refresh", wanted: true, interval: 10)
        _ = try recorder.wait("slow-refresh", state: "available", seconds: 14, after: slowStart + 9)
        sampler.stop()
        let stopped = sampler.sampleNow()
        guard stopped.processes.value?.networkStatus == .notCollected else { throw SmokeFailure.unexpected("explicit stop retained source") }

        let result: [String: Any] = [
            "date": "2026-10-20", "ordinary_user": true, "bundled_unprivileged_helper": true,
            "cold_initial_state": coldFirst.state,
            "initial_ready_seconds": (initialReady.time - begin),
            "warm_return_first_state": "available",
            "grace_stop_seconds": elapsed,
            "expired_return_first_state": "loading",
            "ten_second_refresh_remains_available": true,
            "explicit_stop_state": "stopped",
            "extra_network_traffic": false,
            "scope": "Real production SystemSampler and native observer, process module only, no GUI; no process identifiers, names or addresses retained."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
