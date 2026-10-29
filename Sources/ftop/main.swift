import AppKit
import Foundation
import FtopCore
import FtopSensors

// The `ftop` command: opens the panel and returns, or controls a running panel.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func post(_ verb: String, _ argument: String? = nil) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("dev.ftop.app.\(verb)"), object: argument, userInfo: nil, deliverImmediately: true)
}

func isRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.ftop.app").isEmpty
}

/// The app bundle this command lives in (`Ftop.app/Contents/MacOS/ftop`).
func appBundleURL() -> URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

func open() {
    if isRunning() { post("show"); return }
    guard let bundle = appBundleURL() else {
        fail("ftop: this command is not inside Ftop.app. Run scripts/install.sh, or start the app with `swift run FtopApp`.")
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // `-n`: always start it. Without it, right after the panel quit the system sometimes
    // still counted it as running and started nothing. A second copy hands over and exits.
    task.arguments = ["-n", "-g", "-a", bundle.path]
    do { try task.run() } catch { fail("ftop: could not start \(bundle.path): \(error.localizedDescription)") }
    task.waitUntilExit()
}

/// An explicit network diagnostic waits for its independent interval. Ordinary
/// probes do not start the extra process-network observer.
final class NetworkDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Snapshot?
    let ready = DispatchSemaphore(value: 0)

    func receive(_ snapshot: Snapshot) {
        lock.withLock { latest = snapshot }
        if snapshot.processes.value?.networkStatus.isAvailable == true { ready.signal() }
    }

    var snapshot: Snapshot? { lock.withLock { latest } }
}

/// Two samples one interval apart, so rates and CPU usage are real.
func takeSnapshot() -> (Snapshot, SystemSampler) {
    let sampler = SystemSampler()
    if arguments.contains("--network") {
        let diagnostic = NetworkDiagnostic()
        sampler.start(interval: 1, modules: ModuleID.allCases, processNetwork: true) { diagnostic.receive($0) }
        _ = diagnostic.ready.wait(timeout: .now() + 8)
        sampler.stop()
        return (diagnostic.snapshot ?? sampler.sampleNow(), sampler)
    }
    _ = sampler.sampleNow()
    Thread.sleep(forTimeInterval: 1)
    return (sampler.sampleNow(), sampler)
}

func probe(json: Bool) {
    let (snapshot, _) = takeSnapshot()
    // A process's CPU is a share of the whole machine, the unit of the CPU line and of the panel.
    let cores = snapshot.cpu.value?.cores.count ?? ProcessInfo.processInfo.activeProcessorCount
    if json {
        var snapshot = snapshot
        if let list = snapshot.processes.value { snapshot.processes = .value(list.asShareOfMachine(cores: cores)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? encoder.encode(snapshot)) ?? Data(), as: UTF8.self))
        return
    }
    switch snapshot.cpu {
    case .value(let cpu):
        print("CPU \(Format.percent(cpu.usage))%")
        for core in cpu.cores {
            let frequency = core.frequencyMHz.value.map { Format.gigahertz($0) + " GHz" } ?? "frequency unavailable"
            print("  \(core.tier.letter)\(core.number)  \(Format.percent(core.usage))%  \(frequency)")
        }
        switch cpu.temperature {
        case .value(let temperature):
            let source = temperature.source == .cpuCluster ? "CPU cluster sensors" : "chip die sensors"
            print("  temperature \(Format.degrees(temperature.celsius)) from \(temperature.sensorCount) \(source)")
        case .unavailable(let reason): print("  temperature unavailable: \(reason)")
        }
    case .unavailable(let reason): print("CPU unavailable: \(reason)")
    }
    switch snapshot.memory {
    case .value(let memory):
        let pressure = memory.pressure.value.map { "\($0)" } ?? "unavailable"
        print(
            "Memory \(Format.gigabytes(memory.used)) / \(Format.gigabytesCompact(memory.total)) GB, pressure \(pressure), "
                + "compressed \(Format.gigabytes(memory.compressed)) GB, swap \(Format.gigabytes(memory.swapUsed)) GB")
    case .unavailable(let reason): print("Memory unavailable: \(reason)")
    }
    switch snapshot.network {
    case .value(let network):
        print("Network down \(Format.rate(network.downBytesPerSecond).text), up \(Format.rate(network.upBytesPerSecond).text)")
    case .unavailable(let reason): print("Network unavailable: \(reason)")
    }
    switch snapshot.gpu {
    case .value(let gpu):
        let frequency = gpu.frequencyMHz.value.map { Format.gigahertz($0) + " GHz" } ?? "frequency unavailable: \(gpu.frequencyMHz.reason ?? "")"
        let memory = gpu.memoryBytes.value.map { Format.gigabytes($0) + " GB in use" } ?? "memory unavailable"
        let temperature = gpu.temperature.value.map { "\(Format.degrees($0.celsius)) from \($0.sensorCount) sensors" } ?? "temperature unavailable"
        print("GPU \(Format.percent(gpu.usage))%, \(frequency), \(memory), \(temperature)")
    case .unavailable(let reason): print("GPU unavailable: \(reason)")
    }
    switch snapshot.power {
    case .value(let power):
        let input = power.inputWatts.value.map { Format.watts($0) + " W" } ?? "unavailable"
        let gpu = power.gpuWatts.value.map { Format.watts($0) + " W" } ?? "unavailable"
        print("Power \(Format.watts(power.systemWatts)) W whole machine, adapter \(input), GPU \(gpu)")
    case .unavailable(let reason): print("Power unavailable: \(reason)")
    }
    switch snapshot.processes {
    case .value(let list):
        print("Processes (\(list.coversAllUsers ? "all users" : "your processes only; run `sudo ftop grant` to include system processes"))")
        for process in list.top.prefix(5) {
            print("  \(process.name)  \(Format.processShare(percentOfOneCore: process.cpuPercent, cores: cores))%  \(Format.processMemory(process.memoryBytes))")
        }
        if arguments.contains("--network") {
            if list.networkStatus.isAvailable {
                print("Process network (TCP/UDP socket activity, including local and proxy connections)")
                for process in list.byDownload.prefix(5) {
                    guard let network = process.network else { continue }
                    print("  \(process.name)  down \(Format.rate(network.downloadBytesPerSecond).text), up \(Format.rate(network.uploadBytesPerSecond).text)")
                }
            } else if list.networkStatus.isLoading {
                print("Process network: reading data")
            } else {
                print("Process network unavailable: \(list.networkStatus.reason ?? "not reported")")
            }
        }
    case .unavailable(let reason): print("Processes unavailable: \(reason)")
    }
}

