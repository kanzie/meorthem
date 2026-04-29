import Foundation
import Combine
import AppKit
import IOKit.ps
import MeOrThemCore

@MainActor
final class AppEnvironment {
    /// Weak reference set by AppDelegate after init. Used by App Intents for status queries.
    static weak var shared: AppEnvironment?

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

    // Non-WiFi session guard: avoids spawning ARP/route subprocesses on every tick
    // when the gateway IP hasn't changed since the last non-WiFi session was established.
    private var lastNonWifiGatewayIP: String?

    // Debounce: holds a pending DispatchWorkItem that will open an Ethernet/VPN session
    // after a short delay. Cancelled immediately if WiFi is detected first, preventing
    // spurious Ethernet sessions from being created during the startup race where
    // latestGatewayIP arrives before the first WiFi snapshot.
    private var pendingNonWifiSession: DispatchWorkItem?

    // Traceroute rate-limiting: don't fire more than once per 5 minutes
    private var lastTracerouteDate: Date?
    private let tracerouteDebounce: TimeInterval = 300

    // Stealth mode detection state
    /// Consecutive polls where ALL external (non-gateway) targets have 100% loss.
    private var consecutiveTotalLossPolls: Int = 0
    /// Prevents concurrent TCP probe tasks when detection is already in-flight.
    private var stealthProbeInFlight: Bool = false
    /// Number of consecutive total-loss polls required before TCP probe fires.
    private let stealthDetectionThreshold: Int = 5

    // VPN monitoring state
    /// Tick counter used to re-sample the VPN interface approximately once per minute.
    private var vpnCheckTickCounter: Int = 0
    private let vpnCheckInterval: Int = 30  // ~1 min at 2s poll

    // Sleep/wake state
    /// Timestamp of the most recent system wake event. Used to tag post-wake incidents.
    private var lastWakeDate: Date? = nil

    // Battery monitoring state
    private var isOnBattery: Bool = false
    private var powerSourceObserver: CFRunLoopSource? = nil

    // Local metrics HTTP server
    private var metricsServer: MetricsHTTPServer?

