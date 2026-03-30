import Foundation

struct SpeedtestResult {
    let downloadMbps: Double
    let uploadMbps:   Double
    let latencyMs:    Double
    let jitterMs:     Double
    let isp:          String
    let serverName:   String
    let timestamp:    Date

    var downloadFormatted: String { String(format: "%.1f Mbps", downloadMbps) }
    var uploadFormatted:   String { String(format: "%.1f Mbps", uploadMbps) }
    var latencyFormatted:  String { String(format: "%.1f ms",   latencyMs) }
}
