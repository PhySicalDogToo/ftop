import AppKit
import Testing

@testable import FtopCore
@testable import FtopUI

@MainActor
@Suite struct DNSPanelTests {
    private let states = [
        DNSState(servers: ["114.114.114.114"], source: .systemDefault),
        DNSState(servers: ["114.114.114.114", "8.8.8.8", "1.1.1.1"], source: .systemDefault),
        DNSState(servers: ["ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fe80::1234:5678:9abc:def0%en0"], source: .systemDefault),
        DNSState(servers: ["192.0.2.1"], source: .serviceReference),
        DNSState(unavailableReason: "No current DNS configuration"),
    ]

    @Test func addressesNeverResizeOrLeaveAnyLayout() {
        defer { Strings.language = .auto }
        for language in [Language.en, .zh] {
            Strings.language = language
            for candidate in LayoutLadder.candidates(maxProcesses: 24, showsProcesses: true) {
                for scale in [0.76, 1, 1.3] {
                    let model = FitSweepTests.model(MachineShape(performance: 10, efficiency: 4), ModuleID.allCases, language: language)
                    let limit = SceneBuilder.stretchLimit(candidate, modules: model.config.shown)
                    let choice = LayoutChoice(candidate: candidate, scale: scale, extraWidth: limit.width, extraHeight: limit.height)
                    let expected = model.size(of: choice)
                    for state in states {
                        var builder = SceneBuilder(snapshot: model.snapshot, machine: model.machine, modules: model.config.shown, style: model.style(scale: scale))
                        builder.dns = state
                        let scene = builder.build(choice)
                        let label = "\(language) \(candidate) x\(scale) \(state.source)"
                        #expect(scene.size == expected, "\(label)")
                        FitSweepTests.expectWellFormed(scene, label)
                        let badges = scene.shapes.filter {
                            if case .badge(.dns, _) = $0.kind { return true }; return false
                        }
                        #expect(badges.count == 1, "\(label)")
                        let hover = badges.first.flatMap { badge in
                            scene.hovers.first { $0.rect.contains(badge.rect.origin) && $0.text.contains(Strings.pick("Current DNS", "当前 DNS")) }
                        }
                        #expect(hover != nil, "\(label)")
                        for address in state.servers { #expect(hover?.text.contains(address) == true, "\(label)") }
                        if state.source == .serviceReference { #expect(!scene.texts.contains { $0.string == "192.0.2.1" }, "\(label)") }
                    }
                }
            }
        }
    }

    @Test func defaultRowSitsBetweenMachineReadingsAndProcesses() throws {
        let model = FitSweepTests.model(MachineShape(), ModuleID.allCases)
        let scene = FitSweepTests.scene(model, LayoutChoice(candidate: LayoutCandidate(tier: .full, processCount: 5), scale: 1), snapshot: model.snapshot)
        let dns = try #require(
            scene.shapes.first {
                if case .badge(.dns, _) = $0.kind { return true }; return false
            })
        let machine = try #require(
            scene.shapes.first {
                if case .badge(.machine, _) = $0.kind { return true }; return false
            })
        let processes = try #require(scene.processes)
        #expect(dns.rect.minX == machine.rect.minX)
        #expect(dns.rect.minY > machine.rect.maxY)
        #expect(dns.rect.maxY < processes.rect.minY)
    }

    @Test func wideThinWindowsKeepTheirStripAndDNSHover() {
        let model = FitSweepTests.model(MachineShape(performance: 10, efficiency: 4), ModuleID.allCases)
        let choice = model.choice(for: CGSize(width: 400, height: 30))
        #expect(choice.candidate.tier == .strip)
        let scene = FitSweepTests.scene(model, choice, snapshot: model.snapshot)
        #expect(
            scene.shapes.contains {
                if case .badge(.dns, _) = $0.kind { return true }; return false
            })
        #expect(scene.hovers.contains { $0.text.contains("114.114.114.114") })
    }

    @Test func hiddenDNSRestoresLayoutsWithoutItsBadge() {
        let model = FitSweepTests.model(MachineShape(), ModuleID.stacked + [.gpu, .power])
        for candidate in LayoutLadder.candidates(maxProcesses: 5, showsProcesses: true) {
            let scene = FitSweepTests.scene(model, LayoutChoice(candidate: candidate, scale: 1), snapshot: model.snapshot)
            #expect(
                !scene.shapes.contains {
                    if case .badge(.dns, _) = $0.kind { return true }; return false
                })
        }
    }

    @Test func resizeThresholdsKeepDNSInsideTheChosenScene() {
        let model = FitSweepTests.model(MachineShape(groups: [2, 4, 6]), ModuleID.allCases)
        model.setDNS(states[2])
        for candidate in LayoutLadder.candidates(maxProcesses: 24, showsProcesses: true) {
            let natural = model.size(of: LayoutChoice(candidate: candidate, scale: 1))
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] {
                    let available = CGSize(width: natural.width + dx, height: natural.height + dy)
                    let choice = model.choice(for: available)
                    let scene = FitSweepTests.scene(model, choice, snapshot: model.snapshot)
                    if choice.candidate.tier != .micro || choice.scale > LayoutLadder.minimumMicroScale {
                        #expect(scene.size.width <= available.width + 0.5 && scene.size.height <= available.height + 0.5)
                    }
                    FitSweepTests.expectWellFormed(scene, "DNS resize threshold \(candidate) \(dx),\(dy)")
                    #expect(
                        scene.shapes.contains {
                            if case .badge(.dns, _) = $0.kind { return true }; return false
                        })
                }
            }
        }
    }

    @Test func dnsStaysWithStatisticsOrProcessesWhenOtherModulesAreOff() {
        for modules in [[ModuleID.dns], [.processes, .dns], [.processes, .cpu, .dns]] {
            let model = FitSweepTests.model(MachineShape(), modules)
            for columns in [1, 2, 3] {
                let choice = LayoutChoice(candidate: LayoutCandidate(tier: .full, columns: columns, processCount: modules.contains(.processes) ? 5 : 0), scale: 1)
                let scene = FitSweepTests.scene(model, choice, snapshot: model.snapshot)
                FitSweepTests.expectWellFormed(scene, "DNS minimal modules \(modules) c\(columns)")
                #expect(
                    scene.shapes.contains {
                        if case .badge(.dns, _) = $0.kind { return true }; return false
                    })
                if let rows = scene.processes {
                    let hover = scene.hovers.first { $0.text.contains("当前 DNS") }
                    #expect(hover?.rect.intersects(rows.rect) == false)
                }
            }
        }
    }
}
