import Foundation

public struct HTTPProbeResult {
    /// Time-to-first-byte in milliseconds; nil on timeout or network error.
    public let rttMs: Double?
    /// 0.0 on any 2xx/3xx response; 100.0 on network error or 4xx/5xx.
    public let lossPercent: Double
    /// HTTP status code, nil on network error.
    public let statusCode: Int?
}

/// Measures HTTP/HTTPS reachability and time-to-first-byte via a HEAD request.
///
/// Uses an ephemeral URLSession (no cookies, no cache) with a 5-second timeout.
/// Follows up to 3 redirects. 2xx/3xx responses count as success; 4xx/5xx as loss.
public enum HTTPProber {

    private static let timeout: TimeInterval = 5

    public static func probe(host: String, useHTTPS: Bool) async -> HTTPProbeResult {
        let scheme = useHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host)") else {
            return HTTPProbeResult(rttMs: nil, lossPercent: 100, statusCode: nil)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = timeout
        config.timeoutIntervalForResource = timeout
        // Disable any persistent storage
        config.urlCache                   = nil
        config.httpCookieStorage          = nil
        config.httpMaximumConnectionsPerHost = 1

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "HEAD"

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let loss: Double = statusCode.map { $0 >= 400 ? 100.0 : 0.0 } ?? 100.0
            return HTTPProbeResult(rttMs: elapsed, lossPercent: loss, statusCode: statusCode)
        } catch {
            return HTTPProbeResult(rttMs: nil, lossPercent: 100, statusCode: nil)
        }
    }
}
