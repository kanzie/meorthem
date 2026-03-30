import AppKit

/// Stateless utility that rebuilds an NSMenu from current AppEnvironment state.
/// Called in NSMenuDelegate.menuWillOpen — runs synchronously, O(targets) cost.
enum MenuBuilder {

    struct Actions {
        let showAbout:     () -> Void
        let openSettings:  () -> Void
        let copyReport:    () -> Void
        let runSpeedtest:  () -> Void
        let exportCSV:     () -> Void
        let exportPDF:     () -> Void
        let quit:          () -> Void
    }

    @MainActor
    static func rebuild(_ menu: NSMenu, environment env: AppEnvironment, actions: Actions) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // MARK: - About
        menu.addItem(actionItem("About MeOrThem", action: actions.showAbout))
        menu.addItem(.separator())

        let settings  = env.settings
        let store     = env.metricStore
        let targets   = settings.pingTargets
        let threshold = settings.thresholds

        // MARK: - Overall summary
        let avgRTT: Double? = {
            let rtts = targets.compactMap { store.latestPing[$0.id]?.rtt }
            guard !rtts.isEmpty else { return nil }
            return rtts.reduce(0, +) / Double(rtts.count)
        }()

        let latencyStr: String
        if let rtt = avgRTT {
            let quality = rtt < threshold.latencyYellowMs ? "Excellent" :
                          rtt < threshold.latencyRedMs    ? "Fair" : "Poor"
            latencyStr = String(format: "Latency: %.1fms (%@)", rtt, quality)
        } else {
            latencyStr = "Latency: —"
        }

        let avgLoss = targets.compactMap { store.latestPing[$0.id]?.lossPercent }
                             .reduce(0, +) / Double(max(targets.count, 1))

        menu.addItem(staticItem(latencyStr))
        menu.addItem(staticItem(String(format: "Packet Loss: %.1f%%", avgLoss)))
        menu.addItem(.separator())

        // MARK: - Per-target rows
        for target in targets {
            let result = store.latestPing[target.id]
            let status = MetricStatus.forPingResult(result, thresholds: threshold)
            menu.addItem(TargetMenuItemView.menuItem(target: target, result: result, status: status))
        }
        menu.addItem(.separator())

        // MARK: - Network Details submenu
        menu.addItem(networkDetailsSubmenu(store: store))
        menu.addItem(.separator())

        // MARK: - Actions
        menu.addItem(actionItem("Ping Copy Report", action: actions.copyReport))

        let speedItem = actionItem(speedtestLabel(env.speedtestRunner), action: actions.runSpeedtest)
        speedItem.isEnabled = !isSpeedtestRunning(env.speedtestRunner)
        menu.addItem(speedItem)

        menu.addItem(staticItem(env.speedtestRunner.lastCheckedText,  color: .secondaryLabelColor))
        menu.addItem(staticItem(env.speedtestRunner.summaryText,      color: .secondaryLabelColor))

        menu.addItem(actionItem("Export CSV", action: actions.exportCSV))
        menu.addItem(actionItem("Export PDF", action: actions.exportPDF))
        menu.addItem(.separator())

        // MARK: - Misc
        menu.addItem(actionItem("Settings…", action: actions.openSettings))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        menu.addItem(staticItem("Version \(version)", color: .tertiaryLabelColor))

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", action: actions.quit))
    }

    // MARK: - Network Details submenu

    @MainActor
    private static func networkDetailsSubmenu(store: MetricStore) -> NSMenuItem {
        let parent = NSMenuItem(title: "Network Details", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Network Details")

        if let w = store.latestWifi {
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
            if let eth = NetworkInfo.ethernetInfo() {
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

    nonisolated(unsafe) private static let _menuFont = NSFont.menuFont(ofSize: 13)

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
