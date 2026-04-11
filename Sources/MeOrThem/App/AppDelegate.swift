import AppKit
import Combine
import MeOrThemCore   // for AppearanceObserver

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var environment: AppEnvironment!
    private var settingsController:     SettingsWindowController?
    private var pingReportController:   PingReportWindowController?
    private var chartsWindowController: MetricsChartsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var menuLiveUpdate: AnyCancellable?
    private var menuWifiUpdate: AnyCancellable?
    private var menuSpeedtestUpdate: AnyCancellable?
    private var menuHistoryUpdate: AnyCancellable?
    private var countdownTimer: Timer?
    private var chartsWindowObserver: NSObjectProtocol?
    private var isPulsing = false
    private var hasInitialData = false
    private var loadingBlinkTimer: Timer?
    private var loadingDotVisible = false

    /// Last known download speed from completed bandwidth test (persisted across restarts).
    private var lastDownloadMbps: Double? = {
        let v = UserDefaults.standard.double(forKey: "bandwidthLastDownloadMbps")
        return v > 0 ? v : nil
    }()

    /// Whether a bandwidth test is currently running (drives bar blink animation).
    private var bandwidthTestRunning = false
    private var bandwidthBlinkTimer: Timer?
    private var bandwidthBlinkVisible = false

    /// Last image pointer set on the status bar button. Used to skip redundant
    /// `button.image` assignments when the icon state hasn't changed — each
    /// assignment unconditionally triggers an IPC round-trip to SystemUIServer.
    private var _lastSetImage: NSImage?
    /// Last title string set on the status bar button. Skips NSButton layout work
    /// when the latency text rounds to the same value between consecutive ticks.
    private var _lastSetTitle: String = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Detect first install before AppSettings initialises (sets launchAtLogin = true)
        let isFirstLaunch = UserDefaults.standard.object(forKey: "launchAtLogin") == nil

        environment = AppEnvironment()
        setupStatusItem()
        observeStatusChanges()
        observeAppearance()
        observeBandwidth()
        environment.alertManager.requestPermission()
        environment.monitoringEngine.start()
        UpdateChecker.shared.startPeriodicChecks()

        // Register launch-at-login on first install (silently — matches user expectation)
        if isFirstLaunch {
            try? LaunchAtLoginHelper.set(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.monitoringEngine.stop()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(status: .green)
        startLoadingBlink()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startLoadingBlink() {
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasInitialData else { return }
                self.loadingDotVisible.toggle()
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        loadingBlinkTimer = t
    }

    private func stopLoadingBlink() {
        loadingBlinkTimer?.invalidate()
        loadingBlinkTimer = nil
        loadingDotVisible = false
    }

    private func observeStatusChanges() {
        // Fix: also watch latestPing so we detect initial data even when overallStatus stays green.
        environment.metricStore.$latestPing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestPing in
                guard let self else { return }
                if !self.hasInitialData {
                    let targets = self.environment.settings.pingTargets
                    if targets.allSatisfy({ latestPing[$0.id] != nil }) {
                        self.hasInitialData = true
                        self.stopLoadingBlink()
                        self.updateIcon(status: self.environment.metricStore.overallStatus)
                    }
                }
                // Only refresh the latency text — the icon image is driven by $overallStatus
                // and tickStarted. Calling full updateIcon() here causes N+1 CoreGraphics
                // renders and IPC round-trips to SystemUIServer per tick (once per target +
                // gateway), most of which produce the same image. Use the cheap title-only path.
                if self.environment.settings.showLatencyInMenubar {
                    self.updateLatencyTitle()
                }
            }
            .store(in: &cancellables)

        environment.metricStore.$overallStatus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.updateIcon(status: status)
            }
            .store(in: &cancellables)

        environment.settings.$alwaysShowBarChart
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)

        environment.settings.$showLatencyInMenubar
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)

        environment.settings.$bandwidthScheduleHours
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)

        environment.monitoringEngine.tickStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.isPulsing = true
                self.updateIcon(status: self.environment.metricStore.overallStatus)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    self.isPulsing = false
                    self.updateIcon(status: self.environment.metricStore.overallStatus)
                }
            }
            .store(in: &cancellables)
    }

    private func observeAppearance() {
        AppearanceObserver.shared.appearanceChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                StatusBarIconRenderer.invalidateCache()
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)
    }

    private func observeBandwidth() {
        environment.speedtestRunner.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .running:
                    self.bandwidthTestRunning = true
                    self.startBandwidthBlink()
                case .completed(let result):
                    self.lastDownloadMbps = result.downloadMbps
                    UserDefaults.standard.set(result.downloadMbps, forKey: "bandwidthLastDownloadMbps")
                    self.bandwidthTestRunning = false
                    self.stopBandwidthBlink()
                case .idle, .failed, .unavailable:
                    self.bandwidthTestRunning = false
                    self.stopBandwidthBlink()
                }
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)
    }

    private func startBandwidthBlink() {
        guard bandwidthBlinkTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.bandwidthTestRunning else { return }
                self.bandwidthBlinkVisible.toggle()
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        bandwidthBlinkTimer = t
    }

    private func stopBandwidthBlink() {
        bandwidthBlinkTimer?.invalidate()
        bandwidthBlinkTimer = nil
        bandwidthBlinkVisible = false
    }

    private func updateIcon(status: MetricStatus) {
        let showBar        = environment.settings.alwaysShowBarChart
        let recentStatuses = environment.metricStore.recentOverallStatuses(last: 5)
        let settings       = environment.settings
        let paused         = environment.monitoringEngine.isManuallyPaused

        // Bar is shown only when auto-bandwidth polling is configured.
        let showBandwidthBar = settings.bandwidthScheduleHours > 0

        // During startup the bar blinks in sync with the loading circle; after that it
        // uses its own blink timer while the speedtest is running.
        let barRunning     = bandwidthTestRunning || (!hasInitialData && showBandwidthBar)
        let barBlinkPhase  = hasInitialData ? bandwidthBlinkVisible : loadingDotVisible

        let image = StatusBarIconRenderer.render(
            status:                  status,
            targetStatuses:          recentStatuses,
            showBarChart:            showBar,
            pulse:                   hasInitialData ? isPulsing : loadingDotVisible,
            isLoading:               !hasInitialData,
            isPaused:                paused,
            bandwidthMbps:           lastDownloadMbps,
            showBandwidthBar:        showBandwidthBar,
            bandwidthBarRunning:     barRunning,
            bandwidthBarBlinkVisible: barBlinkPhase,
            bandwidthBarRedMbps:     settings.bandwidthBarRedMbps,
            bandwidthBarYellowMbps:  settings.bandwidthBarYellowMbps
        )
        // Guard: StatusBarIconRenderer caches images by state key and returns the same
        // NSImage pointer for identical visual state. Only push to AppKit when the pointer
        // differs — each assignment triggers an IPC round-trip to SystemUIServer even when
        // the icon is visually unchanged.
        if image !== _lastSetImage {
            _lastSetImage = image
            statusItem.button?.image = image
        }

        updateLatencyTitle()

        statusItem.button?.toolTip = "Me Or Them — \(status.label)"
    }

    /// Updates only the status bar button title (latency text). Called from the
    /// $latestPing subscriber so the text stays current every tick without triggering
    /// a full icon re-render or SystemUIServer IPC for the image.
    private func updateLatencyTitle() {
        let settings = environment.settings
        let newTitle: String
        if settings.showLatencyInMenubar && hasInitialData {
            if environment.monitoringEngine.isPaused {
                newTitle = " —"
            } else {
                let targets = settings.pingTargets
                let store   = environment.metricStore
                let rtts    = targets.compactMap { store.latestPing[$0.id]?.rtt }
                if !rtts.isEmpty {
                    let avg = rtts.reduce(0, +) / Double(rtts.count)
                    newTitle = String(format: " %.0fms", avg)
                } else {
                    newTitle = ""
                }
            }
        } else {
            newTitle = ""
        }
        // Guard: skip NSButton layout work when the text hasn't changed.
        if newTitle != _lastSetTitle {
            _lastSetTitle = newTitle
            statusItem.button?.title = newTitle
        }
    }

    // MARK: - NSMenuDelegate

    private func makeMenuActions() -> MenuBuilder.Actions {
        MenuBuilder.Actions(
            showAbout:          { AboutWindowController.shared.showAndFocus() },
            openSettings:       { [weak self] in self?.showSettings() },
            copyReport:         { [weak self] in self?.showPingReport() },
            showNetworkHistory: { [weak self] in self?.showNetworkHistory() },
            runSpeedtest:       { [weak self] in self?.environment.speedtestRunner.run() },
            showHelp:           { HelpWindowController.shared.showAndFocus() },
            togglePause:        { [weak self] in self?.toggleManualPause() },
            quit:               { NSApp.terminate(nil) }
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        ActionTarget.shared.clear()
        MenuBuilder.rebuild(menu, environment: environment, actions: makeMenuActions())

        menuLiveUpdate = environment.metricStore.$latestPing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        menuWifiUpdate = environment.metricStore.$latestWifi
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshNetworkDetails(menu, environment: self.environment)
            }

        menuSpeedtestUpdate = environment.speedtestRunner.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshSpeedtestItems(menu, runner: self.environment.speedtestRunner,
                                                  environment: self.environment)
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        menuHistoryUpdate = environment.metricStore.$connectionHistory
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] (_: [ConnectionEvent]) in
                guard let self, let menu else { return }
                MenuBuilder.refreshPreviousDisturbances(menu,
                    store: self.environment.metricStore,
                    clearHistory: { self.environment.metricStore.clearConnectionHistory() })
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        let ct = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let menu = self.statusItem.menu else { return }
                MenuBuilder.refreshCountdown(menu, environment: self.environment)
            }
        }
        ct.tolerance = 0.1
        RunLoop.main.add(ct, forMode: .common)
        countdownTimer = ct
    }

    func menuDidClose(_ menu: NSMenu) {
        menuLiveUpdate       = nil
        menuWifiUpdate       = nil
        menuSpeedtestUpdate  = nil
        menuHistoryUpdate    = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - Actions

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: environment.settings)
        }
        settingsController?.showAndFocus()
    }

    private func showPingReport() {
        if pingReportController == nil {
            pingReportController = PingReportWindowController(
                store: environment.metricStore,
                settings: environment.settings,
                exporter: environment.exportCoordinator,
                onShowCharts: { [weak self] in self?.showNetworkHistory() }
            )
        }
        pingReportController?.showAndFocus()
    }

    private func showNetworkHistory() {
        if chartsWindowController == nil {
            chartsWindowController = MetricsChartsWindowController(
                db:         environment.sqliteStore,
                targets:    environment.settings.pingTargets,
                thresholds: environment.settings.thresholds
            )
            // Release on close so the SwiftUI hosting controller doesn't linger in the compositor.
            // The token must be stored — discarding it causes ARC to remove the observer
            // immediately, so the close notification would never fire.
            if let win = chartsWindowController?.window {
                chartsWindowObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: win, queue: .main
                ) { [weak self] _ in
                    self?.chartsWindowController = nil
                    self?.chartsWindowObserver = nil
                }
            }
        }
        chartsWindowController?.showAndFocus()
    }

    private func toggleManualPause() {
        if environment.monitoringEngine.isManuallyPaused {
            environment.monitoringEngine.manualResume()
        } else {
            environment.monitoringEngine.manualPause()
        }
        // Rebuild menu to update pause item label
        if let menu = statusItem.menu {
            ActionTarget.shared.clear()
            MenuBuilder.rebuild(menu, environment: environment, actions: makeMenuActions())
        }
        updateIcon(status: environment.metricStore.overallStatus)
    }

    // MARK: - Dummy @objc selector required by NSMenuItem
    @objc func noop() {}
}
