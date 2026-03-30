import AppKit

/// Stateless utility that rebuilds an NSMenu from current AppEnvironment state.
/// Called in NSMenuDelegate.menuWillOpen — runs synchronously, O(targets) cost.
enum MenuBuilder {

    struct Actions {
        let showAbout:     () -> Void
        let openSettings:  () -> Void
        let copyReport:    () -> Void
        let runSpeedtest:  () -> Void
        let quit:          () -> Void
    }

    // Tags for items updated during live refresh
    static let tagLatency    = 1
    static let tagPacketLoss = 2
    static let tagJitter     = 3
    static let tagCountdown  = 4
    static let tagTargetBase = 100   // tagTargetBase + index per target

    @MainActor
    static func rebuild(_ menu: NSMenu, environment env: AppEnvironment, actions: Actions) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let settings  = env.settings
        let store     = env.metricStore
        let targets   = settings.pingTargets
        let threshold = settings.thresholds

        // MARK: - Overall summary
        let avgLoss = targets.compactMap { store.latestPing[$0.id]?.lossPercent }
                             .reduce(0, +) / Double(max(targets.count, 1))

        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))
        let latencyItem = staticItem(latencyString(targets: targets, store: store,
                                                   threshold: threshold,
                                                   pollSecs: settings.pollIntervalSecs,
                                                   countdown: remaining))
        latencyItem.tag = tagLatency
        menu.addItem(latencyItem)

        let lossItem = staticItem(String(format: "Packet Loss: %.1f%%", avgLoss))
        lossItem.tag = tagPacketLoss
        menu.addItem(lossItem)

        let jitterValues = targets.compactMap { store.latestPing[$0.id]?.jitter }
        let avgJitter = jitterValues.reduce(0.0, +) / Double(max(jitterValues.count, 1))
        let jitterItem = staticItem(jitterValues.isEmpty
            ? "Jitter: —"
            : String(format: "Jitter: %.1fms avg", avgJitter))
        jitterItem.tag = tagJitter
        menu.addItem(jitterItem)

        menu.addItem(.separator())

        // MARK: - Per-target rows
        for (i, target) in targets.enumerated() {
            let result = store.latestPing[target.id]
            let status = MetricStatus.forPingResult(result, thresholds: threshold)
            let item = TargetMenuItemView.menuItem(target: target, result: result, status: status)
            item.tag = tagTargetBase + i
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // MARK: - Network Details submenu
        menu.addItem(networkDetailsSubmenu(store: store))
        menu.addItem(.separator())

        // MARK: - Actions
        menu.addItem(actionItem("Ping Stats Report", action: actions.copyReport))

        let speedItem = actionItem(speedtestLabel(env.speedtestRunner), action: actions.runSpeedtest)
        speedItem.isEnabled = !isSpeedtestRunning(env.speedtestRunner)
        menu.addItem(speedItem)

        menu.addItem(staticItem(env.speedtestRunner.lastCheckedText,  color: .secondaryLabelColor))
        menu.addItem(staticItem(env.speedtestRunner.summaryText,      color: .secondaryLabelColor))

        menu.addItem(.separator())

        // MARK: - Misc
        menu.addItem(actionItem("Settings…", action: actions.openSettings))
        menu.addItem(actionItem("About Me Or Them", action: actions.showAbout))

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", action: actions.quit))
    }

    // MARK: - Live refresh (called while menu is open)

    @MainActor
    static func refreshLiveItems(_ menu: NSMenu, environment env: AppEnvironment) {
        let settings  = env.settings
        let store     = env.metricStore
        let targets   = settings.pingTargets
        let threshold = settings.thresholds

        let avgLoss = targets.compactMap { store.latestPing[$0.id]?.lossPercent }
                             .reduce(0, +) / Double(max(targets.count, 1))

        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))

        if let item = menu.item(withTag: tagLatency) {
            item.attributedTitle = NSAttributedString(
                string: latencyString(targets: targets, store: store,
                                      threshold: threshold,
                                      pollSecs: settings.pollIntervalSecs,
                                      countdown: remaining),
                attributes: _labelAttrs)
        }
        if let item = menu.item(withTag: tagPacketLoss) {
            item.attributedTitle = NSAttributedString(
                string: String(format: "Packet Loss: %.1f%%", avgLoss),
                attributes: _labelAttrs)
        }

        let jitterValues = targets.compactMap { store.latestPing[$0.id]?.jitter }
        let avgJitter = jitterValues.reduce(0.0, +) / Double(max(jitterValues.count, 1))
        if let item = menu.item(withTag: tagJitter) {
            item.attributedTitle = NSAttributedString(
                string: jitterValues.isEmpty
                    ? "Jitter: —"
                    : String(format: "Jitter: %.1fms avg", avgJitter),
                attributes: _labelAttrs)
        }

        for (i, target) in targets.enumerated() {
            guard let item = menu.item(withTag: tagTargetBase + i) else { continue }
            let result = store.latestPing[target.id]
            let status = MetricStatus.forPingResult(result, thresholds: threshold)
            (item.view as? TargetMenuItemView)?.update(result: result, status: status)
        }
    }

    @MainActor
    static func refreshCountdown(_ menu: NSMenu, environment env: AppEnvironment) {
        guard let item = menu.item(withTag: tagLatency) else { return }
        let settings  = env.settings
        let store     = env.metricStore
        let targets   = settings.pingTargets
        let threshold = settings.thresholds
        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))
        item.attributedTitle = NSAttributedString(
            string: latencyString(targets: targets, store: store, threshold: threshold,
                                  pollSecs: settings.pollIntervalSecs, countdown: remaining),
            attributes: _labelAttrs)
    }

    // MARK: - Network Details submenu

    @MainActor
    private static func networkDetailsSubmenu(store: MetricStore) -> NSMenuItem {
        let parent = NSMenuItem(title: "Network Details", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Network Details")

        if let w = store.latestWifi ?? WiFiMonitor.snapshot() {
            // WiFi connection
            sub.addItem(staticItem("WiFi — \(w.ssid)"))
            sub.addItem(.separator())
            if let ip = w.ipAddress   { sub.addItem(staticItem("IP Address:  \(ip)")) }
            if let gw = w.routerIP    { sub.addItem(staticItem("Router:      \(gw)")) }
            sub.addItem(staticItem("MAC Address: \(w.macAddress)"))
            sub.addItem(staticItem("Channel:     \(w.channelDescription)"))
            sub.addItem(staticItem("RSSI:        \(w.rssi) dBm (\(w.rssiQuality))"))
            sub.addItem(staticItem("Noise:       \(w.noise) dBm"))
            sub.addItem(staticItem(String(format: "Tx Rate:     %.3f Mbps", w.txRateMbps)))
            sub.addItem(staticItem("PHY Mode:    \(w.phyMode)"))
        } else {
            // Ethernet or no network
            let wifiIfaceName = WiFiMonitor.interfaceName()
            if let eth = NetworkInfo.ethernetInfo(excluding: wifiIfaceName) {
                sub.addItem(staticItem("Ethernet — \(eth.interface)"))
                sub.addItem(.separator())
                sub.addItem(staticItem("IP Address:  \(eth.ip)"))
                if let gw = NetworkInfo.defaultGateway() {
                    sub.addItem(staticItem("Router:      \(gw)"))
                }
                sub.addItem(staticItem("MAC Address: \(eth.mac)"))
            } else {
                sub.addItem(staticItem("No network connection"))
            }
        }

        parent.submenu = sub
        return parent
    }

    // MARK: - Helpers

    @MainActor
    private static func latencyString(targets: [PingTarget], store: MetricStore,
                                      threshold: Thresholds, pollSecs: Double,
                                      countdown: Int? = nil) -> String {
        let rtts = targets.compactMap { store.latestPing[$0.id]?.rtt }
        let intervalStr = pollSecs.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(pollSecs))s" : String(format: "%.1fs", pollSecs)
        let countdownSuffix: String
        if let cd = countdown, cd > 0 {
            countdownSuffix = " (\(cd)s)"
        } else {
            countdownSuffix = ""
        }
        guard !rtts.isEmpty else { return "Latency: — · \(intervalStr)\(countdownSuffix)" }
        let avg = rtts.reduce(0, +) / Double(rtts.count)
        let quality = avg < threshold.latencyYellowMs ? "Excellent" :
                      avg < threshold.latencyRedMs    ? "Fair" : "Poor"
        return String(format: "Latency: %.1fms (%@) · %@%@", avg, quality, intervalStr, countdownSuffix)
    }

    nonisolated(unsafe) private static let _menuFont = NSFont.menuFont(ofSize: 13)
    nonisolated(unsafe) private static let _labelAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.menuFont(ofSize: 13)
    ]

    @MainActor
    private static func staticItem(_ title: String, color: NSColor = .labelColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color,
                         .font: _menuFont]
        )
        return item
    }

    @MainActor
    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.noop), keyEquivalent: "")
        item.isEnabled = true
        item.target = ActionTarget.shared
        ActionTarget.shared.register(item, action: action)
        return item
    }

    @MainActor
    private static func speedtestLabel(_ runner: SpeedtestRunner) -> String {
        if case .running = runner.state { return "Running Bandwidth Test…" }
        return "Check Bandwidth…"
    }

    @MainActor
    private static func isSpeedtestRunning(_ runner: SpeedtestRunner) -> Bool {
        if case .running = runner.state { return true }
        return false
    }
}

// MARK: - ActionTarget: bridges closures to @objc targets
/// NSMenuItem.target must be an NSObject. This singleton maps items → closures.
@MainActor
final class ActionTarget: NSObject {
    static let shared = ActionTarget()
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func register(_ item: NSMenuItem, action: @escaping () -> Void) {
        item.target = self
        item.action = #selector(handleAction(_:))
        actions[ObjectIdentifier(item)] = action
    }

    @objc func handleAction(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }

    func clear() {
        actions.removeAll()
    }
}
