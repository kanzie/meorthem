import Foundation
import CoreWLAN
import Combine
import SystemConfiguration

/// Reads current WiFi interface stats synchronously (always called on @MainActor).
enum WiFiMonitor {
    static func snapshot() -> WiFiSnapshot? {
        // CWWiFiClient is not thread-safe — must be called on main thread.
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
        case .mode11be: return "802.11be"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Reactive WiFi observer (app target — wraps CWEventDelegate)

/// Subscribes to CWEventDelegate notifications and publishes fresh snapshots
/// whenever the OS reports a signal-strength or link change.
@MainActor
final class WiFiObserver: NSObject, CWEventDelegate {
    static let shared = WiFiObserver()

    let wifiChanged = PassthroughSubject<WiFiSnapshot?, Never>()

    private let client = CWWiFiClient.shared()

    private override init() {
        super.init()
        client.delegate = self
        try? client.startMonitoringEvent(with: .bssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        // linkQualityDidChange is intentionally NOT subscribed — it fires on every RSSI
        // fluctuation (can be dozens/sec) and RSSI is already captured on every poll tick.
        // Subscribing to it caused networksetup subprocess spawning at high frequency → ~20% CPU.
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in wifiChanged.send(WiFiMonitor.snapshot()) }
    }
}
