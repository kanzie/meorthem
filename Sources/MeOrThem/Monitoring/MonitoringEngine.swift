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

    /// Whether monitoring is paused (auto-pause during bandwidth test, or manual user pause).
    private(set) var isPaused = false

    /// Whether monitoring was explicitly paused by the user (disables bandwidth test trigger).
    private(set) var isManuallyPaused = false

    /// Most recently resolved default gateway IP (used to display gateway target in UI).
    private(set) var lastGatewayIP: String?

    // MARK: - Adaptive polling state
    private var consecutiveNonGreenPolls = 0
    private var isAdaptiveMode = false
    private var adaptiveResetGreenCount = 0

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

    /// Auto-pause (e.g., during bandwidth test). Ignored if user manually paused.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        stop()
        nextTickAt = .distantFuture
    }

    /// Auto-resume after bandwidth test. Ignored if user manually paused.
    func resume() {
        guard isPaused, !isManuallyPaused else { return }
        isPaused = false
        let interval = isAdaptiveMode ? max(2, settings.pollIntervalSecs / 2) : settings.pollIntervalSecs
        startEngine(interval: interval, fireImmediately: true)
    }

    /// User-initiated pause — stops monitoring and disables auto-resume.
    func manualPause() {
        isManuallyPaused = true
        isPaused = true
        stop()
        nextTickAt = .distantFuture
    }

    /// User-initiated resume — re-enables auto-resume and restarts monitoring.
    func manualResume() {
        isManuallyPaused = false
        isPaused = false
        let interval = isAdaptiveMode ? max(2, settings.pollIntervalSecs / 2) : settings.pollIntervalSecs
        startEngine(interval: interval, fireImmediately: true)
    }

    /// Call when poll interval setting changes — does not fire an immediate tick.
    func restart(interval: Double? = nil) {
        // Reset adaptive mode when restarted externally
        if interval != nil {
            isAdaptiveMode = false
            consecutiveNonGreenPolls = 0
            adaptiveResetGreenCount = 0
        }
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
        let wifi = WiFiMonitor.snapshot()
        store.recordWiFi(wifi)

        let targets = settings.pingTargets

        // Run all pings concurrently
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

        // Gateway ping for fault isolation — detect local vs ISP issues
        await pingGateway()

        // Adaptive polling — speed up when degraded, restore when healthy
        adaptPollInterval()
    }

    // MARK: - Gateway ping

    private func pingGateway() async {
        guard let gatewayIP = NetworkInfo.defaultGateway() else {
            store.recordGatewayPing(nil)
            return
        }
        lastGatewayIP = gatewayIP
        let result = await Self.pingHost(gatewayIP)
        // Store in regular history so gateway target shows sparklines + latency in the menu.
        store.record(result: result, for: PingTarget.gatewayID)
        // Also record for fault isolation logic.
        store.recordGatewayPing(result, gatewayIP: gatewayIP)
    }

    // MARK: - Adaptive polling

    private func adaptPollInterval() {
        let baseInterval = settings.pollIntervalSecs
        guard baseInterval > 2 else { return }  // already at or below minimum; no adaptation

        let status = store.overallStatus

        if status == .green {
            consecutiveNonGreenPolls = 0
            if isAdaptiveMode {
                adaptiveResetGreenCount += 1
                if adaptiveResetGreenCount >= 3 {
                    isAdaptiveMode = false
                    adaptiveResetGreenCount = 0
                    restart()   // restore original interval
                }
            }
        } else {
            adaptiveResetGreenCount = 0
            consecutiveNonGreenPolls += 1
            if !isAdaptiveMode && consecutiveNonGreenPolls >= 2 {
                isAdaptiveMode = true
                let faster = max(2, baseInterval / 2)
                restart(interval: faster)   // switch to faster polling; also resets adaptive state
                // Re-enable adaptive mode after restart() cleared it
                isAdaptiveMode = true
            }
        }
    }

    // MARK: - Ping helpers

    private static func pingTarget(_ target: PingTarget) async -> PingResult {
        await pingHost(target.host)
    }

    private static func pingHost(_ host: String) async -> PingResult {
        do {
            let output = try await PingMonitor.ping(host: host)
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
