import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

private let processRenderDirectory = ProcessInfo.processInfo.environment["FTOP_PROCESS_RENDER_DIR"] ?? ProcessInfo.processInfo.environment["FTOP_RENDER_DIR"]

/// Native offscreen pictures only; never starts a traffic reader or orders a window front.
@MainActor
@Suite struct ProcessNetworkRenderTests {
    @Test(.enabled(if: processRenderDirectory != nil))
    func writeProcessNetworkReferences() throws {
        let directory = URL(fileURLWithPath: processRenderDirectory!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Strings.language = .auto }
        for language in [Language.en, .zh] {
            Strings.language = language
            for dark in [false, true] {
                let suffix = "\(language.rawValue)-\(dark ? "dark" : "light")"
                for sort in [ProcessSort.download, .upload] {
                    var config = Config()
                    config.motion = false
                    config.language = language
                    config.processSort = sort
                    for (label, candidate) in zip(["single", "wide", "strip"], ProcessNetworkUITests.candidates) {
                        let model = PanelModel()
                        model.apply(config)
                        model.ingest(ProcessNetworkFixture.snapshot())
                        model.setDNS(DNSState(servers: ["114.114.114.114", "8.8.8.8"], source: .systemDefault))
                        model.setChoice(LayoutChoice(candidate: candidate, scale: 1))
                        model.canvas.frame = CGRect(origin: .zero, size: model.hugSize)
                        try write(
                            model.canvas, size: model.hugSize, dark: dark, to: directory.appending(path: "process-\(sort.rawValue)-\(label)-\(suffix).png"),
                            render: { model.render() })
                        model.ingest(ProcessNetworkFixture.snapshot(status: .loading))
                        try write(
                            model.canvas, size: model.hugSize, dark: dark, to: directory.appending(path: "process-\(sort.rawValue)-loading-\(label)-\(suffix).png"),
                            render: { model.render() })
                    }
                    let scene = ProcessNetworkUITests.scene(sort, candidate: ProcessNetworkUITests.candidates[0])
                    let card = try #require(scene.processes?.rows.first?.card)
                    let content = ProcessCardPicture.view(card)
                    try write(content, size: content.frame.size, dark: dark, to: directory.appending(path: "process-\(sort.rawValue)-card-\(suffix).png"))
                    let unavailable = ProcessNetworkUITests.scene(
                        sort, candidate: ProcessNetworkUITests.candidates[0], snapshot: ProcessNetworkFixture.snapshot(unavailable: true))
                    let canvas = PanelCanvasView()
                    canvas.frame = CGRect(origin: .zero, size: unavailable.size)
                    try write(
                        canvas, size: unavailable.size, dark: dark, to: directory.appending(path: "process-\(sort.rawValue)-unavailable-\(suffix).png"),
                        render: {
                            canvas.show(unavailable, style: PanelStyle(motion: false), pinned: false)
                        })
                    if sort == .download {
                        let control = ControlPanel.picture(.init(config: config), expanded: true)
                        try write(control, size: control.frame.size, dark: dark, to: directory.appending(path: "process-controls-\(suffix).png"))
                        var idle = ProcessNetworkFixture.snapshot(status: .notCollected)
                        if var list = idle.processes.value {
                            list.networkNote = nil
                            idle.processes = .value(list)
                        }
                        let idleScene = ProcessNetworkUITests.scene(.cpu, candidate: ProcessNetworkUITests.candidates[0], snapshot: idle)
                        let idleCard = try #require(idleScene.processes?.rows.first?.card)
                        let idleContent = ProcessCardPicture.view(idleCard)
                        try write(idleContent, size: idleContent.frame.size, dark: dark, to: directory.appending(path: "process-idle-card-\(suffix).png"))
                    }
                }
            }
        }
    }

    private func write(_ content: NSView, size: CGSize, dark: Bool, to url: URL, render: (() -> Void)? = nil) throws {
        let frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = NSView(frame: frame)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        content.frame = frame
        backdrop.addSubview(content)
        window.contentView = backdrop
        render?()
        window.layoutIfNeeded()
        backdrop.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let scale: CGFloat = 2
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        backdrop.layer?.render(in: context.cgContext)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        #expect(!window.isVisible)
    }
}
