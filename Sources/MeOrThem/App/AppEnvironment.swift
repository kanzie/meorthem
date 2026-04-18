import Foundation
import Combine
import MeOrThemCore

@MainActor
final class AppEnvironment {
    let settings:          AppSettings
    let sqliteStore:       SQLiteStore
    let metricStore:       MetricStore
    let monitoringEngine:  MonitoringEngine
    let alertManager:      AlertManager
    let speedtestRunner:   SpeedtestRunner
    let exportCoordinator: ExportCoordinator
    let logExporter:       LogExporter

    private var cancellables = Set<AnyCancellable>()
    private var bandwidthScheduleTimer: Timer?
    private var maintenanceTimer: Timer?
    private var lastBandwidthScheduleHours: Double = 0

    // Session tracking — persisted fingerprint and active session ID
    private var currentSessionFingerprint: String?

    // Traceroute rate-limiting: don't fire more than once per 5 minutes
    private var lastTracerouteDate: Date?
    private let tracerouteDebounce: TimeInterval = 300

    init() {
        settings          = AppSettings.shared
        sqliteStore       = SQLiteStore.makeDefault()
        metricStore       = MetricStore(settings: settings, sqliteStore: sqliteStore)
        alertManager      = AlertManager(settings: settings)
        speedtestRunner   = SpeedtestRunner()
        monitoringEngine  = MonitoringEngine(settings: settings, metricStore: metricStore)
        exportCoordinator = ExportCoordinator(metricStore: metricStore, settings: settings, sqliteStore: sqliteStore)
        logExporter       = LogExporter(settings: settings)

        // Wire status changes → notification alerts
        metricStore.$overallStatus
            .dropFirst()
            .sink { [weak self] status in
                self?.alertManager.handleStatusChange(status)
            }
            .store(in: &cancellables)

        // Traceroute trigger: fire when the connection degrades to red (confirmed outage).
        // Debounced to at most once per 5 minutes to avoid hammering the network.
        metricStore.$overallStatus
            .scan((MetricStatus.green, MetricStatus.green)) { acc, new in (acc.1, new) }
            .filter { prev, curr in prev == .green && curr == .red }
            .sink { [weak self] _ in self?.triggerTraceroute() }
            .store(in: &cancellables)

        // Restart monitoring engine when poll interval changes.
        settings.$pollIntervalSecs
            .dropFirst()
            .sink { [weak self] newInterval in
                self?.monitoringEngine.restart(interval: newInterval)
            }
            .store(in: &cancellables)

        // React to OS WiFi events immediately (RSSI, link changes)
        WiFiObserver.shared.wifiChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.metricStore.recordWiFi(snapshot)
            }
            .store(in: &cancellables)

        // Track network sessions: open a new session whenever the WiFi fingerprint changes.
        // The fingerprint encodes gateway IP + channel + band + subnet prefix, giving us
        // SSID-like session grouping without requiring Location Services.
        metricStore.$latestWifi
            .sink { [weak self] snapshot in
                guard let self else { return }
                guard let snapshot,
                      let key = NetworkSessionKey.from(wifi: snapshot) else { return }
                guard key.fingerprint != self.currentSessionFingerprint else {
                    // Same network — just touch the session to keep last_seen current
                    if let sid = self.metricStore.currentSessionID {
                        self.sqliteStore.touchSession(id: sid)
                    }
                    return
                }
                // New network fingerprint — open a fresh session
                let newID = UUID()
                self.currentSessionFingerprint   = key.fingerprint
                self.metricStore.currentSessionID = newID
                self.sqliteStore.openSession(id: newID,
                                             fingerprint: key.fingerprint,
                                             displayName: key.displayName)
                // Reset DNS resolver failure counts — a resolver unreachable on one
                // network may be fine on another.
                self.settings.resetDNSResolverFailureCounts()
            }
            .store(in: &cancellables)

