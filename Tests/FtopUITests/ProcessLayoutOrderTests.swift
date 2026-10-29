import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

private let layoutOrderRenderDirectory = ProcessInfo.processInfo.environment["FTOP_LAYOUT_ORDER_RENDER_DIR"]

/// A ranking is the last block in its statistics stack, including when a setting
/// written by an older version or a module toggle lists a basic reading after it.
@MainActor
@Suite struct ProcessLayoutOrderTests {
    private static let candidates = [
        LayoutCandidate(tier: .detailed, processCount: 7),
        LayoutCandidate(tier: .detailed, columns: 2, processCount: 7),
        LayoutCandidate(tier: .detailed, columns: 3, processCount: 5),
        LayoutCandidate(tier: .full, processCount: 7),
        LayoutCandidate(tier: .full, columns: 2, processCount: 7),
        LayoutCandidate(tier: .full, columns: 3, processCount: 5),
        LayoutCandidate(tier: .compact, processCount: 3),
        LayoutCandidate(tier: .compact, columns: 2, processCount: 3),
        LayoutCandidate(tier: .compact, columns: 3, processCount: 3),
        LayoutCandidate(tier: .detailed, columns: 2, processCount: 7, memoryList: true),
        LayoutCandidate(tier: .full, columns: 2, processCount: 7, memoryList: true),
    ]

    private static func snapshot() -> Snapshot {
        var snapshot = Snapshot.sample(performance: 10, efficiency: 4)
        var entries: [ProcessSample] = []
        for index: Int in 0..<7 {
            let memoryBytes: UInt64 = UInt64(700 - index * 40) << 20
            let downloadRate: Double = Double(367_000 - index * 40_000)
            let uploadRate: Double = Double(140_000 - index * 20_000)
            let network = ProcessNetworkSample(downloadBytesPerSecond: downloadRate, uploadBytesPerSecond: uploadRate)
            entries.append(
                ProcessSample(
                    pid: Int32(index + 1), name: "Application \(index + 1)", cpuPercent: Double(70 - index * 5), memoryBytes: memoryBytes, network: network))
        }
        snapshot.processes = .value(
            ProcessList(top: entries, byMemory: entries, coversAllUsers: false, byDownload: entries, byUpload: entries, networkStatus: .available))
        return snapshot
    }

    private static func scene(_ config: Config, candidate: LayoutCandidate, sort: ProcessSort, scale: Double) -> Scene {
        var builder = SceneBuilder(
            snapshot: snapshot(), machine: MachineShape(performance: 10, efficiency: 4), modules: config.shown,
            style: PanelStyle(scale: scale, motion: false))
        builder.processSort = sort
        builder.dns = DNSState(servers: ["114.114.114.114"], source: .systemDefault)
        return builder.build(candidate)
    }

    private static func expectOrder(_ scene: Scene, label: String) throws {
        let processes = try #require(scene.processes, "\(label): the selected ranking is present")
        let basics = scene.shapes.filter { shape in
            if case .badge = shape.kind { return true }
            return false
        }
        for badge in basics {
            let sameColumn = badge.rect.maxX > processes.rect.minX && badge.rect.minX < processes.rect.maxX
            if sameColumn {
                #expect(badge.rect.maxY < processes.rect.minY, "\(label): a basic reading must be above the ranking in its column")
            } else {
                // An independent ranking column may start higher, but no basic
                // reading belongs to a later column than the ranking.
                #expect(badge.rect.maxX < processes.rect.minX, "\(label): the independent ranking stays to the right of all basic readings")
            }
        }
        FitSweepTests.expectWellFormed(scene, label)
    }

    @Test func reenablingBasicReadingsKeepsRankingBelowThem() throws {
        defer { Strings.language = .auto }
        Strings.language = .zh
        for toggled in [[ModuleID.network], [.network, .memory]] {
            var config = Config()
            for module in toggled { _ = config.setShown(module, false) }
            for module in toggled { _ = config.setShown(module, true) }
            let processPosition = try #require(config.modules.firstIndex(of: .processes))
            for module in toggled {
                #expect(try #require(config.modules.firstIndex(of: module)) > processPosition)
            }
            for sort in ProcessSort.allCases {
                for candidate in Self.candidates {
                    let scene = Self.scene(config, candidate: candidate, sort: sort, scale: 1)
                    try Self.expectOrder(scene, label: "toggle \(toggled), \(sort), \(candidate)")
                }
            }
        }
    }

    @Test func historicalOrderAndOptionalReadingsKeepRankingAtTheEnd() throws {
        defer { Strings.language = .auto }
        Strings.language = .zh
        let orders: [[ModuleID]] = [
            [.cpu, .memory, .processes, .network],
            [.processes, .cpu, .network, .memory],
            [.processes],
        ]
        for modules in orders {
            for visibility in 0..<8 {
                var config = Config()
                config.modules = modules
                config.hidden = ModuleID.added.enumerated().compactMap { index, module in visibility & (1 << index) == 0 ? module : nil }
                for sort in ProcessSort.allCases {
                    for (index, candidate) in Self.candidates.enumerated() {
                        let scale = [0.76, 1, 1.3][index % 3]
                        let scene = Self.scene(config, candidate: candidate, sort: sort, scale: scale)
                        try Self.expectOrder(scene, label: "legacy \(modules), added \(visibility), \(sort), \(candidate), x\(scale)")
                    }
                }
            }
        }
    }

    /// Native view references only: no window is ordered front and no screen is captured.
    @Test(.enabled(if: layoutOrderRenderDirectory != nil))
    func writeLayoutOrderReferences() throws {
        let directory = URL(fileURLWithPath: layoutOrderRenderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Strings.language = .auto }
        for language in [Language.zh, .en] {
            Strings.language = language
            for dark in [true, false] {
                let layouts: [(String, LayoutCandidate)] = [
                    ("single", LayoutCandidate(tier: .full, processCount: 7)),
                    ("two-column", LayoutCandidate(tier: .full, columns: 2, processCount: 7)),
                    ("three-column", LayoutCandidate(tier: .full, columns: 3, processCount: 5)),
                    ("wide-ranking", LayoutCandidate(tier: .full, columns: 2, processCount: 7, memoryList: true)),
                ]
                for (label, candidate) in layouts {
                    let model = PanelModel()
                    var config = Config()
                    config.modules = [.cpu, .memory, .processes, .network]
                    config.motion = false
                    config.language = language
                    config.processSort = .download
                    model.apply(config)
                    model.ingest(Self.snapshot())
                    model.setDNS(DNSState(servers: ["114.114.114.114"], source: .systemDefault))
                    model.setChoice(LayoutChoice(candidate: candidate, scale: 1))
                    let destination = directory.appending(path: "process-order-legacy-\(label)-\(language.rawValue)-\(dark ? "dark" : "light").png")
                    try Self.write(model, dark: dark, to: destination)
                }
            }
        }
    }

    private static func write(_ model: PanelModel, dark: Bool, to destination: URL) throws {
        let frame = CGRect(origin: .zero, size: model.hugSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = NSView(frame: frame)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        model.canvas.frame = frame
        backdrop.addSubview(model.canvas)
        window.contentView = backdrop
        model.render()
        window.layoutIfNeeded()
        backdrop.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let scale: CGFloat = 2
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(frame.width * scale), pixelsHigh: Int(frame.height * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = frame.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        backdrop.layer?.render(in: context.cgContext)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        #expect(!window.isVisible)
    }
}
