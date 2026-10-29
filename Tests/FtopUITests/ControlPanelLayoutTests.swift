import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

@MainActor
@Suite struct ControlPanelLayoutTests {
    @Test func everyDiscLabelAndHitAreaFitsInBothLanguagesAndStates() throws {
        let oldLanguage = Strings.language
        defer { Strings.language = oldLanguage }
        for language in [Language.en, .zh] {
            Strings.language = language
            var config = Config()
            config.language = language
            let face = ControlFace(state: .init(config: config))
            for expanded in [false, true] {
                if expanded { face.expand() } else { face.collapse() }
                face.frame = CGRect(origin: .zero, size: face.fittingSize)
                let targets = face.targetLayout
                let discs = targets.filter { $0.discFrame != nil }
                #expect(discs.count == Config.optional.count + 5 + PaletteID.allCases.count + 1)
                #expect(Set(discs.map(\.item)).isSuperset(of: Config.optional.map { .module($0) }))
                #expect(targets.count == discs.count + (expanded ? 8 : 0))
                for target in targets {
                    let label = "\(language) expanded=\(expanded) \(target.item)"
                    #expect(face.bounds.contains(target.hitFrame), "\(label): hit area leaves the control block")
                    for frame in target.visualFrames {
                        #expect(frame.width > 0 && frame.height > 0, "\(label): empty visual")
                        #expect(face.bounds.contains(frame), "\(label): visual leaves the control block")
                    }
                    // Hover and mouse-up use this same hit test; verify the complete area,
                    // including corners, without sending events or invoking settings writes.
                    let inner = target.hitFrame.insetBy(dx: PanelStyle.controlRingLine, dy: PanelStyle.controlRingLine)
                    for point in [
                        CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                        CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY),
                        CGPoint(x: inner.midX, y: inner.midY),
                    ] {
                        #expect(face.targetItem(at: point) == target.item, "\(label): hit test disagrees with layout")
                    }
                }
                let modules = discs.filter { if case .module = $0.item { true } else { false } }
                let lastModule = try #require(modules.max { $0.hitFrame.maxX < $1.hitFrame.maxX })
                let more = try #require(discs.first { $0.item == .more })
                #expect(lastModule.hitFrame.maxX == more.hitFrame.maxX)
                #expect(lastModule.discFrame?.width == PanelStyle.controlDisc)
            }
        }
    }
}
