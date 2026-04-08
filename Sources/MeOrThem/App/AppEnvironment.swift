import Foundation
import Combine

@MainActor
final class AppEnvironment {
    let settings:          AppSettings
    let metricStore:       MetricStore
    let monitoringEngine:  MonitoringEngine
    let alertManager:      AlertManager
    let speedtestRunner:   SpeedtestRunner
    let exportCoordinator: ExportCoordinator
    let logExporter:       LogExporter

    private var cancellables = Set<AnyCancellable>()
    private var bandwidthScheduleTimer: Timer?
    private var lastBandwidthScheduleHours: Double = 0

    init() {
        settings          = AppSettings.shared
        metricStore       = MetricStore(settings: settings)
        alertManager      = AlertManager()
        speedtestRunner   = SpeedtestRunner()
        monitoringEngine  = MonitoringEngine(settings: settings, metricStore: metricStore)
        exportCoordinator = ExportCoordinator(metricStore: metricStore, settings: settings)
        logExporter       = LogExporter(metricStore: metricStore, settings: settings)

        // Wire status changes → notification alerts
        metricStore.$overallStatus
            .dropFirst()
            .sink { [weak self] status in
                self?.alertManager.handleStatusChange(status)
            }
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

        // Pause/resume monitoring during bandwidth tests
        speedtestRunner.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .running:
                    self.monitoringEngine.pause()
                case .completed, .failed, .idle, .unavailable:
                    if self.monitoringEngine.isPaused {
                        self.monitoringEngine.resume()
                    }
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

        // Log rotation scheduling (daily check)
        if settings.enableLogRotation {
            logExporter.scheduleDaily()
        }
        settings.$enableLogRotation
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled {
                    self?.logExporter.scheduleDaily()
                } else {
                    self?.logExporter.cancelSchedule()
                }
            }
            .store(in: &cancellables)
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
