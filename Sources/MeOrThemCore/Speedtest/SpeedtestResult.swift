import Foundation

public struct SpeedtestResult {
    public let downloadMbps: Double
    public let uploadMbps:   Double
    public let latencyMs:    Double
    public let jitterMs:     Double
    public let isp:          String
    public let serverName:   String
    public let timestamp:    Date

    public init(downloadMbps: Double, uploadMbps: Double, latencyMs: Double,
                jitterMs: Double, isp: String, serverName: String, timestamp: Date) {
        self.downloadMbps = downloadMbps
        self.uploadMbps   = uploadMbps
        self.latencyMs    = latencyMs
        self.jitterMs     = jitterMs
        self.isp          = isp
        self.serverName   = serverName
        self.timestamp    = timestamp
    }

    public var downloadFormatted: String { String(format: "%.1f Mbps", downloadMbps) }
    public var uploadFormatted:   String { String(format: "%.1f Mbps", uploadMbps) }
    public var latencyFormatted:  String { String(format: "%.1f ms",   latencyMs) }
}
