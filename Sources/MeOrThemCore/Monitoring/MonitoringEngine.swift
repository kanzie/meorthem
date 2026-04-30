import Foundation
import Combine

@MainActor
public final class MonitoringEngine {
    private let settings: AppSettings
    private let store: MetricStore
    private var timer: Timer?
    private var isRunning = false
    private let cpuSampler = CPUSampler()

    /// Fires once at the start of every poll tick — used to drive the heartbeat dot.
    public let tickStarted = PassthroughSubject<Void, Never>()

    /// The scheduled fire date of the next poll tick (updated when the timer is scheduled).
    public private(set) var nextTickAt: Date = .distantFuture

    /// Whether monitoring is paused (auto-pause during bandwidth test, or manual user pause).
    public private(set) var isPaused = false

    /// Whether monitoring was explicitly paused by the user (disables bandwidth test trigger).
    public private(set) var isManuallyPaused = false

    /// Most recently resolved default gateway IP (used to display gateway target in UI).
    public private(set) var lastGatewayIP: String?

    // MARK: - Adaptive polling state
    private var consecutiveNonGreenPolls = 0
    private var isAdaptiveMode = false
    private var adaptiveResetGreenCount = 0

    // MARK: - Stealth mode
    /// When true, TCP probing is used instead of ICMP for external targets.
    /// Set by AppEnvironment when the current network profile has ICMP throttling detected.
    public var stealthModeActive: Bool = false

    /// Fires after each tick's pings and gateway probe complete.
    /// Used by AppEnvironment to run stealth-mode detection.
    public var onTickCompleted: (() -> Void)?

    // MARK: - Periodic sampling counter (DNS, interface errors, MTU)
    private var tickCount = 0

    // MARK: - Interface error delta tracking
    /// Cumulative counters from the most-recent sample — used to compute deltas.
    private var lastInterfaceCounters: InterfaceMonitor.Counters?

    public init(settings: AppSettings, metricStore: MetricStore) {
        self.settings = settings
        self.store = metricStore
    }

    public func start(fireImmediately: Bool = true) {
        startEngine(interval: settings.pollIntervalSecs, fireImmediately: fireImmediately)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        nextTickAt = .distantFuture
    }