/// Inspect the same read-only state as the control block, without opening a panel.
func dns(json: Bool) {
    let state = DNSReader.read()
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { print(String(decoding: try encoder.encode(state), as: UTF8.self)) } catch { fail("ftop: could not encode DNS state: \(error.localizedDescription)") }
        return
    }
    switch state.source {
    case .systemDefault: print("DNS source: system default")
    case .serviceReference: print("DNS source: service reference (system default unavailable)")
    case .unavailable: print("DNS unavailable: \(state.unavailableReason ?? "not reported")")
    }
    for server in state.servers { print("  \(server)") }
    for service in state.services {
        let identity = [service.name, service.interfaceName].compactMap { $0 }.joined(separator: " · ")
        print("Service: \(identity.isEmpty ? service.id : identity)")
        print("  manual DNS: \(service.manualServers.isEmpty ? "none reported" : service.manualServers.joined(separator: ", "))")
        print("  service DNS: \(service.providedServers.isEmpty ? "none reported" : service.providedServers.joined(separator: ", "))")
    }
    print("Domain- and interface-specific resolvers may differ. Read-only; no settings changed.")
}

func doctor() {
    let (snapshot, sampler) = takeSnapshot()
    func line(_ name: String, _ ok: Bool, _ detail: String) { print("\(ok ? "ok  " : "MISS") \(name): \(detail)") }
    if let cpu = snapshot.cpu.value {
        // Counted by what the system calls them: "5 super + 10 performance cores" on an M5 Pro.
        var tiers: [CoreTier] = []
        for core in cpu.cores where !tiers.contains(core.tier) { tiers.append(core.tier) }
        let groups = tiers.map { tier in "\(cpu.cores.count(where: { $0.tier == tier })) \(tier == .unknown ? "unclassified" : tier.rawValue)" }
        line("per-core usage", true, groups.joined(separator: " + ") + " cores")
        // Each kind of core can fail for a reason of its own.
        var missing: [String] = []
        for reason in cpu.cores.compactMap({ $0.frequencyMHz.reason }) where !missing.contains(reason) { missing.append(reason) }
        line("per-core frequency", missing.isEmpty, missing.isEmpty ? "read through IOReport without admin rights" : missing.joined(separator: "; "))
        line(
            "temperature", cpu.temperature.value != nil,
            cpu.temperature.reason ?? "\(cpu.temperature.value!.sensorCount) sensors, \(cpu.temperature.value!.source.rawValue)")
    } else {
        line("cpu", false, snapshot.cpu.reason ?? "")
    }
    line("memory", snapshot.memory.value != nil, snapshot.memory.reason ?? "used, compressed, swap, pressure")
    line("network", snapshot.network.value != nil, snapshot.network.reason ?? "64-bit counters on en* interfaces")
    if let gpu = snapshot.gpu.value {
        line("gpu usage", true, "one figure for the whole GPU, from the graphics driver")
        line("gpu frequency", gpu.maxFrequencyMHz != nil, gpu.maxFrequencyMHz == nil ? gpu.frequencyMHz.reason ?? "" : "read through IOReport without admin rights")
        line("gpu memory", gpu.memoryBytes.value != nil, gpu.memoryBytes.reason ?? "unified memory the GPU holds")
        line("gpu temperature", gpu.temperature.value != nil, gpu.temperature.reason ?? "\(gpu.temperature.value!.sensorCount) controller sensors")
    } else {
        line("gpu", false, snapshot.gpu.reason ?? "")
    }
    if let power = snapshot.power.value {
        line("power", true, "whole machine, from the controller")
        line("gpu power", power.gpuWatts.value != nil, power.gpuWatts.reason ?? "read through IOReport without admin rights")
    } else {
        line("power", false, snapshot.power.reason ?? "")
    }
    if let list = snapshot.processes.value {
        if list.helperOutdated {
            line(
                "processes", false,
                "all users, but the granted helper is from an older version (no list by memory, shorter lists). Run `sudo ftop grant` again to replace it.")
        } else {
            line("processes", list.coversAllUsers, list.coversAllUsers ? "all users" : "your processes only. Run `sudo ftop grant` to include system processes.")
        }
        if arguments.contains("--network") {
            line(
                "process network", list.networkStatus.isAvailable,
                list.networkStatus.isLoading
                    ? "waiting for initial process traffic samples"
                    : list.networkStatus.reason ?? "native TCP/UDP socket activity; proxy/TUN totals may overlap")
        }
    } else {
        line("processes", false, snapshot.processes.reason ?? "")
    }
    line("panel", isRunning(), isRunning() ? "running" : "not running")
    // Opening any copy shows the running panel, so a second copy explains a panel that came back.
    let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "dev.ftop.app").map { $0.resolvingSymlinksInPath().path }
    if copies.count > 1 {
        line("copies", false, "\(copies.count) copies of Ftop.app on this Mac; opening any of them shows the running panel. Keep one and delete the others:")
        for copy in copies { print("       \(copy)") }
    }
    print("config: \(Config.fileURL.path)")
    if arguments.contains("--states") { print(sampler.describeStates()) }
}