    init() {
        settings          = AppSettings.shared
        sqliteStore       = SQLiteStore.makeDefault()
        metricStore       = MetricStore(settings: settings, sqliteStore: sqliteStore)
        alertManager      = AlertManager(settings: settings)
        speedtestRunner   = SpeedtestRunner()
        monitoringEngine  = MonitoringEngine(settings: settings, metricStore: metricStore)
        exportCoordinator = ExportCoordinator(metricStore: metricStore, settings: settings, sqliteStore: sqliteStore)
        logExporter       = LogExporter(settings: settings)

        // Wire status changes → notification alerts (pass fault type for richer notification body)
        metricStore.$overallStatus
            .dropFirst()
            .sink { [weak self] status in
                guard let self else { return }
                self.alertManager.handleStatusChange(status,
                                                     faultType: self.metricStore.networkFaultType)
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

        // Track network sessions: open a new session whenever the network fingerprint changes.
        // Reacts to both WiFi state changes and gateway IP changes so that Ethernet and VPN
        // users get sessions too. CombineLatest fires whenever either upstream updates;
        // the fingerprint equality check in applySessionKey() acts as the gate — only a real
        // network change (new gateway IP, subnet, MAC, or WiFi channel) opens a new session.
        Publishers.CombineLatest(metricStore.$latestWifi, metricStore.$latestGatewayIP)
            .sink { [weak self] wifi, gatewayIP in
                guard let self else { return }
                self.updateNetworkSession(wifi: wifi, gatewayIP: gatewayIP)
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

        // Stealth mode detection + periodic VPN re-check — runs after every tick.
        monitoringEngine.onTickCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateStealthMode()
                self?.periodicVPNCheck()
            }
        }

        // SQLite maintenance: aggregate + prune on launch, then every hour.
        runSQLiteMaintenance()
        let mt = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runSQLiteMaintenance() }
        }
        mt.tolerance = 300   // ±5 min jitter is fine for housekeeping
        RunLoop.main.add(mt, forMode: .common)
        maintenanceTimer = mt

        // Sleep/wake event recording — pauses monitoring on sleep, resumes on wake.
        // NSWorkspace notifications are delivered on the main thread.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSleep() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }

        // Battery power monitoring — adjust poll rate when on battery.
        isOnBattery = Self.readIsOnBattery()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let env = Unmanaged<AppEnvironment>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in env.handlePowerSourceChange() }
        }, ctx)?.takeRetainedValue() {
            powerSourceObserver = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        // Subscribe to batteryBehavior changes so the setting takes effect immediately.
        settings.$batteryBehavior
            .dropFirst()
            .sink { [weak self] _ in self?.applyBatteryBehavior() }
            .store(in: &cancellables)
        // Apply on launch (no-op when .normal or on AC).
        applyBatteryBehavior()

        // Local metrics endpoint — start if enabled, react to settings changes.
        if settings.metricsServerEnabled { startMetricsServer() }
        settings.$metricsServerEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.startMetricsServer() } else { self.metricsServer?.stop() }
            }
            .store(in: &cancellables)
        settings.$metricsServerPort
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.settings.metricsServerEnabled else { return }
                self.metricsServer?.stop()
                self.startMetricsServer()
            }
            .store(in: &cancellables)
    }

    // MARK: - Sleep / Wake handling

    private func handleSleep() {
        sqliteStore.insertSystemEvent(timestamp: Date(), eventType: "sleep")
        monitoringEngine.pause()
    }

    private func handleWake() {
        let now = Date()
        sqliteStore.insertSystemEvent(timestamp: now, eventType: "wake")
        lastWakeDate = now
        metricStore.lastWakeDate = now
        if monitoringEngine.isPaused { monitoringEngine.resume() }
    }

    // MARK: - Battery / Power source handling

    private static func readIsOnBattery() -> Bool {
        let info    = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return sources.contains { src in
            let desc = IOPSGetPowerSourceDescription(info, src)
                .takeUnretainedValue() as? [String: Any]
            return (desc?[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        }
    }

    @MainActor
    private func handlePowerSourceChange() {
        let nowOnBattery = Self.readIsOnBattery()
        guard nowOnBattery != isOnBattery else { return }
        isOnBattery = nowOnBattery
        applyBatteryBehavior()
    }

    @MainActor
    private func applyBatteryBehavior() {
        guard isOnBattery else {
            // Restore AC behaviour: resume if battery-paused, reset to configured interval.
            if monitoringEngine.isPaused && !monitoringEngine.isManuallyPaused {
                monitoringEngine.resume()
            }
            monitoringEngine.restart(interval: settings.pollIntervalSecs)
            return
        }
        switch settings.batteryBehavior {
        case .normal:  break   // no change
        case .reduced: monitoringEngine.restart(interval: settings.pollIntervalSecs * 2)
        case .paused:  monitoringEngine.pause()
        }
    }

    // MARK: - Local metrics server

    private func startMetricsServer() {
        let server = MetricsHTTPServer(metricStore: metricStore, settings: settings)
        try? server.start(port: settings.metricsServerPort)
        metricsServer = server
    }

    // MARK: - Network session tracking

    /// Derives the correct session key for the current network state and applies it.
    /// Handles WiFi, Ethernet, and VPN connection types.
    private func updateNetworkSession(wifi: WiFiSnapshot?, gatewayIP: String?) {
        if let wifi {
            // WiFi: fingerprint encodes gateway IP + channel + band + subnet.
            // Cancel any pending Ethernet/VPN session — WiFi always wins.
            pendingNonWifiSession?.cancel()
            pendingNonWifiSession = nil
            if let key = NetworkSessionKey.from(wifi: wifi) {
                applySessionKey(key)
            }
            return
        }

        guard let gatewayIP else { return }  // No connectivity — nothing to track.

        // Non-WiFi path: determine interface type via routing table.
        // Guard against spawning ARP/route subprocesses every tick when the gateway IP
        // is unchanged and a non-WiFi session is already established.
        guard gatewayIP != lastNonWifiGatewayIP ||
              currentSessionFingerprint?.hasPrefix("eth|") == false &&
              currentSessionFingerprint?.hasPrefix("vpn|") == false
        else {
            // Same gateway as last tick — keep last_seen current without re-probing.
            if let sid = metricStore.currentSessionID {
                sqliteStore.touchSession(id: sid)
            }
            return
        }
        lastNonWifiGatewayIP = gatewayIP

        // Debounce non-WiFi session creation by 3 s to absorb the startup race where
        // latestGatewayIP arrives before the first WiFi snapshot. If WiFi is detected
        // before the timer fires, the work item is cancelled (see WiFi branch above)
        // and no Ethernet/VPN session is ever written to the database.
        pendingNonWifiSession?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNonWifiSession = nil
            // Run ARP and routing lookups off the MainActor — cached (30 s TTL), but the
            // first call in a cache window can spawn a short subprocess.
            Task { [weak self] in
                guard let self else { return }
                let (ifaceName, gatewayMAC) = await Task.detached(priority: .utility) {
                    let iface = NetworkInfo.defaultGatewayInterface()
                    let mac   = NetworkInfo.gatewayMACAddress(for: gatewayIP)
                    return (iface, mac)
                }.value

                await MainActor.run {
                    let key: NetworkSessionKey
                    if let iface = ifaceName,
                       iface.hasPrefix("utun") || iface.hasPrefix("ppp") || iface.hasPrefix("tap") {
                        // VPN tunnel interface
                        let localIP = NetworkInfo.ipAddress(for: iface)
                        key = NetworkSessionKey.fromVPN(
                            gatewayIP: gatewayIP, localIP: localIP, interfaceName: iface)
                    } else {
                        // Ethernet or unrecognised interface type
                        let wifiIfaceName = WiFiMonitor.interfaceName()
                        let ethInfo = NetworkInfo.ethernetInfo(excluding: wifiIfaceName)
                        key = NetworkSessionKey.fromEthernet(
                            gatewayIP: gatewayIP, localIP: ethInfo?.ip, gatewayMAC: gatewayMAC)
                    }
                    self.applySessionKey(key)
                }
            }
        }
        pendingNonWifiSession = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Opens a new session or touches the existing one, depending on whether the
    /// fingerprint has changed since the last call.
    private func applySessionKey(_ key: NetworkSessionKey) {
        guard key.fingerprint != currentSessionFingerprint else {
            if let sid = metricStore.currentSessionID {
                sqliteStore.touchSession(id: sid)
            }
            return
        }
        let newID = UUID()
        currentSessionFingerprint    = key.fingerprint
        metricStore.currentSessionID = newID
        let vpnIface = NetworkInfo.activeVPNInterface()
        metricStore.recordVPNInterface(vpnIface)
        sqliteStore.openSession(id: newID,
                                fingerprint:     key.fingerprint,
                                displayName:     key.displayName,
                                connectionType:  key.connectionType.rawValue,
                                weakFingerprint: key.hasWeakFingerprint,
                                vpnInterface:    vpnIface)

        // Clear stale ISP name, portal state, and hijack suspicion immediately.
        metricStore.recordSessionISP(nil)
        metricStore.recordCaptivePortal(nil)
        metricStore.recordDNSHijackSuspicion(false)

        // Async ISP identification via DNS TXT lookup — non-blocking, best-effort.
        let ispDB = sqliteStore
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let gatewayIP = await MainActor.run { self.metricStore.latestGatewayIP }
            guard let ip = gatewayIP else { return }
            guard let ispName = await ASNLookup.resolve(ip: ip) else { return }
            await MainActor.run {
                self.metricStore.recordSessionISP(ispName)
                ispDB.updateSessionISP(id: newID, ispName: ispName)
            }
        }

        // Captive portal probe — one HTTP check per session open, zero steady-state cost.
        Task.detached(priority: .utility) { [weak self] in
            let detected = await CaptivePortalProber.probe()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.metricStore.recordCaptivePortal(detected)
                if detected == true {
                    self.alertManager.fireCaptivePortalDetected()
                }
            }
        }

        // Upsert connection profile and restore stealth mode from stored state.
        let fp = key.fingerprint
        let db = sqliteStore
        sqliteStore.upsertConnectionProfile(fingerprint: fp, displayName: key.displayName)
        Task.detached(priority: .utility) { [weak self] in
            let profile = db.connectionProfile(fingerprint: fp)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.monitoringEngine.stealthModeActive = profile?.stealthMode ?? false
                self.consecutiveTotalLossPolls = 0
                self.stealthProbeInFlight = false
            }
        }
        // Log non-WiFi interface details on session open (WiFi rows are logged per-tick
        // via appendWiFi; Ethernet/VPN sessions only need a snapshot at session creation).
        if key.connectionType != .wifi {
            let ifaceParts = key.fingerprint.split(separator: "|")
            let ifaceName  = key.connectionType == .vpn
                ? (ifaceParts.count >= 2 ? String(ifaceParts[1]) : key.displayName)
                : key.displayName
            logExporter.appendInterfaceSnapshot(
                interfaceName:  ifaceName,
                connectionType: key.connectionType.rawValue,
                localIP:        nil,
                gatewayIP:      metricStore.latestGatewayIP)
        }
        // Reset DNS resolver failure counts — a resolver unreachable on one network
        // may be fully functional on another.
        settings.resetDNSResolverFailureCounts()
    }

    // MARK: - VPN monitoring

    /// Called after every tick. Re-samples the active VPN interface approximately once per minute
    /// and updates MetricStore so the menu and analyzer always reflect the current VPN state.
    private func periodicVPNCheck() {
        vpnCheckTickCounter += 1
        guard vpnCheckTickCounter >= vpnCheckInterval else { return }
        vpnCheckTickCounter = 0
        let iface = NetworkInfo.activeVPNInterface()
        if iface != metricStore.vpnInterface {
            metricStore.recordVPNInterface(iface)
        }
    }

    // MARK: - Stealth mode detection

    /// Called after every monitoring tick. Detects ICMP throttling by checking for 5 consecutive
    /// polls with 100% loss on all external targets, then confirming TCP reachability.
    private func evaluateStealthMode() {
        let externalIDs = settings.pingTargets.map(\.id)
        guard !externalIDs.isEmpty else { return }

        let allTotalLoss = externalIDs.allSatisfy {
            metricStore.latestPing[$0]?.lossPercent == 100
        }

        if allTotalLoss {
            consecutiveTotalLossPolls += 1
        } else {
            consecutiveTotalLossPolls = 0
            // Pings are working — record ICMP last-ok timestamp.
            if let fp = currentSessionFingerprint {
                sqliteStore.updateICMPLastOk(fingerprint: fp)
            }
        }

        // When stealth mode is already active and pings recover, disable it.
        if monitoringEngine.stealthModeActive && !allTotalLoss {
            monitoringEngine.stealthModeActive = false
            if let fp = currentSessionFingerprint {
                sqliteStore.setStealthMode(false, probePort: nil, source: nil, fingerprint: fp)
            }
        }

        // Trigger TCP probe after threshold consecutive total-loss ticks.
        guard consecutiveTotalLossPolls == stealthDetectionThreshold,
              !stealthProbeInFlight,
              !monitoringEngine.stealthModeActive,
              let host = settings.pingTargets.first?.host,
              let fp = currentSessionFingerprint else { return }

        stealthProbeInFlight = true
        let db = sqliteStore

        Task.detached(priority: .utility) { [weak self] in
            let probeResult = await TCPProber.probeAny(host: host)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stealthProbeInFlight = false

                if let (_, port) = probeResult {
                    // TCP succeeded but ICMP failed → ICMP is being throttled.
                    self.monitoringEngine.stealthModeActive = true
                    db.setStealthMode(true, probePort: port, source: "auto", fingerprint: fp)
                    db.setICMPThrottled(true, fingerprint: fp)
                    self.alertManager.fireStealthModeDetected()
                }
                // If TCP also fails: genuine outage — don't enable stealth mode.
            }
        }
    }

    private func runSQLiteMaintenance() {
        sqliteStore.aggregateAndPrune(
            rawRetentionDays:       settings.rawRetentionDays,
            aggregateRetentionDays: settings.aggregateRetentionDays,
            incidentRetentionDays:  settings.incidentRetentionDays
        )
        updateAvailabilityStats()
    }

    private func updateAvailabilityStats() {
        let db    = sqliteStore
        let store = metricStore
        Task.detached(priority: .utility) {
            let now   = Date()
            let h24   = db.availabilityFraction(from: now.addingTimeInterval(-86_400), to: now)
            let d7    = db.availabilityFraction(from: now.addingTimeInterval(-7 * 86_400), to: now)
            let d30   = db.availabilityFraction(from: now.addingTimeInterval(-30 * 86_400), to: now)
            await MainActor.run { store.recordAvailability(h24: h24, d7: d7, d30: d30) }
        }
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
        let pings      = metricStore.latestPing.values
        let validRTTs  = pings.compactMap(\.rtt)
        let trigRTT: Double?  = validRTTs.isEmpty ? nil
                              : validRTTs.reduce(0, +) / Double(validRTTs.count)
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
                // Skip the test if we are inside the configured quiet window.
                // The timer continues running; the next tick will fire after another interval.
                guard !self.settings.isInBandwidthQuietHours() else { return }
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
