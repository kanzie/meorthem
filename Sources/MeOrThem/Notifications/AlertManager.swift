import Foundation
import UserNotifications
import MeOrThemCore

@MainActor
final class AlertManager {
    private var previousStatus: MetricStatus = .green
    private var lastFiredAt: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 60
    private let settings: AppSettings

    static let categoryID       = "com.meorthem.degradation"
    static let actionViewCharts = "VIEW_CHARTS"

    init(settings: AppSettings) {
        self.settings = settings
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let action = UNNotificationAction(
            identifier: Self.actionViewCharts,
            title: "View Charts",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func handleStatusChange(_ newStatus: MetricStatus) {
        defer { previousStatus = newStatus }

        // Only notify on degradation (green→yellow or yellow→red)
        guard newStatus > previousStatus else { return }
        guard settings.enableNotificationBanner else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= cooldownSeconds else { return }
        lastFiredAt = now

        fire(status: newStatus)
    }

    private func fire(status: MetricStatus) {
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Connection \(status.label)"
        content.body  = status == .red
            ? "Your connection is poor. Video calls may be affected."
            : "Your connection quality has degraded."
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "com.meorthem.status.\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Fires when ICMP throttling is auto-detected and stealth (TCP) mode is activated.
    func fireStealthModeDetected() {
        guard settings.enableNotificationBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Stealth Mode Activated"
        content.body  = "ICMP pings appear to be blocked on this network. Switched to TCP probing."
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: "com.meorthem.stealth.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
