import Foundation
import FtopCore
import Testing

@testable import FtopSensors

@Suite struct DNSSettingsTests {
    @Test func customWritePreservesEveryOtherDNSField() throws {
        let original: [String: Any] = [
            "ServerAddresses": ["192.0.2.53"], "SearchDomains": ["company.example"], "DomainName": "company.example",
            "SortList": ["10.0.0.0/8"], "SupplementalMatchDomains": ["internal.example"], "ServerPort": 53,
            "SearchOrder": 200000, "FutureField": ["enabled": true],
        ]
        let backend = DNSFakeBackend(snapshot: snapshot(configuration: original))
        let request = DNSChangeRequest(target: try backend.snapshot.target(), mode: .custom(["1.1.1.1", "2001:db8::53"]))
        let result = try DNSChangeTransaction.save(request, backend: backend)
        var expected = original
        expected["ServerAddresses"] = ["1.1.1.1", "2001:db8::53"]
        #expect(NSDictionary(dictionary: backend.persisted.configuration ?? [:]).isEqual(to: expected))
        #expect(backend.events == ["read", "authorize", "lock", "read", "stage", "read", "commit", "apply", "verify", "state", "unlock"])
        #expect(result.target.manualServers == ["1.1.1.1", "2001:db8::53"])
        #expect(result.didChange)
    }

    @Test func automaticOnlyRemovesAddressesAndKeepsSearchDomains() throws {
        let backend = DNSFakeBackend(snapshot: snapshot(configuration: ["ServerAddresses": ["1.1.1.1"], "SearchDomains": ["example.test"]]))
        _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
        #expect(NSDictionary(dictionary: backend.persisted.configuration ?? [:]).isEqual(to: ["SearchDomains": ["example.test"]]))
    }

    @Test func automaticRemovesAnExistingEmptyAddressKey() throws {
        let backend = DNSFakeBackend(snapshot: snapshot(configuration: ["ServerAddresses": [String](), "SearchDomains": ["example.test"]]))
        let result = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
        #expect(result.didChange)
        #expect(backend.persisted.configuration?["ServerAddresses"] == nil)
        #expect(backend.persisted.configuration?["SearchDomains"] as? [String] == ["example.test"])
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
    }

