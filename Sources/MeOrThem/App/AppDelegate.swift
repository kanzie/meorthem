import AppKit
import Combine
import MeOrThemCore   // for AppearanceObserver

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var environment: AppEnvironment!
    private var settingsController: SettingsWindowController?
    private var pingReportController: PingReportWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var menuLiveUpdate: AnyCancellable?
    private var menuWifiUpdate: AnyCancellable?
    private var menuSpeedtestUpdate: AnyCancellable?
    private var countdownTimer: Timer?
    private var isPulsing = false
    private var hasInitialData = false
    private var loadingBlinkTimer: Timer?
    private var loadingDotVisible = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment = AppEnvironment()
        setupStatusItem()
        observeStatusChanges()
        observeAppearance()
        environment.alertManager.requestPermission()
        environment.monitoringEngine.start()
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
        environment.metricStore.$overallStatus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if !self.hasInitialData {
                    let targets = self.environment.settings.pingTargets
                    let store   = self.environment.metricStore
                    if targets.allSatisfy({ store.latestPing[$0.id] != nil }) {
                        self.hasInitialData = true
                        self.stopLoadingBlink()
                    }
                }
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

        // Update menubar text when new ping data arrives
        environment.metricStore.$latestPing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.environment.settings.showLatencyInMenubar else { return }
                self.updateIcon(status: self.environment.metricStore.overallStatus)
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

    private func updateIcon(status: MetricStatus) {
        let showBar       = environment.settings.alwaysShowBarChart
        let recentStatuses = environment.metricStore.recentOverallStatuses(last: 5)
        let image = StatusBarIconRenderer.render(
            status: status,
            targetStatuses: recentStatuses,
            showBarChart: showBar,
            pulse: hasInitialData ? isPulsing : loadingDotVisible,
            isLoading: !hasInitialData
        )
        statusItem.button?.image = image

        // Menubar text mode: show average latency next to icon
        if environment.settings.showLatencyInMenubar && hasInitialData && !environment.monitoringEngine.isPaused {
            let targets = environment.settings.pingTargets
            let store   = environment.metricStore
            let rtts    = targets.compactMap { store.latestPing[$0.id]?.rtt }
            if !rtts.isEmpty {
                let avg = rtts.reduce(0, +) / Double(rtts.count)
                statusItem.button?.title = String(format: " %.0fms", avg)
            } else {
                statusItem.button?.title = ""
            }
        } else if environment.settings.showLatencyInMenubar && environment.monitoringEngine.isPaused {
            statusItem.button?.title = " —"
        } else {
            statusItem.button?.title = ""
        }

        statusItem.button?.toolTip = "Me Or Them — \(status.label)"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        ActionTarget.shared.clear()

        MenuBuilder.rebuild(menu, environment: environment, actions: MenuBuilder.Actions(
            showAbout:    { AboutWindowController.shared.showAndFocus() },
            openSettings: { [weak self] in self?.showSettings() },
            copyReport:   { [weak self] in self?.showPingReport() },
            runSpeedtest: { [weak self] in self?.environment.speedtestRunner.run() },
            showHelp:     { HelpWindowController.shared.showAndFocus() },
            quit:         { NSApp.terminate(nil) }
        ))

        // Refresh live items when new ping data arrives
        menuLiveUpdate = environment.metricStore.$latestPing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        // Refresh network details when WiFi state changes or paused state changes
        menuWifiUpdate = environment.metricStore.$latestWifi
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshNetworkDetails(menu, environment: self.environment)
            }

        // Refresh speedtest section when state changes (covers both running → completed and idle)
        menuSpeedtestUpdate = environment.speedtestRunner.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshSpeedtestItems(menu, runner: self.environment.speedtestRunner,
                                                  environment: self.environment)
                // Also refresh live items to show/hide Paused state
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        // 1-second timer: countdown + refresh network details for real-time TX rate
        let ct = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let menu = self.statusItem.menu else { return }
                MenuBuilder.refreshCountdown(menu, environment: self.environment)
                MenuBuilder.refreshNetworkDetails(menu, environment: self.environment)
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
                exporter: environment.exportCoordinator
            )
        }
        pingReportController?.showAndFocus()
    }

    // MARK: - Dummy @objc selector required by NSMenuItem
    @objc func noop() {}
}
