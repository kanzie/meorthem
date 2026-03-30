import AppKit
import Combine
import MeOrThemCore   // for AppearanceObserver (Bug 15: removed duplicate from MeOrThem/Utilities)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var environment: AppEnvironment!
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

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

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func observeStatusChanges() {
        environment.metricStore.$overallStatus
            .removeDuplicates()                     // skip redundant icon redraws
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateIcon(status: status)
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
        let targetStatuses = environment.settings.pingTargets.map {
            environment.metricStore.status(for: $0.id)
        }
        let showBar = environment.settings.alwaysShowBarChart
        let image = StatusBarIconRenderer.render(
            status: status,
            targetStatuses: targetStatuses,
            showBarChart: showBar
        )
        statusItem.button?.image = image
        statusItem.button?.toolTip = "MeOrThem — \(status.label)"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Clear previous action registrations to avoid leaking closures
        ActionTarget.shared.clear()

        MenuBuilder.rebuild(menu, environment: environment, actions: MenuBuilder.Actions(
            showAbout:    { AboutWindowController.shared.showAndFocus() },
            openSettings: { [weak self] in self?.showSettings() },
            copyReport:   { [weak self] in self?.copyReport() },
            runSpeedtest: { [weak self] in self?.environment.speedtestRunner.run() },
            exportCSV:    { [weak self] in self?.environment.exportCoordinator.exportCSV() },
            exportPDF:    { [weak self] in self?.environment.exportCoordinator.exportPDF() },
            quit:         { NSApp.terminate(nil) }
        ))
    }

    // MARK: - Actions

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: environment.settings)
        }
        settingsController?.showAndFocus()
    }

    private func copyReport() {
        let text = environment.metricStore.summaryText(targets: environment.settings.pingTargets)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Dummy @objc selector required by NSMenuItem
    @objc func noop() {}
}
