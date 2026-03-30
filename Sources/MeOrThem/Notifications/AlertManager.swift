import Foundation
import UserNotifications

@MainActor
final class AlertManager {
    private var previousStatus: MetricStatus = .green
    private var lastFiredAt: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 60

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handleStatusChange(_ newStatus: MetricStatus) {
        defer { previousStatus = newStatus }

        // Only notify on degradation (green→yellow or yellow→red)
        guard newStatus > previousStatus else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= cooldownSeconds else { return }
        lastFiredAt = now

        fire(status: newStatus)
    }

    private func fire(status: MetricStatus) {
        let content = UNMutableNotificationContent()
        content.title = "MeOrThem — Connection \(status.label)"
        content.body  = status == .red
            ? "Your connection is poor. Video calls may be affected."
            : "Your connection quality has degraded."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.meorthem.status.\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
