import Foundation
import Testing

@testable import FtopCore

@Suite struct ProcessNetworkTests {
    private func sample(
        _ pid: Int32, down: Double? = nil, up: Double = 0, cpu: Double = 10, memory: UInt64 = 100,
        app: String? = nil, usageAvailable: Bool = true
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, name: "process \(pid)", cpuPercent: cpu, memoryBytes: memory, appPath: app,
            network: down.map { ProcessNetworkSample(downloadBytesPerSecond: $0, uploadBytesPerSecond: up) }, usageAvailable: usageAvailable)
    }

    @Test func oldProcessJSONHasNoInventedNetworkReading() throws {
        let data = Data(
            #"{"top":[{"pid":7,"name":"Old app","cpuPercent":25,"memoryBytes":512,"members":[{"name":"Helper","cpuPercent":10,"memoryBytes":128}]}],"byMemory":[],"coversAllUsers":true,"helperOutdated":false}"#
                .utf8)
        let list = try JSONDecoder().decode(ProcessList.self, from: data)
        #expect(list.top[0].usageAvailable)
        #expect(list.top[0].network == nil)
        #expect(list.top[0].members[0].usageAvailable)
        #expect(list.top[0].members[0].network == nil)
        #expect(list.byDownload.isEmpty && list.byUpload.isEmpty)
        #expect(list.networkStatus == .notCollected)
        #expect(list.networkStatus.reason != nil)
        #expect(list.entries(sortedBy: .download).isEmpty)
        #expect(list.entries(sortedBy: .cpu) == list.top)
    }

    @Test func loadingNeverPresentsOldTrafficAndRoundTrips() throws {
        let entry = sample(1, down: 1234)
        let list = ProcessList(top: [entry], coversAllUsers: false, byDownload: [entry], byUpload: [entry], networkStatus: .loading)
        let decoded = try JSONDecoder().decode(ProcessList.self, from: JSONEncoder().encode(list))
        #expect(decoded.networkStatus.isLoading)
        #expect(!decoded.networkStatus.isAvailable)
        #expect(decoded.networkStatus.reason == nil)
        #expect(decoded.entries(sortedBy: .download).isEmpty)
        #expect(decoded.entries(sortedBy: .upload).isEmpty)
        #expect(decoded.entries(sortedBy: .cpu) == [entry])
        #expect(!ProcessNetworkStatus.notCollected.isLoading)
        #expect(!ProcessNetworkStatus.unavailable("reader failed").isLoading)
    }

    @Test func newNetworkValuesAndUnknownUsageRoundTrip() throws {
        var entry = sample(1, down: 0, up: 123_456, cpu: 0, memory: 0, usageAvailable: false)
        entry.members = [ProcessMember(name: "network helper", cpuPercent: 0, memoryBytes: 0, network: entry.network, usageAvailable: false)]
        let list = ProcessList(
            top: [], coversAllUsers: false, byDownload: [entry], byUpload: [entry], networkStatus: .available,
            networkNote: "Traffic can be attributed to a VPN core")
        let decoded = try JSONDecoder().decode(ProcessList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(!decoded.byDownload[0].usageAvailable)
        #expect(!decoded.byDownload[0].members[0].usageAvailable)
        #expect(decoded.byDownload[0].network?.downloadBytesPerSecond == 0)
        #expect(decoded.networkStatus.isAvailable)
        #expect(decoded.networkStatus.reason == nil)
        let unavailable = ProcessNetworkStatus.unavailable("reader stopped")
        #expect(try JSONDecoder().decode(ProcessNetworkStatus.self, from: JSONEncoder().encode(unavailable)) == unavailable)
    }

    @Test func emptyNetworkRankingIsDifferentFromUnavailable() {
        let busyCPU = sample(1, cpu: 900)
        var list = ProcessList(top: [busyCPU], coversAllUsers: true, networkStatus: .available)
        #expect(list.networkStatus.isAvailable)
        #expect(list.entries(sortedBy: .download).isEmpty)
        #expect(list.entries(sortedBy: .memory).isEmpty)
        list.byDownload = [sample(2, down: 0)]
        #expect(list.entries(sortedBy: .download).count == 1)
        list.networkStatus = .unavailable("permission denied")
        #expect(list.entries(sortedBy: .download).isEmpty)
        #expect(list.entries(sortedBy: .cpu) == [busyCPU])
        #expect(list.networkStatus.reason == "permission denied")
    }

    @Test func networkSortConfigurationKeepsOldDefaults() throws {
        #expect(!ProcessSort.cpu.isNetwork && !ProcessSort.memory.isNetwork)
        #expect(ProcessSort.download.isNetwork && ProcessSort.upload.isNetwork)
        #expect(try Config.decode(Data("{}".utf8)).processSort == .cpu)
        for sort in ProcessSort.allCases {
            let config = try Config.decode(Data("{processSort: \"\(sort.rawValue)\"}".utf8))
            #expect(config.processSort == sort)
            #expect(try Config.decode(JSONEncoder().encode(config)) == config)
        }
        #expect(throws: (any Error).self) { try Config.decode(Data(#"{processSort:"disk"}"#.utf8)) }
    }

    @Test func completeCandidateAppsAreFoldedBeforeChoosingTheTopRows() throws {
        let path = "/Applications/Many Helpers.app"
        let helpers = (1...120).map { sample(Int32($0), down: 100, up: Double($0), app: path) }
        let competitor = sample(999, down: 10_000, up: 20_000)
        let candidates = helpers + [competitor]
        let download = ProcessSample.folded(candidates, by: .download)
        let first = try #require(download.first)
        #expect(download.prefix(1).map(\.appPath) == [path])
        #expect(first.network?.downloadBytesPerSecond == 12_000)
        #expect(first.network?.uploadBytesPerSecond == 7_260)
        #expect(first.members.count == 120)
        #expect(first.usageAvailable)
        let upload = ProcessSample.folded(candidates, by: .upload)
        #expect(upload.first?.pid == competitor.pid)
        #expect(upload.last?.members.first?.network?.uploadBytesPerSecond == 120)
    }

    @Test func unknownMembersPreventFabricatedCompleteAppTotals() throws {
        let path = "/Applications/Mixed.app"
        let first = sample(1, down: 100, up: 20, app: path)
        let second = sample(2, cpu: 0, memory: 0, app: path, usageAvailable: false)
        let folded = try #require(ProcessSample.folded([first, second], by: .download).first)
        #expect(folded.network == nil)
        #expect(!folded.usageAvailable)
        #expect(folded.members.map(\.usageAvailable) == [true, false])
        #expect(folded.members[0].network == first.network)
        #expect(folded.members[1].network == nil)
        let knownZero = sample(3, down: 0)
        let unknown = sample(4)
        #expect(ProcessSample.folded([unknown, folded, knownZero], by: .download).first?.pid == knownZero.pid)
        let unknownUsage = sample(5, cpu: 999, memory: 999, usageAvailable: false)
        #expect(ProcessSample.folded([unknownUsage, first], by: .cpu).first?.pid == first.pid)
        #expect(ProcessSample.folded([unknownUsage, first], by: .memory).first?.pid == first.pid)
    }

    @Test func allFourRankingsPreserveTrafficAndAvailabilityDuringCPUConversion() {
        var entry = sample(1, down: 1234, up: 5678, cpu: 400, memory: 1024)
        entry.members = [ProcessMember(name: "helper", cpuPercent: 200, memoryBytes: 512, network: entry.network, usageAvailable: false)]
        let list = ProcessList(
            top: [entry], byMemory: [entry], coversAllUsers: true, byDownload: [entry], byUpload: [entry], networkStatus: .available, networkNote: "source"
        )
        .asShareOfMachine(cores: 8)
        for sort in ProcessSort.allCases {
            let converted = list.entries(sortedBy: sort)[0]
            #expect(converted.cpuPercent == 50)
            #expect(converted.members[0].cpuPercent == 25)
            #expect(converted.network == entry.network)
            #expect(converted.members[0].network == entry.network)
            #expect(!converted.members[0].usageAvailable)
            #expect(converted.usageAvailable)
        }
        #expect(list.networkStatus == .available && list.networkNote == "source")
    }

    @Test func fourSteadyOrdersAreIndependentAndKeepCurrentValues() {
        var cpu = SteadyRanking.cpu
        var memory = SteadyRanking.memory
        var download = SteadyRanking.download
        var upload = SteadyRanking.upload
        let a = sample(1, down: 1_000, up: 20_000, cpu: 100, memory: 100)
        let b = sample(2, down: 20_000, up: 1_000, cpu: 1, memory: 1_000)
        let initial = ProcessList(
            top: [a, b], byMemory: [b, a], coversAllUsers: true, byDownload: [b, a], byUpload: [a, b], networkStatus: .available)
        let first = initial.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 0, hold: false)
        #expect(first.top.map(\.pid) == [1, 2])
        #expect(first.byMemory.map(\.pid) == [2, 1])
        #expect(first.byDownload.map(\.pid) == [2, 1])
        #expect(first.byUpload.map(\.pid) == [1, 2])
        let changedA = sample(1, down: 900_000, up: 0, cpu: 0, memory: 10_000)
        let changedB = sample(2, down: 0, up: 900_000, cpu: 900, memory: 0)
        let changed = ProcessList(
            top: [changedB, changedA], byMemory: [changedA, changedB], coversAllUsers: true,
            byDownload: [changedA, changedB], byUpload: [changedB, changedA], networkStatus: .available)
        let held = changed.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: true)
        for sort in ProcessSort.allCases { #expect(held.entries(sortedBy: sort).map(\.pid) == first.entries(sortedBy: sort).map(\.pid)) }
        #expect(held.byDownload.first?.network?.downloadBytesPerSecond == 0)
        #expect(held.byUpload.first?.network?.uploadBytesPerSecond == 0)
        #expect(held.top.first?.cpuPercent == 0)
    }

    @Test func unavailableTrafficClearsOrdersBeforeAReaderRestarts() {
        var cpu = SteadyRanking.cpu
        var memory = SteadyRanking.memory
        var download = SteadyRanking.download
        var upload = SteadyRanking.upload
        let first = sample(1, down: 100_000, up: 100_000)
        let second = sample(2, down: 1, up: 1)
        var list = ProcessList(top: [], coversAllUsers: true, byDownload: [first, second], byUpload: [first, second], networkStatus: .available)
        _ = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 0, hold: false)
        list.networkStatus = .unavailable("reader stopped")
        let missing = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: false)
        #expect(missing.byDownload.isEmpty && missing.byUpload.isEmpty)
        list.networkStatus = .available
        list.byDownload = [sample(2, down: 0), sample(1, down: 0)]
        list.byUpload = list.byDownload
        let resumed = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: true)
        #expect(resumed.byDownload.map(\.pid) == [2, 1])
        #expect(resumed.byUpload.map(\.pid) == [2, 1])
    }

    @Test func anUnknownRateDoesNotRetainItsPreviousMeasuredLevel() {
        var cpu = SteadyRanking.cpu
        var memory = SteadyRanking.memory
        var download = SteadyRanking.download
        var upload = SteadyRanking.upload
        var list = ProcessList(
            top: [], coversAllUsers: true, byDownload: [sample(1, down: 100_000), sample(2, down: 10_000)], networkStatus: .available)
        _ = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 0, hold: false)
        list.byDownload = [sample(1), sample(2, down: 10_000)]
        let unknown = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: false)
        #expect(unknown.byDownload.map(\.pid) == [2, 1])
        #expect(unknown.byDownload.last?.network == nil)
        list.byDownload = [sample(1, down: 5_000), sample(2, down: 10_000)]
        let known = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: false)
        #expect(known.byDownload.map(\.pid) == [2, 1])
    }

    @Test func unknownRatesKeepTheirRowUnderAHoldWithoutRetainingTheirLevel() {
        var cpu = SteadyRanking.cpu
        var memory = SteadyRanking.memory
        var download = SteadyRanking.download
        var upload = SteadyRanking.upload
        var list = ProcessList(
            top: [], coversAllUsers: true, byDownload: [sample(1, down: 100_000), sample(2, down: 10_000)], networkStatus: .available)
        _ = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 0, hold: false)
        list.byDownload = [sample(1), sample(2, down: 10_000), sample(3)]
        let held = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: true)
        #expect(held.byDownload.map(\.pid) == [1, 2, 3])
        #expect(held.byDownload.first?.network == nil)
        list.byDownload = [sample(1, down: 5_000), sample(2, down: 10_000)]
        let released = list.steadied(cpu: &cpu, memory: &memory, download: &download, upload: &upload, elapsed: 1, hold: false)
        #expect(released.byDownload.map(\.pid) == [2, 1])
    }
}
