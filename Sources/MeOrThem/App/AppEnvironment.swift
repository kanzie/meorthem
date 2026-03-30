import Foundation
import Combine

@MainActor
final class AppEnvironment {
    let settings:         AppSettings
    let metricStore:      MetricStore
    let monitoringEngine: MonitoringEngine
    let alertManager:     AlertManager
    let speedtestRunner:  SpeedtestRunner
    let exportCoordinator: ExportCoordinator

    private var cancellables = Set<AnyCancellable>()

    init() {
        settings          = AppSettings.shared
        metricStore       = MetricStore(settings: settings)
        alertManager      = AlertManager()
        speedtestRunner   = SpeedtestRunner()
        monitoringEngine  = MonitoringEngine(settings: settings, metricStore: metricStore)
        exportCoordinator = ExportCoordinator(metricStore: metricStore, settings: settings)

        // Wire status changes → notification alerts
        metricStore.$overallStatus
            .dropFirst()
            .sink { [weak self] status in
                self?.alertManager.handleStatusChange(status)
            }
            .store(in: &cancellables)

        // Restart monitoring engine when poll interval changes
        settings.$pollIntervalSecs
            .dropFirst()
            .sink { [weak self] _ in
                self?.monitoringEngine.restart()
            }
            .store(in: &cancellables)

        // React to OS WiFi events immediately (RSSI, SSID, link changes)
        WiFiObserver.shared.wifiChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.metricStore.recordWiFi(snapshot)
            }
            .store(in: &cancellables)
    }
}
