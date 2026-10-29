import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

enum ProcessNetworkFixture {
    static func snapshot(unavailable: Bool = false, status: ProcessNetworkStatus? = nil) -> Snapshot {
        var snapshot = Snapshot.sample(performance: 10, efficiency: 4)
        snapshot.time = Date()
        let cpu = ProcessSample(pid: 1, name: "Processor app", cpuPercent: 180, memoryBytes: 1 << 29)
        let memory = ProcessSample(pid: 2, name: "Memory app", cpuPercent: 2, memoryBytes: 8 << 30)
        let download = ProcessSample(
            pid: 3, name: "Downloader", cpuPercent: 0, memoryBytes: 0,
            members: [
                .init(
                    name: "Network helper", cpuPercent: 0, memoryBytes: 0,
                    network: .init(downloadBytesPerSecond: 12_300_000, uploadBytesPerSecond: 2100), usageAvailable: false)
            ],
            network: .init(downloadBytesPerSecond: 12_300_000, uploadBytesPerSecond: 2100), usageAvailable: false)
        let upload = ProcessSample(
            pid: 4, name: "Uploader", cpuPercent: 5, memoryBytes: 1 << 28,
            network: .init(downloadBytesPerSecond: 0, uploadBytesPerSecond: 8_900_000))
        snapshot.processes = .value(
            ProcessList(
                top: [cpu, memory], byMemory: [memory, cpu], coversAllUsers: false,
                byDownload: [download, upload], byUpload: [upload, download],
                networkStatus: status ?? (unavailable ? .unavailable("Process traffic reader unavailable") : .available),
                networkNote:
                    "TCP/UDP socket activity, including local and proxy connections. TUN may appear under both app and proxy; totals are not physical-interface throughput. Other userland providers may be unavailable. Only sampled connections are counted; first observations or very short-lived connections may be missed."
            ))
        return snapshot
    }
}

@MainActor
@Suite struct ProcessNetworkUITests {
    static let candidates = [
        LayoutCandidate(tier: .full, processCount: 5),
        LayoutCandidate(tier: .full, columns: 2, processCount: 5, memoryList: true),
        LayoutCandidate(tier: .strip, strip: .rich),
    ]

    static func scene(_ sort: ProcessSort, candidate: LayoutCandidate, snapshot: Snapshot = ProcessNetworkFixture.snapshot(), scale: Double = 1) -> Scene {
        var builder = SceneBuilder(
            snapshot: snapshot, machine: MachineShape(performance: 10, efficiency: 4), modules: ModuleID.allCases, style: PanelStyle(scale: scale, motion: false))
        builder.processSort = sort
        return builder.build(candidate)
    }

    @Test func selectionIsSharedByWideNarrowAndRichStrip() throws {
        for sort in ProcessSort.allCases {
            let expected =
                switch sort {
                case .cpu: "Processor app"
                case .memory: "Memory app"
                case .download: "Downloader"
                case .upload: "Uploader"
                }
            for candidate in Self.candidates {
                let scene = Self.scene(sort, candidate: candidate)
                if candidate.tier == .strip {
                    #expect(scene.texts.contains { $0.string == expected })
                    #expect(
                        scene.shapes.contains {
                            if case .badge(let glyph, _) = $0.kind { return glyph == ProcessPresentation.glyph(sort) }; return false
                        })
                } else {
                    let rows = try #require(scene.processes?.rows)
                    #expect(rows.first?.name == expected)
                    if sort.isNetwork { #expect(rows.allSatisfy { $0.share == 0 }) }
                }
                FitSweepTests.expectWellFormed(scene, "\(candidate) \(sort)")
            }
        }
        let wide = Self.scene(.upload, candidate: Self.candidates[1])
        let sorts = wide.clicks.compactMap { click -> ProcessSort? in if case .sort(let sort) = click.action { sort } else { nil } }
        #expect(sorts == ProcessSort.allCases)
    }

    @Test func unavailableNeverFallsBackToCPUOrFabricatesZero() {
        for sort in [ProcessSort.download, .upload] {
            for candidate in Self.candidates {
                let scene = Self.scene(sort, candidate: candidate, snapshot: ProcessNetworkFixture.snapshot(unavailable: true))
                #expect(scene.processes == nil)
                #expect(!scene.texts.contains { ["Processor app", "Downloader", "Uploader"].contains($0.string) })
                #expect(scene.texts.contains { $0.string == "—" })
                #expect(scene.hovers.contains { $0.text.contains("Process traffic reader unavailable") })
            }
        }
    }

