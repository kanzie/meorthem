import Foundation

@MainActor
final class MonitoringEngine {
    private let settings: AppSettings
    private let store: MetricStore
    private var timer: Timer?
    private var isRunning = false

    init(settings: AppSettings, metricStore: MetricStore) {
        self.settings = settings
        self.store = metricStore
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer()
        // Run immediately on launch
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Call when poll interval setting changes.
    func restart() {
        stop()
        start()
    }

    // MARK: - Private

    private func scheduleTimer() {
        let interval = settings.pollIntervalSecs
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick() }
        }
        t.tolerance = interval * 0.1   // 10% tolerance aids power efficiency
        RunLoop.main.add(t, forMode: .common)  // fires even during menu tracking
        timer = t
    }

    private func tick() async {
        let targets = settings.pingTargets

        // Run all pings concurrently, then update store on MainActor
        await withTaskGroup(of: (UUID, PingResult).self) { group in
            for target in targets {
                group.addTask {
                    let result = await Self.pingTarget(target)
                    return (target.id, result)
                }
            }
            for await (id, result) in group {
                store.record(result: result, for: id)
            }
        }

        // WiFi snapshot — must run on main thread (CWWiFiClient requirement)
        let wifi = WiFiMonitor.snapshot()
        store.recordWiFi(wifi)
    }

    private static func pingTarget(_ target: PingTarget) async -> PingResult {
        do {
            let output = try await PingMonitor.ping(host: target.host)
            let parsed = PingParser.parse(output)
            let avg    = parsed.rtts.isEmpty ? nil : parsed.rtts.reduce(0, +) / Double(parsed.rtts.count)
            let jitter = JitterCalculator.jitter(from: parsed.rtts)
            return PingResult(
                timestamp:   Date(),
                rtt:         avg,
                lossPercent: parsed.lossPercent,
                jitter:      jitter
            )
        } catch {
            return PingResult(timestamp: Date(), rtt: nil, lossPercent: 100, jitter: nil)
        }
    }
}