        // Pause/resume monitoring during bandwidth tests; persist completed results to SQLite
        speedtestRunner.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .running:
                    self.monitoringEngine.pause()
                case .completed(let result):
                    if self.monitoringEngine.isPaused { self.monitoringEngine.resume() }
                    self.sqliteStore.insertSpeedtest(
                        timestamp:    result.timestamp,
                        downloadMbps: result.downloadMbps,
                        uploadMbps:   result.uploadMbps,
                        latencyMs:    result.latencyMs,
                        jitterMs:     result.jitterMs,
                        isp:          result.isp,
                        serverName:   result.serverName
                    )
                case .failed, .idle, .unavailable:
                    if self.monitoringEngine.isPaused { self.monitoringEngine.resume() }
                }
            }
            .store(in: &cancellables)

        // Bandwidth test scheduling — trigger immediately when enabling from disabled.
        lastBandwidthScheduleHours = settings.bandwidthScheduleHours
        rescheduleBandwidthTimer(hours: settings.bandwidthScheduleHours)
        settings.$bandwidthScheduleHours
            .dropFirst()
            .sink { [weak self] hours in
                guard let self else { return }
                let wasDisabled = self.lastBandwidthScheduleHours == 0
                self.lastBandwidthScheduleHours = hours
                self.rescheduleBandwidthTimer(hours: hours)
                if wasDisabled && hours > 0 {
                    Task { @MainActor [weak self] in
                        guard let self, case .idle = self.speedtestRunner.state else { return }
                        self.speedtestRunner.run()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-start bandwidth test at launch if scheduling is enabled
        if settings.bandwidthScheduleHours > 0 {
            Task { @MainActor [weak self] in
                guard let self, case .idle = self.speedtestRunner.state else { return }
                self.speedtestRunner.run()
            }
        }

        // Continuous CSV append log — start on launch, react to setting changes.
        logExporter.start()
        settings.$enableLogRotation
            .dropFirst()
            .sink { [weak self] enabled in
                self?.logExporter.enabledDidChange(enabled)
            }
            .store(in: &cancellables)

        // Feed new ping samples to the log exporter.
        metricStore.onPingRecorded = { [weak self] result, targetID in
            guard let self else { return }
            guard let target = self.settings.pingTargets.first(where: { $0.id == targetID })
                           ?? (targetID == PingTarget.gatewayID
                               ? PingTarget(id: PingTarget.gatewayID, label: "Gateway",
                                            host: self.metricStore.latestGatewayIP ?? "gateway",
                                            isSystem: true)
                               : nil)
            else { return }
            self.logExporter.appendPing(result, target: target)
        }

        // Feed WiFi snapshots to the log exporter.
        metricStore.onWiFiRecorded = { [weak self] snapshot in
            self?.logExporter.appendWiFi(snapshot)
        }

        // SQLite maintenance: aggregate + prune on launch, then every hour.
        runSQLiteMaintenance()
        let mt = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runSQLiteMaintenance() }
        }
        mt.tolerance = 300   // ±5 min jitter is fine for housekeeping
        RunLoop.main.add(mt, forMode: .common)
        maintenanceTimer = mt
    }

    private func runSQLiteMaintenance() {
        sqliteStore.aggregateAndPrune(
            rawRetentionDays:       settings.rawRetentionDays,
            aggregateRetentionDays: settings.aggregateRetentionDays,
            incidentRetentionDays:  settings.incidentRetentionDays
        )
    }

    // MARK: - Traceroute on degradation

    private func triggerTraceroute() {
        let now = Date()
        if let last = lastTracerouteDate, now.timeIntervalSince(last) < tracerouteDebounce { return }
        lastTracerouteDate = now

        guard let host = settings.pingTargets.first?.host else { return }
        let db        = sqliteStore
        let sessionID = metricStore.currentSessionID
        // Snapshot the current average RTT/loss across all monitored targets for context
        let pings     = metricStore.latestPing.values
        let trigRTT: Double?  = pings.compactMap(\.rtt).isEmpty ? nil
                              : pings.compactMap(\.rtt).reduce(0, +) / Double(pings.compactMap(\.rtt).count)
        let trigLoss: Double? = pings.isEmpty ? nil
                              : pings.map(\.lossPercent).reduce(0, +) / Double(pings.count)

        Task.detached(priority: .utility) {
            guard let result = await TracerouteRunner.run(host: host) else { return }
            db.insertTracerouteEvent(sessionID: sessionID,
                                     timestamp: Date(),
                                     targetHost: host,
                                     output: result.output,
                                     hopCount: result.hopCount,
                                     triggerRTTMs: trigRTT,
                                     triggerLossPct: trigLoss)
        }
    }

    // MARK: - Bandwidth scheduling

    private func rescheduleBandwidthTimer(hours: Double) {
        bandwidthScheduleTimer?.invalidate()
        bandwidthScheduleTimer = nil
        guard hours > 0 else { return }
        let interval = hours * 3600
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .idle = self.speedtestRunner.state {
                    self.speedtestRunner.run()
                }
            }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        bandwidthScheduleTimer = t
    }
}
