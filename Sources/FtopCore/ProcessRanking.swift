import Foundation

/// Keeps a ranked list from reshuffling on every sample.
///
/// Readings of busy processes cross each other all the time, so a list sorted by the
/// current reading never rests. This ranks by a level that rises with the reading at
/// once and falls slowly, and lets an entry pass another only when it is clearly ahead.
public struct SteadyRanking: Sendable {
    /// An entry passes another when its level is above the other's by this share of it…
    public var relative: Double
    /// …plus this much, in the unit of the readings.
    public var margin: Double
    /// Seconds for a level to lose about two thirds of its distance to a lower reading.
    public var fall: Double

    private var levels: [String: Double] = [:]
    private var order: [String] = []

    public init(relative: Double, margin: Double, fall: Double) {
        self.relative = relative
        self.margin = margin
        self.fall = fall
    }

    /// For processor use in percent of one core.
    public static var cpu: SteadyRanking { SteadyRanking(relative: 0.12, margin: 1, fall: 4) }
    /// For memory in bytes.
    public static var memory: SteadyRanking { SteadyRanking(relative: 0.04, margin: 24 * 1_048_576, fall: 4) }
    /// For process traffic in bytes per second, with an independent state per direction.
    public static var download: SteadyRanking { SteadyRanking(relative: 0.12, margin: 1_000, fall: 4) }
    public static var upload: SteadyRanking { .download }

    /// The order to show `entries` in, `elapsed` seconds after the last call. With `hold`
    /// nothing already listed changes rank; entries that left are dropped and new ones go last.
    /// `unavailableIDs` clears their old levels without losing their place during a hold.
    public mutating func step(
        _ entries: [(id: String, value: Double)], elapsed: Double, hold: Bool = false, unavailableIDs: [String] = []
    ) -> [String] {
        let keep = fall > 0 ? exp(-max(0, elapsed) / fall) : 0
        var next: [String: Double] = [:]
        for entry in entries where next[entry.id] == nil {
            next[entry.id] = levels[entry.id].map { max(entry.value, entry.value + ($0 - entry.value) * keep) } ?? entry.value
        }
        levels = next

        let unavailable = Set(unavailableIDs)
        var result = order.filter { next[$0] != nil || (hold && unavailable.contains($0)) }
        let known = Set(result)
        var seen = known
        let arrivals = entries.filter { seen.insert($0.id).inserted }.enumerated()
            .sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }
        result += arrivals.map(\.element.id)
        // Arrivals are placed even under a hold when there was no list before.
        if !hold || known.isEmpty {
            for index in result.indices.dropFirst() {
                let level = next[result[index]]!
                guard let target = result[..<index].firstIndex(where: { level > next[$0]! * (1 + relative) + margin }) else { continue }
                result.insert(result.remove(at: index), at: target)
            }
        }
        var present = Set(result)
        result += unavailableIDs.filter { present.insert($0).inserted }
        order = result
        return result
    }
}

extension ProcessList {
    private static func arrange(
        _ samples: [ProcessSample], ranking: inout SteadyRanking, elapsed: Double, hold: Bool, value: (ProcessSample) -> Double?
    ) -> [ProcessSample] {
        let byID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let readings = samples.compactMap { sample -> (id: String, value: Double)? in
            guard let value = value(sample), value.isFinite, value >= 0 else { return nil }
            return (sample.id, value)
        }
        // Unknown values are not ranked as zero and cannot retain an old measured level.
        let measured = Set(readings.map(\.id))
        let unavailable = samples.filter { !measured.contains($0.id) }.map(\.id)
        return ranking.step(readings, elapsed: elapsed, hold: hold, unavailableIDs: unavailable).compactMap { byID[$0] }
    }

    /// Keeps the existing CPU and memory call site available without owning any
    /// traffic ranking state. New callers should use the four-ranking overload.
    public func steadied(cpu: inout SteadyRanking, memory: inout SteadyRanking, elapsed: Double, hold: Bool) -> ProcessList {
        var list = self
        list.top = Self.arrange(top, ranking: &cpu, elapsed: elapsed, hold: hold) { $0.usageAvailable ? $0.cpuPercent : nil }
        list.byMemory = Self.arrange(byMemory, ranking: &memory, elapsed: elapsed, hold: hold) { $0.usageAvailable ? Double($0.memoryBytes) : nil }
        return list
    }

    /// Four independent orders. Unavailable traffic clears its previous state;
    /// values in the returned rows remain the current readings, not the ranking levels.
    public func steadied(
        cpu: inout SteadyRanking, memory: inout SteadyRanking, download: inout SteadyRanking, upload: inout SteadyRanking, elapsed: Double, hold: Bool
    ) -> ProcessList {
        var list = steadied(cpu: &cpu, memory: &memory, elapsed: elapsed, hold: hold)
        if networkStatus.isAvailable {
            list.byDownload = Self.arrange(byDownload, ranking: &download, elapsed: elapsed, hold: hold) { $0.network?.downloadBytesPerSecond }
            list.byUpload = Self.arrange(byUpload, ranking: &upload, elapsed: elapsed, hold: hold) { $0.network?.uploadBytesPerSecond }
        } else {
            _ = download.step([], elapsed: elapsed, hold: hold)
            _ = upload.step([], elapsed: elapsed, hold: hold)
            list.byDownload = []
            list.byUpload = []
        }
        return list
    }
}
