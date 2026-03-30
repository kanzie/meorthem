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
    static let tagLatency        = 1
    static let tagPacketLoss     = 2
    static let tagJitter         = 3
    static let tagCountdown      = 4
    static let tagNetworkDetails = 5
    static let tagTargetBase     = 100   // tagTargetBase + index per target

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
        let netItem = networkDetailsSubmenu(store: store)
        netItem.tag = tagNetworkDetails
        menu.addItem(netItem)
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
    static func refreshNetworkDetails(_ menu: NSMenu, environment env: AppEnvironment) {
        guard let item = menu.item(withTag: tagNetworkDetails) else { return }
        let updated = networkDetailsSubmenu(store: env.metricStore)
        item.submenu = updated.submenu
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
            sub.addItem(infoItem("WiFi — \(w.ssid)", bold: true))
            sub.addItem(.separator())
            if let ip = w.ipAddress   { sub.addItem(infoItem("IP Address:  \(ip)")) }
            if let gw = w.routerIP    { sub.addItem(infoItem("Router:      \(gw)")) }
            sub.addItem(infoItem("MAC Address: \(w.macAddress)"))
            sub.addItem(infoItem("Channel:     \(w.channelDescription)"))
            sub.addItem(infoItem("RSSI:        \(w.rssi) dBm (\(w.rssiQuality))"))
            sub.addItem(infoItem("Noise:       \(w.noise) dBm"))
            sub.addItem(infoItem(String(format: "Tx Rate:     %.3f Mbps", w.txRateMbps)))
            sub.addItem(infoItem("PHY Mode:    \(w.phyMode)"))
        } else {
            // Ethernet or no network
            let wifiIfaceName = WiFiMonitor.interfaceName()
            if let eth = NetworkInfo.ethernetInfo(excluding: wifiIfaceName) {
                sub.addItem(infoItem("Ethernet — \(eth.interface)", bold: true))
                sub.addItem(.separator())
                sub.addItem(infoItem("IP Address:  \(eth.ip)"))
                if let gw = NetworkInfo.defaultGateway() {
                    sub.addItem(infoItem("Router:      \(gw)"))
                }
                sub.addItem(infoItem("MAC Address: \(eth.mac)"))
            } else {
                sub.addItem(infoItem("No network connection"))
            }
        }

        parent.submenu = sub
        return parent
    }

    /// Creates a view-based menu item displaying text in labelColor with no hover highlight.
    @MainActor
    private static func infoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let view = InfoMenuItemView(text: text, bold: bold)
        item.view = view
        return item
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

// MARK: - InfoMenuItemView: non-hoverable info row with labelColor text

/// A plain NSView-based menu item that shows readable (non-grey) text without hover highlight.
final class InfoMenuItemView: NSView {
    private static let font12 = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let font12b = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    init(text: String, bold: Bool = false) {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? InfoMenuItemView.font12b : InfoMenuItemView.font12
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let width: CGFloat = 280
        let size = (text as NSString).boundingRect(
            with: NSSize(width: width - 28, height: 100),
            options: .usesLineFragmentOrigin,
            attributes: [.font: label.font!]
        )
        let height = max(20, size.height + 6)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        label.frame = NSRect(x: 14, y: 3, width: width - 20, height: height - 6)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    // No background drawing → no hover highlight
    override var isOpaque: Bool { false }
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