/// Installs the helper setuid root so the panel can read every user's processes.
func grant() {
    guard geteuid() == 0 else {
        fail(
            "This needs admin rights once. Run:\n\n    sudo ftop grant\n\nIt copies ftop-helper to \(HelperInstall.path), owned by root with the setuid bit, so ftop can read CPU and memory of system processes. Undo with `sudo ftop revoke`."
        )
    }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { fail("ftop: cannot locate itself") }
    let source = executable.deletingLastPathComponent().appending(path: "ftop-helper").path
    let target = HelperInstall.path
    let manager = FileManager.default
    do {
        try manager.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        if manager.fileExists(atPath: target) { try manager.removeItem(atPath: target) }
        try manager.copyItem(atPath: source, toPath: target)
        try manager.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: target)
        // chmod after chown: changing the owner clears the setuid bit.
        guard chmod(target, 0o4755) == 0 else { fail("ftop: chmod failed: \(String(cString: strerror(errno)))") }
    } catch {
        fail("ftop: \(error.localizedDescription)")
    }
    print("Installed \(target). Restart the panel with `ftop quit` then `ftop`.")
}

func revoke() {
    guard geteuid() == 0 else { fail("Run: sudo ftop revoke") }
    try? FileManager.default.removeItem(atPath: HelperInstall.path)
    print("Removed \(HelperInstall.path).")
}

switch arguments.first {
case nil, "show": open()
case "toggle": if isRunning() { post("toggle") } else { open() }
case "quit": post("quit")
case "size":
    guard arguments.count == 2, arguments[1].split(separator: "x").compactMap({ Double($0) }).count == 2 else { fail("usage: ftop size 300x420") }
    post("size", arguments[1])
case "probe": probe(json: arguments.contains("--json"))
case "dns":
    guard arguments.count == 1 || arguments == ["dns", "--json"] else { fail("usage: ftop dns [--json]") }
    dns(json: arguments.contains("--json"))
case "doctor": doctor()
case "grant": grant()
case "revoke": revoke()
case "config": print(Config.fileURL.path)
case "version":
    guard let bundle = appBundleURL(), let version = Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String else {
        fail("ftop: this command is not inside Ftop.app, so it has no version.")
    }
    print(version)
case "update":
    // The panel does the work: it is the app that gets replaced and restarted.
    if !isRunning() {
        open()
        Thread.sleep(forTimeInterval: 2)
    }
    post("update")
    print("Asked the panel to look for a newer version. It installs one and restarts; `ftop version` shows the result.")
case "help", "-h", "--help":
    print(
        """
        ftop            open the panel (or bring it back if it is hidden)
        ftop toggle     show or hide the panel
        ftop quit       close the panel
        ftop size WxH   resize the panel, e.g. `ftop size 300x420`
        ftop probe      print readings (--json for JSON; --network adds a bounded process-network diagnostic)
        ftop dns        inspect current DNS addresses and their source, read-only (--json for JSON)
        ftop doctor     list available readings (--states adds CPU/GPU frequency data; --network checks per-process network)
        ftop config     print the path of the settings file
        ftop version    print the installed version
        ftop update     look for a newer version now and install it
        sudo ftop grant   let ftop read system processes (one time); `sudo ftop revoke` undoes it
        """)
default:
    fail("ftop: unknown command '\(arguments[0])'. Try `ftop help`.")
}