    /// Auto-pause (e.g., during bandwidth test). Ignored if user manually paused.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        stop()
        nextTickAt = .distantFuture
    }

    /// Auto-resume after bandwidth test. Ignored if user manually paused.
    public func resume() {
        guard isPaused, !isManuallyPaused else { return }
        isPaused = false
        let interval = isAdaptiveMode ? max(2, settings.pollIntervalSecs / 2) : settings.pollIntervalSecs
        startEngine(interval: interval, fireImmediately: true)
    }

    /// User-initiated pause — stops monitoring and disables auto-resume.
    public func manualPause() {
        isManuallyPaused = true
        isPaused = true
        stop()
        nextTickAt = .distantFuture
    }

    /// User-initiated resume — re-enables auto-resume and restarts monitoring.
    public func manualResume() {
        isManuallyPaused = false
        isPaused = false
        let interval = isAdaptiveMode ? max(2, settings.pollIntervalSecs / 2) : settings.pollIntervalSecs
        startEngine(interval: interval, fireImmediately: true)
    }

    /// Call when poll interval setting changes — does not fire an immediate tick.
    /// Resets adaptive-polling state so the new interval takes effect cleanly.
    public func restart(interval: Double? = nil) {
        guard !isPaused else { return }
        isAdaptiveMode = false
        consecutiveNonGreenPolls = 0
        adaptiveResetGreenCount = 0
        stop()
        startEngine(interval: interval ?? settings.pollIntervalSecs, fireImmediately: false)
    }

    /// Internal restart used by adaptive polling — preserves adaptive state.
    private func restartAdaptive(interval: Double) {
        stop()
        startEngine(interval: interval, fireImmediately: false)
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

        // Sample CPU before pings run — captures the load level that could affect timing.
        store.recordSystemLoad(cpuSampler.sample())

        // WiFi snapshot first — must run on main thread (CWWiFiClient requirement).
        let wifi = WiFiMonitor.snapshot()
        store.recordWiFi(wifi)

        let targets = settings.pingTargets

        // Run pings concurrently, capped at 5 simultaneous tasks to avoid process exhaustion.
        let concurrencyCap = min(targets.count, 5)
        let useStealthMode = stealthModeActive
        await withTaskGroup(of: (UUID, PingResult).self) { group in
            var pending = targets[...]
            // Seed up to the cap
            for _ in 0..<concurrencyCap {
                guard let target = pending.popFirst() else { break }
                group.addTask {
                    let result = await Self.pingTarget(target, stealth: useStealthMode)
                    return (target.id, result)
                }
            }
            for await (id, result) in group {
                store.record(result: result, for: id)
                // Start next pending target as a slot becomes free
                if let target = pending.popFirst() {
                    group.addTask {
                        let result = await Self.pingTarget(target, stealth: useStealthMode)
                        return (target.id, result)
                    }
                }
            }
        }

        // Gateway ping for fault isolation — detect local vs ISP issues
        await pingGateway()

        // Notify AppEnvironment that the full tick (pings + gateway) is complete.
        // This is the correct moment for stealth-mode detection — all latestPing values are fresh.
        onTickCompleted?()

        // Adaptive polling — speed up when degraded, restore when healthy
        adaptPollInterval()

        // Increment tick counter for periodic background measurements
        tickCount += 1

        // Multi-resolver DNS probe — every 6th tick (~30 s at 5 s poll interval).
        // Raw UDP queries bypass mDNSResponder cache; probes run concurrently via TaskGroup.
        if tickCount % 6 == 0 {
            let activeResolvers = settings.dnsResolvers.filter { $0.isEnabled && $0.autoDisabledAt == nil }
            if !activeResolvers.isEmpty {
                // Capture dynamic IPs before leaving the MainActor.
                let gatewayIP = lastGatewayIP
                Task { [weak self] in
                    guard let self else { return }
                    let results = await Task.detached(priority: .utility) {
                        await withTaskGroup(of: (DNSResolver, Double?, Int?, String?).self) { group in
                            for resolver in activeResolvers {
                                let ip: String?
                                if resolver.isGateway      { ip = gatewayIP }
                                else if resolver.isSystem  { ip = DNSProber.systemResolverIP() }
                                else                       { ip = resolver.ip.isEmpty ? nil : resolver.ip }
                                guard let resolvedIP = ip else { continue }
                                group.addTask {
                                    let (ms, rcode, resolved) = DNSProber.probeWithAnswer(resolverIP: resolvedIP)
                                    return (resolver, ms, rcode, resolved)
                                }
                            }
                            var out: [(DNSResolver, Double?, Int?, String?)] = []
                            for await r in group { out.append(r) }
                            return out
                        }
                    }.value

                    let anySucceeded = results.contains { $0.1 != nil }

                    // DNS hijack detection: compare A-record answers across resolvers.
                    // A private-space answer from any resolver is an immediate signal.
                    // Differing public answers across ≥2 resolvers is a softer signal.
                    let answerIPs = results.compactMap { $0.3 }
                    let hijackSuspected: Bool
                    if answerIPs.isEmpty {
                        hijackSuspected = false
                    } else if answerIPs.contains(where: { DNSProber.isPrivateIP($0) }) {
                        hijackSuspected = true
                    } else if answerIPs.count >= 2 {
                        hijackSuspected = Set(answerIPs).count > 1
                    } else {
                        hijackSuspected = false
                    }

                    for (resolver, ms, rcode, _) in results {
                        self.store.recordDNSResolverSample(resolver: resolver, resolveMs: ms, rcode: rcode)
                        await MainActor.run {
                            self.settings.updateDNSResolverFailureCount(
                                id: resolver.id,
                                succeeded: ms != nil,
                                otherResolversOK: anySucceeded && ms == nil ? true : anySucceeded)
                        }
                    }
                    await MainActor.run { self.store.recordDNSHijackSuspicion(hijackSuspected) }
                    // Refresh the summary once all results are recorded.
                    let enabledSummary = activeResolvers.map { (name: $0.name, ip: $0.isGateway ? (gatewayIP ?? "") : ($0.isSystem ? (DNSProber.systemResolverIP() ?? "") : $0.ip)) }
                    self.store.refreshDNSSummary(enabledResolvers: enabledSummary)
                }
            }
        }

        // Re-probe auto-disabled resolvers — every 60th tick (~5 min), offset by 30.
        // Only one probe per disabled resolver; re-enables on success.
        if tickCount % 60 == 30 {
            let disabledResolvers = settings.dnsResolvers.filter { $0.isEnabled && $0.autoDisabledAt != nil }
            if !disabledResolvers.isEmpty {
                let gatewayIP = lastGatewayIP
                Task { [weak self] in
                    guard let self else { return }
                    for resolver in disabledResolvers {
                        let ip: String?
                        if resolver.isGateway      { ip = gatewayIP }
                        else if resolver.isSystem  { ip = DNSProber.systemResolverIP() }
                        else                       { ip = resolver.ip.isEmpty ? nil : resolver.ip }
                        guard let resolvedIP = ip else { continue }
                        let (ms, _) = await Task.detached(priority: .utility) {
                            DNSProber.probe(resolverIP: resolvedIP)
                        }.value
                        if ms != nil {
                            await MainActor.run { self.settings.reEnableDNSResolver(id: resolver.id) }
                        }
                    }
                }
            }
        }

        // Interface error sample — every 6th tick, offset by 3 ticks (~30 s, staggered from DNS).
        // Reads cumulative netstat counters and stores the delta since the last reading.
        if tickCount % 6 == 3 {
            // Prefer the interface name from the latest WiFi snapshot (most reliable).
            // If WiFi is not active, ask the routing table which interface carries the
            // default route — this correctly handles Ethernet (en1, etc.), VPN (utun/ppp),
            // and any other interface type. Do NOT fall back to a hardcoded "en0"; if no
            // interface is found skip this sample rather than reading the wrong adapter.
            guard let iface = store.latestWifi?.interfaceName
                           ?? NetworkInfo.defaultGatewayInterface() else { return }
            Task { [weak self] in
                guard let self else { return }
                let counters = await Task.detached(priority: .utility) {
                    InterfaceMonitor.readCounters(for: iface)
                }.value
                guard let counters else { return }

                if let prev = self.lastInterfaceCounters {
                    // Compute deltas, clamping negatives (counter reset / interface restart)
                    let dErrIn  = max(0, Int64(counters.errorsIn)  - Int64(prev.errorsIn))
                    let dErrOut = max(0, Int64(counters.errorsOut) - Int64(prev.errorsOut))
                    let dDropIn = max(0, Int64(counters.dropsIn)   - Int64(prev.dropsIn))
                    self.store.recordInterfaceDelta(errorsIn: dErrIn, errorsOut: dErrOut,
                                                   dropsIn: dDropIn, iface: counters.iface)
                }
                self.lastInterfaceCounters = counters
            }
        }

        // MTU probe — every 30th tick (~150 s at 5 s poll interval), offset by 15 ticks.
        // Probes the first external ping target with a 1472-byte payload (Don't-Fragment).
        // A loss where normal pings succeed indicates MTU-related path fragmentation.
        if tickCount % 30 == 15 {
            if let probeHost = settings.pingTargets.first?.host {
                Task { [weak self] in
                    guard let self else { return }
                    let result = await Task.detached(priority: .utility) {
                        MTUChecker.probe(host: probeHost)
                    }.value
                    if let result {
                        self.store.recordMTUResult(host: probeHost,
                                                   payloadBytes: result.payloadBytes,
                                                   reachable: result.reachable,
                                                   rttMs: result.rttMs)
                    }
                }
            }
        }
    }

    // MARK: - Gateway ping

    private func pingGateway() async {
        // NetworkInfo.defaultGateway() spawns /sbin/route and calls waitUntilExit() when
        // the 30-second cache expires. Run it off the MainActor to avoid blocking the
        // main thread during that brief subprocess wait.
        let gatewayIP = await Task.detached { NetworkInfo.defaultGateway() }.value
        guard let gatewayIP else {
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
            // Only accelerate polling on red status — yellow (e.g. transient latency spikes)
            // should not drain battery by halving the poll interval unnecessarily.
            if status == .red { consecutiveNonGreenPolls += 1 }
            if !isAdaptiveMode && consecutiveNonGreenPolls >= 2 {
                isAdaptiveMode = true
                let faster = max(2, baseInterval / 2)
                restartAdaptive(interval: faster)
            }
        }
    }

    // MARK: - Ping helpers

    private static func pingTarget(_ target: PingTarget, stealth: Bool) async -> PingResult {
        switch target.probeMode {
        case .http:  return await httpProbeTarget(target.host, useHTTPS: false)
        case .https: return await httpProbeTarget(target.host, useHTTPS: true)
        case .tcp:   return await tcpProbeTarget(target.host)
        case .icmp:
            if stealth { return await tcpProbeTarget(target.host) }
            return await pingHost(target.host)
        }
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

    /// TCP-based reachability probe used in stealth mode (ICMP blocked).
    /// Tries ports 443, 80, 53. Reports 0% loss on connect, 100% on failure.
    private static func tcpProbeTarget(_ host: String) async -> PingResult {
        if let (rttMs, _) = await TCPProber.probeAny(host: host) {
            return PingResult(timestamp: Date(), rtt: rttMs, lossPercent: 0, jitter: nil)
        }
        return PingResult(timestamp: Date(), rtt: nil, lossPercent: 100, jitter: nil)
    }

    /// HTTP/HTTPS probe — measures time-to-first-byte via a HEAD request.
    /// RTT = TTFB in ms; loss = 0 on 2xx/3xx, 100 on error or 4xx/5xx.
    private static func httpProbeTarget(_ host: String, useHTTPS: Bool) async -> PingResult {
        let result = await HTTPProber.probe(host: host, useHTTPS: useHTTPS)
        return PingResult(timestamp: Date(), rtt: result.rttMs,
                          lossPercent: result.lossPercent, jitter: nil)
    }
}