    @Test func customWriteDeduplicatesAddressesAndReportsActualSystemResolvers() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        let request = DNSChangeRequest(
            target: try backend.snapshot.target(), mode: .custom(["2001:db8::53", "2001:0db8:0:0:0:0:0:0053", "1.1.1.1", "1.1.1.1"]))
        let result = try DNSChangeTransaction.save(request, backend: backend)
        #expect(result.target.manualServers == ["2001:db8::53", "1.1.1.1"])
        #expect(try backend.persisted.manualServers == result.target.manualServers)
        // Saved service addresses and the system's chosen resolver are separate facts.
        #expect(result.state.servers == ["203.0.113.53"])
        #expect(result.state.source == .systemDefault)
    }

    @Test func automaticWithoutProtocolOrConfigurationDoesNotAuthorizeOrCreateProtocol() throws {
        for exists in [false, true] {
            let backend = DNSFakeBackend(snapshot: snapshot(configuration: nil, protocolExists: exists))
            let result = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            #expect(!result.didChange)
            #expect(backend.events == ["read", "state"])
            #expect(backend.persisted.protocolExists == exists)
        }
    }

    @Test func customAddsMissingProtocolOnlyWhenNeeded() throws {
        let backend = DNSFakeBackend(snapshot: snapshot(configuration: nil, protocolExists: false))
        _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .custom(["1.1.1.1"])), backend: backend)
        #expect(backend.persisted.protocolExists)
        #expect(backend.createdProtocol)
    }

    @Test func invalidDraftAndInvalidTokenNeverAuthorize() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        #expect(throws: DNSChangeError.self) {
            try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .custom(["bad.example"])), backend: backend)
        }
        var invalid = try backend.snapshot.target()
        for data in [Data(), Data("not a property list".utf8), try PropertyListSerialization.data(fromPropertyList: ["version": 1], format: .binary, options: 0)] {
            invalid.configurationToken = data
            #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: invalid, mode: .automatic), backend: backend) }
        }
        #expect(backend.events.isEmpty)
    }

    @Test func tokenCannotBeRetargetedToAnotherService() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        var target = try backend.snapshot.target()
        target.serviceID = "other-service"
        #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .automatic), backend: backend) }
        #expect(backend.events.isEmpty)
    }

    @Test func configurationAndLocationConflictsAreRejectedBeforeAuthorization() throws {
        for change in ["configuration", "location", "connection"] {
            let backend = DNSFakeBackend(snapshot: snapshot())
            let target = try backend.snapshot.target()
            if change == "configuration" { backend.snapshot.configuration?["SearchDomains"] = ["changed.example"] }
            if change == "location" { backend.snapshot.locationID = "other-location" }
            if change == "connection" { backend.snapshot.network["ipv4"] = ["Router": "192.0.2.254"] }
            #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .automatic), backend: backend) }
            #expect(backend.events == ["read"])
        }
    }

    @Test func changeWhileAuthorizingIsRejectedUnderLock() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        let target = try backend.snapshot.target()
        backend.onAuthorize = { backend.snapshot.configuration?["ServerAddresses"] = ["9.9.9.9"] }
        #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .automatic), backend: backend) }
        #expect(!backend.events.contains("stage"))
        #expect(backend.events.last == "unlock")
    }

    @Test func serviceOrInterfaceChangeDuringAuthorizationNeverStages() throws {
        for change in ["service", "interface", "location"] {
            let backend = DNSFakeBackend(snapshot: snapshot())
            let target = try backend.snapshot.target()
            backend.onAuthorize = {
                switch change {
                case "service": backend.snapshot.serviceID = "other-service"
                case "interface": backend.snapshot.interfaceName = "en7"
                default: backend.snapshot.locationID = "other-location"
                }
            }
            #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .automatic), backend: backend) }
            #expect(!backend.events.contains("stage"))
            #expect(backend.events.last == "unlock")
            #expect(try backend.persisted.manualServers == ["192.0.2.53"])
        }
    }

    @Test func connectionChangeImmediatelyBeforeCommitNeverPersists() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        let target = try backend.snapshot.target()
        backend.onStage = { backend.snapshot.network["link"] = ["Active": false] }
        #expect(throws: DNSChangeError.self) { try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .automatic), backend: backend) }
        #expect(!backend.events.contains("commit"))
        #expect(try backend.persisted.manualServers == ["192.0.2.53"])
    }

    @Test func deniedPermissionAndBusyLockDoNotStageAnything() throws {
        for stage in ["authorize", "lock"] {
            let backend = DNSFakeBackend(snapshot: snapshot())
            backend.failureStage = stage
            #expect(throws: DNSChangeError.self) {
                try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            }
            #expect(!backend.events.contains("stage"))
            #expect(!backend.events.contains("commit"))
        }
    }

    @Test func cancelledAuthorizationDoesNotStageOrPersist() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.failureStage = "authorize"
        backend.failureCode = .authorizationCancelled
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected cancelled authorization")
        } catch let error as DNSChangeError {
            #expect(error.code == .authorizationCancelled)
            #expect(error.persistence == .unchanged)
        }
        #expect(backend.events == ["read", "authorize"])
        #expect(try backend.persisted.manualServers == ["192.0.2.53"])
    }

    @Test func stageFailureUnlocksWithoutCommitAndDisabledProtocolDoesNotAuthorize() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.failureStage = "stage"
        #expect(throws: DNSChangeError.self) {
            try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
        }
        #expect(!backend.events.contains("commit"))
        #expect(backend.events.last == "unlock")
        #expect(try backend.persisted.manualServers == ["192.0.2.53"])
        let disabled = DNSFakeBackend(snapshot: snapshot())
        disabled.snapshot.protocolEnabled = false
        #expect(throws: DNSChangeError.self) {
            try DNSChangeTransaction.save(DNSChangeRequest(target: disabled.snapshot.target(), mode: .automatic), backend: disabled)
        }
        #expect(disabled.events == ["read"])
    }

    @Test func existingWriterIsRejectedWithoutAnAuthorizationPrompt() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.hasExternalWriter = true
        #expect(throws: DNSChangeError.self) {
            try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
        }
        #expect(backend.events == ["read"])
    }

    @Test func applyFailureReportsVerifiedPersistenceWithoutRollback() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.failureStage = "apply"
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected an apply failure")
        } catch let error as DNSChangeError {
            #expect(error.code == .applyFailed)
            #expect(error.persistence == .saved)
            #expect(error.currentManualServers == [])
        }
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
        #expect(try backend.persisted.manualServers == [])
    }

    @Test func commitFailureWithUnchangedStorageIsReportedAsUnchanged() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.failureStage = "commit"
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected a commit failure")
        } catch let error as DNSChangeError {
            #expect(error.persistence == .unchanged)
            #expect(error.currentManualServers == ["192.0.2.53"])
        }
        #expect(!backend.events.contains("apply"))
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
    }

    @Test func commitFailureAfterStorageChangedIsReportedAsSaved() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.commitStoresThenThrows = true
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected a commit failure")
        } catch let error as DNSChangeError {
            #expect(error.code == .writeFailed)
            #expect(error.persistence == .saved)
            #expect(error.currentManualServers == [])
        }
        #expect(!backend.events.contains("apply"))
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
    }

    @Test func commitFailureWithoutARereadDoesNotClaimNothingWasSaved() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.commitStoresThenThrows = true
        backend.failureStage = "verify"
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected a commit failure")
        } catch let error as DNSChangeError {
            #expect(error.persistence == .unknown)
            #expect(error.currentManualServers == nil)
        }
        #expect(!backend.events.contains("apply"))
    }

    @Test func concurrentChangeAfterCommitIsReportedWithoutBeingOverwritten() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.onApply = { backend.persisted.configuration?["ServerAddresses"] = ["9.9.9.9"] }
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected a verification failure")
        } catch let error as DNSChangeError {
            #expect(error.code == .verificationFailed)
            #expect(error.persistence == .unknown)
            #expect(error.currentManualServers == ["9.9.9.9"])
        }
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
        #expect(try backend.persisted.manualServers == ["9.9.9.9"])
    }

    @Test func failedRereadAfterApplyLeavesAnExplicitUnknownResult() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.failureStage = "verify"
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .automatic), backend: backend)
            Issue.record("Expected readback failure")
        } catch let error as DNSChangeError {
            #expect(error.code == .verificationFailed && error.persistence == .unknown)
            #expect(error.currentManualServers == nil)
        }
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
        #expect(backend.events.last == "unlock")
    }

    @Test func connectionChangeAfterCommitReportsSavedServiceWithoutRepeatingWrite() throws {
        let backend = DNSFakeBackend(snapshot: snapshot())
        backend.onApply = { backend.persisted.locationID = "other-location" }
        do {
            _ = try DNSChangeTransaction.save(DNSChangeRequest(target: backend.snapshot.target(), mode: .custom(["2001:db8::53"])), backend: backend)
            Issue.record("Expected changed connection")
        } catch let error as DNSChangeError {
            #expect(error.code == .verificationFailed && error.persistence == .saved)
            #expect(error.currentManualServers == ["2001:db8::53"])
        }
        #expect(backend.events.filter { $0 == "commit" }.count == 1)
        #expect(try backend.persisted.manualServers == ["2001:db8::53"])
    }

    @Test func baselineDictionaryOrderingDoesNotCauseAFalseConflict() throws {
        let backend = DNSFakeBackend(snapshot: snapshot(configuration: ["ServerAddresses": ["1.1.1.1"], "SearchDomains": ["example.test"]]))
        let target = try backend.snapshot.target()
        backend.snapshot.configuration = ["SearchDomains": ["example.test"], "ServerAddresses": ["1.1.1.1"]]
        _ = try DNSChangeTransaction.save(DNSChangeRequest(target: target, mode: .custom(["9.9.9.9"])), backend: backend)
        #expect(backend.events.contains("commit"))
    }

    @Test func readOnlyHardwareSmokeWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["FTOP_DNS_READ_SMOKE"] == "1" else { return }
        let state = DNSReader.read()
        var output: [String: Any] = ["source": state.source.rawValue, "defaultAddressCount": state.servers.count, "serviceCount": state.services.count]
        do {
            let target = try DNSNativeBackend().current().target()
            output["targetInterface"] = target.interfaceName
            output["manualAddressCount"] = target.manualServers.count
            output["hasBaseline"] = !target.configurationToken.isEmpty
        } catch let error as DNSChangeError {
            output["targetError"] = error.code.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print("DNS read-only smoke: " + String(decoding: data, as: UTF8.self))
        if let directory = ProcessInfo.processInfo.environment["FTOP_DNS_READ_SMOKE_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appending(path: "dns-read-smoke.json"), options: .atomic)
        }
        #expect(state.source != .unavailable)
    }

    private func snapshot(configuration: [String: Any]? = ["ServerAddresses": ["192.0.2.53"]], protocolExists: Bool = true) -> DNSConfigurationSnapshot {
        DNSConfigurationSnapshot(
            locationID: "location", serviceID: "wifi", serviceName: "Wi-Fi", interfaceName: "en0",
            protocolExists: protocolExists, protocolEnabled: protocolExists, configuration: configuration,
            network: ["ipv4": ["Addresses": ["192.0.2.2"], "Router": "192.0.2.1"], "link": ["Active": true]])
    }
}

