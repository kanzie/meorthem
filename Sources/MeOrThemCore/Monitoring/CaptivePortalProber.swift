import Foundation

/// Detects captive portals (hotel/airport/coffee-shop login pages) by making a single
/// HTTP request to a known URL and comparing the response body and final URL to expected values.
///
/// Uses the same endpoint Apple's CaptiveNetworkSupport framework checks internally.
/// One probe per session open — zero steady-state overhead.
public enum CaptivePortalProber {

    /// Expected body from captive.apple.com when the path to the internet is clear.
    private static let successBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    private static let probeURL    = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private static let timeout: TimeInterval = 5

    /// Returns `true` when a captive portal is detected, `false` when the connection is clear,
    /// and `nil` when the probe itself failed (e.g. complete network outage — inconclusive).
    public static func probe() async -> Bool? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache                   = nil
        config.httpCookieStorage          = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: probeURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            // A redirect to a login page means the final URL will differ from the probe URL,
            // or the status code will be non-200.
            if http.statusCode != 200 { return true }
            if let finalURL = http.url, finalURL.host != probeURL.host { return true }

            let body = String(data: data, encoding: .utf8) ?? ""
            return body.trimmingCharacters(in: .whitespacesAndNewlines) != successBody
        } catch {
            // Network errors are inconclusive — could be a full outage with no portal.
            return nil
        }
    }
}
