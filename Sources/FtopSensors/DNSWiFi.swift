import AppKit
import CoreLocation
@preconcurrency import CoreWLAN
import Foundation

public enum DNSWiFiPermission: String, Sendable {
    case notDetermined, authorized, denied, restricted
}

public struct DNSWiFiReading: Sendable, Equatable {
    public var ssid: String?
    public var bssid: String?
    public var interfaceName: String?
    public var connected: Bool
    public var connectionKnown: Bool
    public var permission: DNSWiFiPermission

    public init(
        ssid: String? = nil, bssid: String? = nil, interfaceName: String? = nil,
        connected: Bool = false, connectionKnown: Bool = true,
        permission: DNSWiFiPermission
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.interfaceName = interfaceName
        self.connected = connected
        self.connectionKnown = connectionKnown
        self.permission = permission
    }
}

/// Reads the current association only. There is no scan, location fix, DNS
/// query, shell command, or proxy inspection. Call off the main thread because
/// CoreWLAN can perform synchronous local IPC.
public enum DNSWiFiReader {
    public static func read(permission: DNSWiFiPermission) -> DNSWiFiReading {
        guard permission == .authorized else {
            return DNSWiFiReading(connectionKnown: false, permission: permission)
        }
        guard let interfaces = CWWiFiClient.shared().interfaces(),
            !interfaces.isEmpty
        else {
            return DNSWiFiReading(connectionKnown: false, permission: permission)
        }
        let connected = interfaces.filter { $0.powerOn() && $0.serviceActive() }
        guard connected.count == 1, let interface = connected.first else {
            return DNSWiFiReading(
                connected: false, connectionKnown: connected.isEmpty,
                permission: permission)
        }
        return selected(
            ssid: interface.ssid(), bssid: interface.bssid(),
            interfaceName: interface.interfaceName, connected: true,
            permission: permission)
    }

    static func selected(
        ssid: String?, bssid: String? = nil, interfaceName: String?,
        connected: Bool, permission: DNSWiFiPermission
    ) -> DNSWiFiReading {
        guard permission == .authorized else {
            return DNSWiFiReading(connectionKnown: false, permission: permission)
        }
        guard connected else { return DNSWiFiReading(permission: permission) }
        guard let interfaceName, !interfaceName.isEmpty else {
            return DNSWiFiReading(connectionKnown: false, permission: permission)
        }
        let name = ssid.flatMap {
            $0.isEmpty || $0 == "<redacted>" ? nil : $0
        }
        let accessPoint = bssid.flatMap {
            $0.isEmpty || $0 == "<redacted>" ? nil : $0
        }
        return DNSWiFiReading(
            ssid: name, bssid: accessPoint, interfaceName: interfaceName,
            connected: true, permission: permission)
    }
}

/// Permission is requested only from the rules UI. Events are hints; every DNS
/// transaction rereads both the association and its immutable service baseline.
@MainActor
public final class DNSWiFiMonitor: NSObject, CLLocationManagerDelegate,
    CWEventDelegate
{
    public var onChange: (() -> Void)?
    private let location = CLLocationManager()
    private let wifi = CWWiFiClient.shared()
    private var monitoring = false
    private var wakeObserver: NSObjectProtocol?

    public override init() {
        super.init()
        location.delegate = self
    }

    public var permission: DNSWiFiPermission {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    public func requestAccess() {
        if permission == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else {
            onChange?()
        }
    }

    public func start() {
        guard !monitoring else { return }
        monitoring = true
        wifi.delegate = self
        for event: CWEventType in [
            .ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange,
        ] {
            try? wifi.startMonitoringEvent(with: event)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.changed()
        }
    }

    public func stop() {
        guard monitoring else { return }
        try? wifi.stopMonitoringAllEvents()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        monitoring = false
    }

    public nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        changed()
    }

    public nonisolated func ssidDidChangeForWiFiInterface(
        withName interfaceName: String
    ) { changed() }
    public nonisolated func bssidDidChangeForWiFiInterface(
        withName interfaceName: String
    ) { changed() }
    public nonisolated func linkDidChangeForWiFiInterface(
        withName interfaceName: String
    ) { changed() }
    public nonisolated func powerStateDidChangeForWiFiInterface(
        withName interfaceName: String
    ) { changed() }

    private nonisolated func changed() {
        Task { @MainActor [weak self] in
            guard let self, monitoring else { return }
            onChange?()
        }
    }
}