private final class DNSFakeBackend: DNSWriteBackend {
    var snapshot: DNSConfigurationSnapshot
    var persisted: DNSConfigurationSnapshot
    var events: [String] = []
    var failureStage: String?
    var failureCode: DNSChangeError.Code?
    var hasExternalWriter = false
    var createdProtocol = false
    var commitStoresThenThrows = false
    var onAuthorize: (() -> Void)?
    var onStage: (() -> Void)?
    var onApply: (() -> Void)?

    init(snapshot: DNSConfigurationSnapshot) {
        self.snapshot = snapshot
        persisted = snapshot
    }
    func current() throws -> DNSConfigurationSnapshot { events.append("read"); return snapshot }
    func externalWriterRunning() -> Bool { hasExternalWriter }
    func authorize() throws { try event("authorize"); onAuthorize?() }
    func lock() throws { try event("lock") }
    func unlock() { events.append("unlock") }
    func stage(_ configuration: [String: Any], createProtocol: Bool) throws {
        try event("stage")
        snapshot.configuration = configuration
        snapshot.protocolExists = true
        snapshot.protocolEnabled = true
        createdProtocol = createProtocol
        onStage?()
    }
    func commit() throws {
        try event("commit")
        persisted = snapshot
        if commitStoresThenThrows { throw DNSChangeError(code: .writeFailed, message: "Fixture response lost after persistence") }
    }
    func apply() throws { try event("apply"); onApply?() }
    func reread(_ original: DNSConfigurationSnapshot) throws -> DNSConfigurationSnapshot { try event("verify"); return persisted }
    func state() -> DNSState { events.append("state"); return DNSState(servers: ["203.0.113.53"], source: .systemDefault) }
    private func event(_ name: String) throws {
        events.append(name)
        if failureStage == name { throw DNSChangeError(code: failureCode ?? (name == "authorize" ? .permissionDenied : .writeFailed), message: "Fixture failure") }
    }
}
