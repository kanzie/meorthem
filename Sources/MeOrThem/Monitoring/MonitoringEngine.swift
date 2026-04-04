import Foundation
import Combine

@MainActor
final class MonitoringEngine {
    private let settings: AppSettings
    private let store: MetricStore
    private var timer: Timer?
    private var isRunning = false

    /// Fires once at the start of every poll tick — used to drive the heartbeat dot.
    let tickStarted = PassthroughSubject<Void, Never>()

    /// The scheduled fire date of the next poll tick (updated when the timer is scheduled).
    private(set) var nextTickAt: Date = .distantFuture

    init(settings: AppSettings, metricStore: MetricStore) {
        self.settings = settings
        self.store = metricStore
    }

    func start(fireImmediately: Bool = true) {
        startEngine(interval: settings.pollIntervalSecs, fireImmediately: fireImmediately)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        nextTickAt = .distantFuture
    }

    /// Call when poll interval setting changes — does not fire an immediate tick.
    /// Pass `interval` directly from the @Published sink value to avoid reading
    /// the stale property (@Published fires in willSet, before storage is committed).
    func restart(interval: Double? = nil) {
        stop()
        startEngine(interval: interval ?? settings.pollIntervalSecs, fireImmediately: false)
    }

    // MARK: - Private

    private func startEngine(interval: Double, fireImmediately: Bool) {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer(interval: interval)
        if fireImmediately {
            Task { await tick() }
        }
    }

    private func scheduleTimer(interval: Double) {
        nextTickAt = Date().addingTimeInterval(interval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.nextTickAt = Date().addingTimeInterval(interval)
                await self.tick()
            }
        }
        t.tolerance = interval * 0.1   // 10% tolerance aids power efficiency
        RunLoop.main.add(t, forMode: .common)  // fires even during menu tracking
        timer = t
    }

    private func tick() async {
        tickStarted.send()

        // WiFi snapshot first — must run on main thread (CWWiFiClient requirement).
        // Taken before pings so the store is populated even on the first tick.
        let wifi = WiFiMonitor.snapshot()
        store.recordWiFi(wifi)

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
