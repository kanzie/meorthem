import Foundation
import CoreWLAN
import Combine

/// Reads current WiFi interface stats synchronously (always called on @MainActor).
enum WiFiMonitor {
    static func snapshot() -> WiFiSnapshot? {
        // CWWiFiClient is not thread-safe — must be called on main thread.
        // MonitoringEngine dispatches this to @MainActor, so we are safe.
        let client = CWWiFiClient.shared()
        guard let iface = client.interface(), iface.wlanChannel() != nil else {
            return nil
        }

        let rssi  = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let chan  = iface.wlanChannel()
        let band: Double = {
            guard let b = chan?.channelBand else { return 2.4 }
            switch b {
            case .band2GHz: return 2.4
            case .band5GHz: return 5.0
            case .band6GHz: return 6.0
            case .bandUnknown: return 0
            @unknown default:  return 0
            }
        }()

        let ifaceName = iface.interfaceName ?? "en0"

        return WiFiSnapshot(
            timestamp:      Date(),
            ssid:           iface.ssid() ?? "Unknown",
            bssid:          iface.bssid() ?? "—",
            rssi:           rssi,
            noise:          noise,
            snr:            rssi - noise,
            channelNumber:  chan?.channelNumber ?? 0,
            channelBandGHz: band,
            txRateMbps:     iface.transmitRate(),
            interfaceName:  ifaceName,
            macAddress:     iface.hardwareAddress() ?? "—",
            phyMode:        phyModeString(iface.activePHYMode()),
            ipAddress:      NetworkInfo.ipAddress(for: ifaceName),
            routerIP:       NetworkInfo.defaultGateway()
        )
    }

    static func interfaceName() -> String? {
        CWWiFiClient.shared().interface()?.interfaceName
    }

    private static func phyModeString(_ mode: CWPHYMode) -> String {
        switch mode {
        case .modeNone: return "—"
        case .mode11a:  return "802.11a"
        case .mode11b:  return "802.11b"
        case .mode11g:  return "802.11g"
        case .mode11n:  return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Reactive WiFi observer

/// Subscribes to CWEventDelegate notifications and publishes fresh snapshots
/// whenever the OS reports a signal-strength or SSID change.
@MainActor
final class WiFiObserver: NSObject, CWEventDelegate {
    static let shared = WiFiObserver()

    /// Fires with a new snapshot (or nil when disconnected) on every relevant event.
    let wifiChanged = PassthroughSubject<WiFiSnapshot?, Never>()

    private let client = CWWiFiClient.shared()

    private override init() {
        super.init()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .bssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        try? client.startMonitoringEvent(with: .linkQualityDidChange)
    }

    // MARK: CWEventDelegate

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }

    nonisolated func linkQualityDidChangeForWiFiInterface(withName interfaceName: String,
                                                          rssi: Int,
                                                          transmitRate: Double) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }
}
