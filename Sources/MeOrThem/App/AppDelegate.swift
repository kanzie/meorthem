import AppKit
import Combine
import MeOrThemCore   // for AppearanceObserver (Bug 15: removed duplicate from MeOrThem/Utilities)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var environment: AppEnvironment!
    private var settingsController: SettingsWindowController?
    private var pingReportController: PingReportWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var menuLiveUpdate: AnyCancellable?
    private var menuWifiUpdate: AnyCancellable?
    private var countdownTimer: Timer?
    private var isPulsing = false
    private var hasInitialData = false

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
        updateIcon(status: .green)  // shows grey loading circle until data arrives

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func observeStatusChanges() {
        environment.metricStore.$overallStatus
            .removeDuplicates()                     // skip redundant icon redraws
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                // Mark initial data as received once all targets have results
                if !self.hasInitialData {
                    let targets = self.environment.settings.pingTargets
                    let store   = self.environment.metricStore
                    if targets.allSatisfy({ store.latestPing[$0.id] != nil }) {
                        self.hasInitialData = true
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
                self.updateIcon(status: self.environment.metricStore.overallStatus)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(status: MetricStatus) {
        let showBar = environment.settings.alwaysShowBarChart
        let recentStatuses = environment.metricStore.recentOverallStatuses(last: 5)
        let image = StatusBarIconRenderer.render(
            status: status,
            targetStatuses: recentStatuses,
            showBarChart: showBar,
            pulse: isPulsing,
            isLoading: !hasInitialData
        )
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Me Or Them — \(status.label)"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Clear previous action registrations to avoid leaking closures
        ActionTarget.shared.clear()

        MenuBuilder.rebuild(menu, environment: environment, actions: MenuBuilder.Actions(
            showAbout:    { AboutWindowController.shared.showAndFocus() },
            openSettings: { [weak self] in self?.showSettings() },
            copyReport:   { [weak self] in self?.showPingReport() },
            runSpeedtest: { [weak self] in self?.environment.speedtestRunner.run() },
            quit:         { NSApp.terminate(nil) }
        ))

        // Refresh live items every time new ping data arrives while the menu is open
        menuLiveUpdate = environment.metricStore.$latestPing
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshLiveItems(menu, environment: self.environment)
            }

        // Refresh Network Details when WiFi state changes while menu is open
        menuWifiUpdate = environment.metricStore.$latestWifi
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak menu] _ in
                guard let self, let menu else { return }
                MenuBuilder.refreshNetworkDetails(menu, environment: self.environment)
            }

        // 1-second countdown ticker
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
        menuLiveUpdate = nil
        menuWifiUpdate = nil
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
