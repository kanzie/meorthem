import Foundation

public struct WiFiSnapshot {
    public let timestamp: Date
    public let bssid: String
    /// Signal strength in dBm (typically -40 to -90)
    public let rssi: Int
    /// Noise floor in dBm (typically -90 to -100)
    public let noise: Int
    /// Signal-to-noise ratio in dB
    public let snr: Int
    public let channelNumber: Int
    public let channelBandGHz: Double   // 2.4 / 5.0 / 6.0
    public let txRateMbps: Double
    public let interfaceName: String
    public let macAddress: String
    public let phyMode: String
    public let ipAddress: String?
    public let routerIP: String?

    public init(timestamp: Date, bssid: String, rssi: Int, noise: Int, snr: Int,
                channelNumber: Int, channelBandGHz: Double, txRateMbps: Double,
                interfaceName: String, macAddress: String, phyMode: String,
                ipAddress: String?, routerIP: String?) {
        self.timestamp = timestamp
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.snr = snr
        self.channelNumber = channelNumber
        self.channelBandGHz = channelBandGHz
        self.txRateMbps = txRateMbps
        self.interfaceName = interfaceName
        self.macAddress = macAddress
        self.phyMode = phyMode
        self.ipAddress = ipAddress
        self.routerIP = routerIP
    }

    public var rssiQuality: String {
        switch rssi {
        case ..<(-80): return "Trash"
        case ..<(-65): return "Poor"
        case ..<(-55): return "Good"
        default:       return "Great"
        }
    }

    public var channelDescription: String {
        let ghzStr = channelBandGHz == 2.4 ? "2.4 GHz" :
                     channelBandGHz == 5.0 ? "5 GHz" :
                     channelBandGHz == 6.0 ? "6 GHz" : "Unknown"
        return "\(channelNumber) (\(ghzStr))"
    }
}
