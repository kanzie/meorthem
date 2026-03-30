import Foundation

struct WiFiSnapshot {
    let timestamp: Date
    let ssid: String
    let bssid: String
    /// Signal strength in dBm (typically -40 to -90)
    let rssi: Int
    /// Noise floor in dBm (typically -90 to -100)
    let noise: Int
    /// Signal-to-noise ratio in dB
    let snr: Int
    let channelNumber: Int
    let channelBandGHz: Double   // 2.4 / 5.0 / 6.0
    let txRateMbps: Double
    let interfaceName: String
    let macAddress: String
    let phyMode: String
    let ipAddress: String?
    let routerIP: String?

    var rssiQuality: String {
        switch rssi {
        case ..<(-80): return "Trash"
        case ..<(-65): return "Poor"
        case ..<(-55): return "Good"
        default:       return "Great"
        }
    }

    var channelDescription: String {
        let ghzStr = channelBandGHz == 2.4 ? "2.4 GHz" :
                     channelBandGHz == 5.0 ? "5 GHz" :
                     channelBandGHz == 6.0 ? "6 GHz" : "Unknown"
        return "\(channelNumber) (\(ghzStr))"
    }
}
