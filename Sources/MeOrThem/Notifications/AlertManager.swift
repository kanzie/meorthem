import Foundation
import UserNotifications
import MeOrThemCore

@MainActor
final class AlertManager {
    private var previousStatus: MetricStatus = .green
    private var lastFiredAt: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 60
    private let settings: AppSettings

    /// Timestamp when the connection first left the green state — used to compute outage duration.
    private var degradedSince: Date? = nil

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

    /// Call on every status change. Pass the current fault type so the notification body
    /// can attribute the issue (local router vs ISP) rather than showing a generic message.
    func handleStatusChange(_ newStatus: MetricStatus, faultType: NetworkFaultType = .none) {
        defer { previousStatus = newStatus }

        guard settings.enableNotificationBanner else {
            // Still track degraded-since so recovery duration is correct if setting is toggled.
            if newStatus > .green && degradedSince == nil { degradedSince = Date() }
            if newStatus == .green { degradedSince = nil }
            return
        }

        let now = Date()

        if newStatus == .green && previousStatus > .green {
            // Recovery: connection returned to green.
            let duration = degradedSince.map { now.timeIntervalSince($0) }
            degradedSince = nil
            fireRecovery(duration: duration)
            return
        }

        if newStatus > previousStatus {
            // Degradation: green→yellow or yellow→red.
            if degradedSince == nil { degradedSince = now }
            guard now.timeIntervalSince(lastFiredAt) >= cooldownSeconds else { return }
            lastFiredAt = now
            fireDegraded(status: newStatus, faultType: faultType)
        }
    }

    private func fireDegraded(status: MetricStatus, faultType: NetworkFaultType) {
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Connection \(status.label)"

        var body = status == .red
            ? "Your connection is poor. Video calls may be affected."
            : "Your connection quality has degraded."

        if faultType != .none {
            body += " \(faultType.displayLabel)."
        }
        content.body = body
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound { content.sound = .default }

        deliver(content, id: "com.meorthem.status.\(UUID().uuidString)")
    }

    private func fireRecovery(duration: TimeInterval?) {
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Connection Restored"
        if let d = duration, d >= 60 {
            let mins = Int(d / 60)
            let secs = Int(d) % 60
            content.body = "Your connection is back to normal after \(mins)m \(secs)s."
        } else if let d = duration {
            content.body = "Your connection is back to normal after \(Int(d))s."
        } else {
            content.body = "Your connection is back to normal."
        }
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound { content.sound = .default }

        deliver(content, id: "com.meorthem.recovery.\(UUID().uuidString)")
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Fires when a captive portal is detected on a newly-opened network session.
    func fireCaptivePortalDetected() {
        guard settings.enableNotificationBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Captive Portal Detected"
        content.body  = "This network requires a login before internet access is available. Open a browser to complete sign-in."
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound { content.sound = .default }
        deliver(content, id: "com.meorthem.captiveportal.\(UUID().uuidString)")
    }

    /// Fires when ICMP throttling is auto-detected and stealth (TCP) mode is activated.
    func fireStealthModeDetected() {
        guard settings.enableNotificationBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "Me Or Them — Stealth Mode Activated"
        content.body  = "ICMP pings appear to be blocked on this network. Switched to TCP probing."
        content.categoryIdentifier = Self.categoryID
        if settings.enableNotificationSound { content.sound = .default }
        deliver(content, id: "com.meorthem.stealth.\(UUID().uuidString)")
    }
}