    @Test func loadingAppearsInEveryProcessFormWithoutChangingGeometry() {
        defer { Strings.language = .auto }
        for language in [Language.en, .zh] {
            Strings.language = language
            for sort in [ProcessSort.download, .upload] {
                for candidate in Self.candidates {
                    for scale in [0.76, 1, 1.3] {
                        let scene = Self.scene(sort, candidate: candidate, snapshot: ProcessNetworkFixture.snapshot(status: .loading), scale: scale)
                        let available = Self.scene(sort, candidate: candidate, scale: scale)
                        #expect(scene.size == available.size)
                        #expect(scene.processes == nil)
                        #expect(scene.texts.contains { $0.string == ProcessPresentation.loadingText })
                        #expect(scene.hovers.contains { $0.text == ProcessPresentation.loadingText })
                        #expect(!scene.texts.contains { ["Downloader", "Uploader"].contains($0.string) })
                        FitSweepTests.expectWellFormed(scene, "loading \(language) \(candidate) \(sort) x\(scale)")
                    }
                }
            }
        }
    }

    @Test func loadingUnavailableAndQuietSamplesRemainDistinct() {
        defer { Strings.language = .auto }
        for language in [Language.en, .zh] {
            Strings.language = language
            #expect(
                ProcessPresentation.placeholder(ProcessNetworkFixture.snapshot(status: .loading).processes.value, sortedBy: .download) == ProcessPresentation.loadingText)
            #expect(ProcessPresentation.placeholder(ProcessNetworkFixture.snapshot(status: .loading).processes.value, sortedBy: .cpu) == "—")
            for status in [ProcessNetworkStatus.available, .notCollected, .unavailable("reader failed")] {
                let list = ProcessNetworkFixture.snapshot(status: status).processes.value
                #expect(ProcessPresentation.placeholder(list, sortedBy: .download) == "—")
                #expect(ProcessPresentation.emptyReason(list, sortedBy: .download) != ProcessPresentation.loadingText)
            }
            #expect(
                ProcessPresentation.emptyReason(ProcessNetworkFixture.snapshot(status: .unavailable("reader failed")).processes.value, sortedBy: .upload).contains(
                    "reader failed"))
        }
    }

    @Test func validZeroAndMissingReadingsStayDistinct() throws {
        let scene = Self.scene(.download, candidate: Self.candidates[0])
        let rows = try #require(scene.processes?.rows)
        let downloading = try #require(rows.first)
        #expect(downloading.value == "12.3")
        #expect(downloading.unit == "MB/s")
        #expect(downloading.card.cpu == "—")
        #expect(downloading.card.memory == "—")
        #expect(downloading.card.members.first?.value == "12.3")
        #expect(rows.last?.value == "0")
        #expect(rows.last?.unit == "KB/s")
        #expect(ProcessPresentation.rate(nil).number == "—")
        #expect(ProcessPresentation.rate(.infinity).number == "—")
        #expect(ProcessPresentation.rate(-1).number == "—")
        #expect(ProcessPresentation.rate(.greatestFiniteMagnitude).number == ">999")
    }

    @Test func reusedBarePIDNeverJoinsOldUsageIntoNetworkOnlyEntry() throws {
        var snapshot = ProcessNetworkFixture.snapshot()
        var list = try #require(snapshot.processes.value)
        let old = ProcessSample(pid: 3, name: "Exited process with reused PID", cpuPercent: 140, memoryBytes: 9 << 30)
        list.top.append(old)
        list.byMemory.append(old)
        snapshot.processes = .value(list)
        let scene = Self.scene(.download, candidate: Self.candidates[0], snapshot: snapshot)
        let row = try #require(scene.processes?.rows.first)
        #expect(row.name == "Downloader")
        #expect(row.card.cpu == "—")
        #expect(row.card.memory == "—")
        #expect(row.value == "12.3")
    }

    @Test func everyModeAndReadingUsesFixedGeometry() {
        var quiet = ProcessNetworkFixture.snapshot()
        quiet.processes = .value(ProcessList(top: [], coversAllUsers: false, networkStatus: .available))
        let unavailable = ProcessNetworkFixture.snapshot(unavailable: true)
        var extreme = ProcessNetworkFixture.snapshot()
        if var list = extreme.processes.value {
            list.byDownload[0].network = .init(downloadBytesPerSecond: .greatestFiniteMagnitude, uploadBytesPerSecond: .nan)
            list.byUpload[0].network = .init(downloadBytesPerSecond: .infinity, uploadBytesPerSecond: .greatestFiniteMagnitude)
            extreme.processes = .value(list)
        }
        for candidate in LayoutLadder.candidates(maxProcesses: 24, showsProcesses: true) {
            for scale in [0.76, 1, 1.3] {
                let size = Self.scene(.cpu, candidate: candidate, scale: scale).size
                for sort in ProcessSort.allCases {
                    for snapshot in [ProcessNetworkFixture.snapshot(), quiet, unavailable, extreme, ProcessNetworkFixture.snapshot(status: .loading)] {
                        let scene = Self.scene(sort, candidate: candidate, snapshot: snapshot, scale: scale)
                        #expect(scene.size == size, "\(candidate) \(sort) x\(scale)")
                        FitSweepTests.expectWellFormed(scene, "\(candidate) \(sort) x\(scale)")
                        if let rows = scene.processes {
                            let room = PanelStyle(scale: scale).processFigureRoom
                            for row in rows.rows {
                                let style = PanelStyle(scale: scale)
                                let measured = Typesetter.width(row.value, style.bodyStrong) + style.processUnitGap + Typesetter.width(row.unit, style.caption)
                                #expect(measured <= room)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func cardFitsFourMetricsMembersAndCollectorNote() throws {
        Strings.language = .en
        defer { Strings.language = .auto }
        let scene = Self.scene(.download, candidate: Self.candidates[0])
        var card = try #require(scene.processes?.rows.first?.card)
        #expect(card.networkNote?.contains("proxy") == true)
        card.members = Array(repeating: .init(name: "An unusually long helper process name", value: ">999", unit: "GB/s"), count: 4)
        for note in [card.networkNote, String(repeating: "代理连接与物理接口的统计范围不同。", count: 100)] {
            card.networkNote = note
            let layout = ProcessCardLayout(card)
            let bounds = CGRect(origin: .zero, size: layout.size)
            #expect(layout.metricFrames.count == 4)
            #expect(layout.metricFrames[2].minY > layout.metricFrames[0].maxY)
            #expect(layout.metricFrames.allSatisfy(bounds.contains))
            #expect(layout.memberFrames.allSatisfy(bounds.contains))
            #expect(layout.noteFrames.allSatisfy(bounds.contains))
            #expect(layout.noteLines.count <= PanelStyle.processCardNoteMaximumLines)
            #expect(layout.size.width <= PanelStyle.processCardMaximumWidth)
            for (line, frame) in zip(layout.noteLines, layout.noteFrames) {
                #expect(Typesetter.width(line, PanelStyle().caption) <= frame.width)
            }
        }
    }

    @Test func knownCollectorScopeIsLocalizedAndDiagnosticsArePreserved() {
        Strings.language = .zh
        defer { Strings.language = .auto }
        let translated = ProcessPresentation.localizedNote(ProcessPresentation.socketScope)
        #expect(translated?.contains("物理网卡") == true)
        #expect(translated?.contains("部分应用") == true)
        #expect(translated?.contains("首次观察") == true)
        #expect(ProcessPresentation.localizedReason(ProcessNetworkStatus.notCollected.reason) == nil)
        #expect(ProcessPresentation.localizedReason("error 42") == "error 42")
        #expect(ProcessPresentation.localizedNote("socket error 42") == "socket error 42")
    }

    @Test func controlMenuSelectsAllFourModesThroughItsOwnActions() throws {
        _ = NSApplication.shared
        for language in [Language.en, .zh] {
            Strings.language = language
            defer { Strings.language = .auto }
            var config = Config()
            config.language = language
            let face = ControlFace(state: .init(config: config))
            #expect(face.processRankingRowFrame == nil)
            face.expand()
            face.frame = CGRect(origin: .zero, size: face.fittingSize)
            let row = try #require(face.processRankingRowFrame)
            #expect(face.bounds.contains(row))
            #expect(!row.intersects(try #require(face.dnsRowFrame)))
            var selected: [(ProcessSort, String, String)] = []
            face.onChange = { config, key, value in selected.append((config.processSort, key, value)) }
            for (index, sort) in ProcessSort.allCases.enumerated() {
                let menu = face.makeProcessSortMenu()
                #expect(menu.items.count == 4)
                let item = menu.items[index]
                #expect(item.title == ControlPanel.name(of: sort))
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
                #expect(selected.last?.0 == sort)
                #expect(selected.last?.1 == "processSort")
                #expect(selected.last?.2 == "\"\(sort.rawValue)\"")
                #expect(face.makeProcessSortMenu().items[index].state == .on)
            }
        }
    }

    @Test func processCardOmitsCollectionInstructionButKeepsRealDiagnostics() throws {
        defer { Strings.language = .auto }
        for language in [Language.en, .zh] {
            Strings.language = language
            let idle = Self.scene(.cpu, candidate: Self.candidates[0], snapshot: ProcessNetworkFixture.snapshot(status: .notCollected))
            let card = try #require(idle.processes?.rows.first?.card)
            #expect(card.networkNote?.contains("切换到下载") != true)
            #expect(card.networkNote?.contains("Select Download") != true)
            #expect(card.networkNote == ProcessPresentation.localizedNote(ProcessPresentation.socketScope))
            let failed = Self.scene(.cpu, candidate: Self.candidates[0], snapshot: ProcessNetworkFixture.snapshot(status: .unavailable("reader failed")))
            #expect(failed.processes?.rows.first?.card.networkNote?.contains("reader failed") == true)
        }
    }

    @Test func warmSortSwitchPreservesCurrentTrafficAndColdSwitchShowsLoading() throws {
        let model = PanelModel()
        var config = Config()
        config.language = .en
        config.processSort = .download
        model.apply(config)
        defer { Strings.language = .auto }
        model.ingest(ProcessNetworkFixture.snapshot())
        #expect(model.snapshot?.processes.value?.networkStatus.isAvailable == true)
        config.processSort = .cpu
        model.apply(config)
        #expect(model.snapshot?.processes.value?.byDownload.isEmpty == false)
        #expect(model.snapshot?.processes.value?.byUpload.isEmpty == false)
        #expect(model.snapshot?.processes.value?.networkStatus == .available)
        var updated = ProcessNetworkFixture.snapshot()
        var updatedList = try #require(updated.processes.value)
        updatedList.byUpload[0].network?.uploadBytesPerSecond = 4_200_000
        updated.processes = .value(updatedList)
        model.ingest(updated)
        config.processSort = .upload
        model.apply(config)
        #expect(model.snapshot?.processes.value?.entries(sortedBy: .upload).first?.network?.uploadBytesPerSecond == 4_200_000)
        #expect(model.snapshot?.processes.value?.networkStatus == .available)
        config.processSort = .memory
        model.apply(config)
        model.ingest(ProcessNetworkFixture.snapshot(status: .notCollected))
        config.processSort = .download
        model.apply(config)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.processes.value?.byDownload.isEmpty == true)
        #expect(model.snapshot?.processes.value?.byUpload.isEmpty == true)
    }

    @Test func disabledOrExplicitlyStoppedReaderImmediatelyDiscardsPreviousTraffic() throws {
        let model = PanelModel()
        var config = Config()
        config.processSort = .download
        model.apply(config)
        model.ingest(ProcessNetworkFixture.snapshot())
        model.resetProcessNetwork(loading: true)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.processes.value?.byDownload.isEmpty == true)
        #expect(model.snapshot?.processes.value?.top.isEmpty == false)
        model.ingest(ProcessNetworkFixture.snapshot())
        config.modules.removeAll { $0 == .processes }
        model.apply(config)
        let list = try #require(model.snapshot?.processes.value)
        #expect(list.byDownload.isEmpty && list.byUpload.isEmpty)
        #expect(list.networkStatus == .notCollected)
        #expect(list.networkNote == nil)
        config.modules.append(.processes)
        model.apply(config)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.processes.value?.byUpload.isEmpty == true)
        model.resetProcessNetwork(loading: false)
        #expect(model.snapshot?.processes.value?.networkStatus == .notCollected)
    }

    @Test func staleWarmSnapshotShowsLoadingUntilNextCurrentSample() {
        let model = PanelModel()
        var config = Config()
        config.processSort = .download
        model.apply(config)
        var stale = ProcessNetworkFixture.snapshot()
        stale.time = Date().addingTimeInterval(-7)
        model.ingest(stale)
        config.processSort = .cpu
        model.apply(config)
        config.processSort = .upload
        model.apply(config)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.processes.value?.byUpload.isEmpty == true)
        model.ingest(ProcessNetworkFixture.snapshot())
        #expect(model.snapshot?.processes.value?.networkStatus == .available)
        #expect(model.snapshot?.processes.value?.byUpload.isEmpty == false)
    }

    @Test func coldSelectionShowsLoadingBeforeFirstTrafficOrUsageSample() {
        let model = PanelModel()
        var config = Config()
        config.processSort = .download
        model.apply(config)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.cpu.value == nil)
        #expect(model.snapshot?.memory.value == nil)
        #expect(model.snapshot?.processes.value?.byDownload.isEmpty == true)
        var unavailable = ProcessNetworkFixture.snapshot()
        unavailable.processes = .unavailable("usage reader unavailable")
        model.ingest(unavailable)
        model.resetProcessNetwork(loading: true)
        #expect(model.snapshot?.processes.value?.networkStatus == .loading)
        #expect(model.snapshot?.processes.value?.top.isEmpty == true)
        #expect(model.snapshot?.cpu.value != nil)
    }
}
