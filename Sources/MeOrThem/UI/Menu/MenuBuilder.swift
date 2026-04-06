import AppKit

/// Stateless utility that rebuilds an NSMenu from current AppEnvironment state.
/// Called in NSMenuDelegate.menuWillOpen — runs synchronously, O(targets) cost.
enum MenuBuilder {

    struct Actions {
        let showAbout:     () -> Void
        let openSettings:  () -> Void
        let copyReport:    () -> Void
        let runSpeedtest:  () -> Void
        let showHelp:      () -> Void
        let togglePause:   () -> Void
        let quit:          () -> Void
    }

    // Tags for items updated during live refresh
    static let tagLatency                = 1
    static let tagPacketLoss             = 2
    static let tagJitter                 = 3
    static let tagNetworkDetails         = 5
    static let tagSpeedtestLabel         = 7
    static let tagSpeedtestLast          = 8
    static let tagSpeedtestResult        = 9
    static let tagPauseItem              = 10
    static let tagLastEvent              = 11
    static let tagPreviousDisturbances   = 12
    static let tagTargetBase             = 100
    static let tagGatewayTarget          = 200

    @MainActor
    static func rebuild(_ menu: NSMenu, environment env: AppEnvironment, actions: Actions) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let settings  = env.settings
        let store     = env.metricStore
        let targets   = settings.pingTargets
        let threshold = settings.thresholds
        let paused    = env.monitoringEngine.isPaused

        // MARK: - Pause / Resume (top of menu — task 7)
        let pauseLabel = env.monitoringEngine.isManuallyPaused ? "Resume Monitoring" : "Pause Monitoring"
        let pauseItem  = actionItem(pauseLabel, action: actions.togglePause)
        pauseItem.tag  = tagPauseItem
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        // MARK: - Overall summary
        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))

        let latencyItem = staticItem(latencyString(targets: targets, store: store,
                                                   threshold: threshold,
                                                   pollSecs: settings.pollIntervalSecs,
                                                   countdown: remaining,
                                                   paused: paused))
        latencyItem.tag = tagLatency
        menu.addItem(latencyItem)

        let lossValues = paused ? [] : targets.compactMap { store.latestPing[$0.id]?.lossPercent }
        let avgLoss: Double? = lossValues.isEmpty ? nil : lossValues.reduce(0, +) / Double(lossValues.count)
        let lossItem = staticItem(paused ? "Packet Loss: Paused"
                                         : String(format: "Packet Loss: %.1f%%", avgLoss ?? 0))
        lossItem.tag = tagPacketLoss
        menu.addItem(lossItem)

        let jitterValues = paused ? [] : targets.compactMap { store.latestPing[$0.id]?.jitter }
        let avgJitter    = jitterValues.reduce(0.0, +) / Double(max(jitterValues.count, 1))
        let jitterItem   = staticItem(paused ? "Jitter: Paused" :
                                     (jitterValues.isEmpty
                                         ? "Jitter: —"
                                         : String(format: "Jitter: %.1fms avg", avgJitter)))
        jitterItem.tag = tagJitter
        menu.addItem(jitterItem)

        // Recovery/Ongoing indicator — shown when there is or was a recent degradation event
        let lastEventItem = lastEventMenuItem(store: store)
        lastEventItem.tag = tagLastEvent
        menu.addItem(lastEventItem)

        menu.addItem(.separator())

        // MARK: - Per-target rows (user targets)
        for (i, target) in targets.enumerated() {
            let result = paused ? nil : store.latestPing[target.id]
            let status = store.effectiveStatus(for: target.id)
            let spark  = store.sparklineData(for: target.id)
            let item   = TargetMenuItemView.menuItem(target: target, result: result,
                                                     status: status, sparkline: spark)
            item.tag = tagTargetBase + i
            menu.addItem(item)
        }

        // Gateway system target row
        let gatewayIP    = env.monitoringEngine.lastGatewayIP ?? "—"
        let gatewayTarget = PingTarget(id: PingTarget.gatewayID, label: "Gateway",
                                       host: gatewayIP, isSystem: true)
        let gwResult  = paused ? nil : store.latestPing[PingTarget.gatewayID]
        let gwStatus  = store.effectiveStatus(for: PingTarget.gatewayID)
        let gwSpark   = store.sparklineData(for: PingTarget.gatewayID)
        let gwItem    = TargetMenuItemView.menuItem(target: gatewayTarget, result: gwResult,
                                                    status: gwStatus, sparkline: gwSpark)
        gwItem.tag = tagGatewayTarget
        menu.addItem(gwItem)
        menu.addItem(.separator())

        // MARK: - Actions section
        menu.addItem(actionItem("Ping Stats Report", action: actions.copyReport))

        let distItem = previousDisturbancesItem(store: store,
                                                clearHistory: { store.clearConnectionHistory() })
        distItem.tag = tagPreviousDisturbances
        menu.addItem(distItem)

        let netItem = networkDetailsSubmenu(store: store)
        netItem.tag = tagNetworkDetails
        menu.addItem(netItem)

        menu.addItem(.separator())

        let speedLabelItem = actionItem(speedtestLabel(env.speedtestRunner), action: actions.runSpeedtest)
        speedLabelItem.isEnabled = !isSpeedtestRunning(env.speedtestRunner)
            && !env.monitoringEngine.isManuallyPaused
        speedLabelItem.tag = tagSpeedtestLabel
        menu.addItem(speedLabelItem)

        let lastItem = staticItem(env.speedtestRunner.lastCheckedText, color: .secondaryLabelColor)
        lastItem.tag = tagSpeedtestLast
        menu.addItem(lastItem)

        let resultItem = staticItem(env.speedtestRunner.summaryText, color: .secondaryLabelColor)
        resultItem.tag = tagSpeedtestResult
        menu.addItem(resultItem)

        menu.addItem(.separator())

        // Task 9: Help, Settings, About order
        menu.addItem(actionItem("Help",            action: actions.showHelp))
        menu.addItem(actionItem("Settings…",       action: actions.openSettings))
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
        let paused    = env.monitoringEngine.isPaused

        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))

        if let item = menu.item(withTag: tagLatency) {
            item.attributedTitle = NSAttributedString(
                string: latencyString(targets: targets, store: store, threshold: threshold,
                                      pollSecs: settings.pollIntervalSecs, countdown: remaining,
                                      paused: paused),
                attributes: _labelAttrs)
        }

        let lossValues = paused ? [] : targets.compactMap { store.latestPing[$0.id]?.lossPercent }
        let avgLoss: Double? = lossValues.isEmpty ? nil : lossValues.reduce(0, +) / Double(lossValues.count)
        if let item = menu.item(withTag: tagPacketLoss) {
            item.attributedTitle = NSAttributedString(
                string: paused ? "Packet Loss: Paused"
                               : String(format: "Packet Loss: %.1f%%", avgLoss ?? 0),
                attributes: _labelAttrs)
        }

        let jitterValues = paused ? [] : targets.compactMap { store.latestPing[$0.id]?.jitter }
        let avgJitter    = jitterValues.reduce(0.0, +) / Double(max(jitterValues.count, 1))
        if let item = menu.item(withTag: tagJitter) {
            item.attributedTitle = NSAttributedString(
                string: paused ? "Jitter: Paused" :
                        (jitterValues.isEmpty ? "Jitter: —"
                         : String(format: "Jitter: %.1fms avg", avgJitter)),
                attributes: _labelAttrs)
        }

        if let item = menu.item(withTag: tagLastEvent) {
            let updated = lastEventMenuItem(store: store)
            item.attributedTitle = updated.attributedTitle
            item.isHidden        = updated.isHidden
        }

        for (i, target) in targets.enumerated() {
            guard let item = menu.item(withTag: tagTargetBase + i) else { continue }
            let result = paused ? nil : store.latestPing[target.id]
            let status = store.effectiveStatus(for: target.id)
            let spark  = store.sparklineData(for: target.id)
            (item.view as? TargetMenuItemView)?.update(result: result, status: status, sparkline: spark)
        }

        if let gwItem = menu.item(withTag: tagGatewayTarget) {
            let gwResult = paused ? nil : store.latestPing[PingTarget.gatewayID]
            let gwStatus = store.effectiveStatus(for: PingTarget.gatewayID)
            let gwSpark  = store.sparklineData(for: PingTarget.gatewayID)
            (gwItem.view as? TargetMenuItemView)?.update(result: gwResult, status: gwStatus, sparkline: gwSpark)
        }
    }

    @MainActor
    static func refreshSpeedtestItems(_ menu: NSMenu, runner: SpeedtestRunner, environment env: AppEnvironment) {
        if let item = menu.item(withTag: tagSpeedtestLabel) {
            item.attributedTitle = NSAttributedString(string: speedtestLabel(runner), attributes: _labelAttrs)
            item.isEnabled = !isSpeedtestRunning(runner) && !env.monitoringEngine.isManuallyPaused
        }
        if let item = menu.item(withTag: tagSpeedtestLast) {
            item.attributedTitle = NSAttributedString(
                string: runner.lastCheckedText,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: _menuFont])
        }
        if let item = menu.item(withTag: tagSpeedtestResult) {
            item.attributedTitle = NSAttributedString(
                string: runner.summaryText,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: _menuFont])
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
        let paused    = env.monitoringEngine.isPaused
        let remaining = max(0, Int(env.monitoringEngine.nextTickAt.timeIntervalSinceNow))
        item.attributedTitle = NSAttributedString(
            string: latencyString(targets: targets, store: store, threshold: threshold,
                                  pollSecs: settings.pollIntervalSecs, countdown: remaining,
                                  paused: paused),
            attributes: _labelAttrs)
    }

    // MARK: - Last event item (Task 2)

    @MainActor
    private static func lastEventMenuItem(store: MetricStore) -> NSMenuItem {
        guard let event = store.connectionHistory.first else {
            return hiddenItem()
        }

        let text: String
        let color: NSColor

        if event.isActive {
            text  = "Ongoing"
            color = event.severity == MetricStatus.red ? .systemRed : .systemOrange
        } else {
            // Hide "Recovered" after 1 minute of stability.
            let kRecoveredTimeoutSecs: TimeInterval = 60
            if let end = event.endTime, Date().timeIntervalSince(end) > kRecoveredTimeoutSecs {
                return hiddenItem()
            }
            text  = "Recovered"
            color = .secondaryLabelColor
        }

        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: _menuFont])
        return item
    }

    // MARK: - Previous Disturbances submenu

    @MainActor
    static func previousDisturbancesItem(store: MetricStore,
                                         clearHistory: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Previous Disturbances", action: nil, keyEquivalent: "")
        item.submenu = connectionHistorySubmenu(history: store.connectionHistory,
                                               clearHistory: clearHistory)
        return item
    }

    @MainActor
    static func refreshPreviousDisturbances(_ menu: NSMenu, store: MetricStore,
                                            clearHistory: @escaping () -> Void) {
        guard let item = menu.item(withTag: tagPreviousDisturbances) else { return }
        // Skip if user is currently hovering the item (submenu may be open)
        guard menu.highlightedItem !== item else { return }
        let updated = previousDisturbancesItem(store: store, clearHistory: clearHistory)
        item.submenu = updated.submenu
    }

    // MARK: - Network Details submenu

    @MainActor
    private static func networkDetailsSubmenu(store: MetricStore) -> NSMenuItem {
        let parent = NSMenuItem(title: "Network Details", action: nil, keyEquivalent: "")
        let sub    = NSMenu(title: "Network Details")

        if let w = store.latestWifi ?? WiFiMonitor.snapshot() {
            sub.addItem(infoItem("WiFi", bold: true))
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

    // MARK: - Previous Disturbances submenu content

    @MainActor
    private static func connectionHistorySubmenu(history: [ConnectionEvent],
                                                 clearHistory: @escaping () -> Void) -> NSMenu {
        let sub = NSMenu(title: "Previous Disturbances")

        if history.isEmpty {
            sub.addItem(infoItem("No degradation events recorded"))
            return sub
        }

        for event in history {
            let dotColor: NSColor = event.severity == .red ? .systemRed : .systemOrange
            let dot  = "● "
            let ts   = event.timestampString
            let dur  = event.isActive
                ? "active · \(event.durationString())"
                : "lasted \(event.durationString())"
            let text = "\(dot)\(ts) · \(event.cause) · \(dur)"

            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false

            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: dotColor,
                .font: NSFont.menuFont(ofSize: 12)
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuFont(ofSize: 12)
            ]
            let attributed = NSMutableAttributedString(string: dot, attributes: attrs)
            attributed.append(NSAttributedString(string: "\(ts) · \(event.cause) · \(dur)",
                                                 attributes: bodyAttrs))
            item.attributedTitle = attributed
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear All", action: #selector(AppDelegate.noop),
                                   keyEquivalent: "")
        clearItem.isEnabled = true
        clearItem.target    = ActionTarget.shared
        ActionTarget.shared.register(clearItem, action: clearHistory)
        sub.addItem(clearItem)

        return sub
    }

    @MainActor
    private static func hiddenItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden  = true
        return item
    }

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
                                      countdown: Int? = nil,
                                      paused: Bool = false) -> String {
        let intervalStr = pollSecs.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(pollSecs))s" : String(format: "%.1fs", pollSecs)
        if paused {
            return "Latency: Paused · \(intervalStr)"
        }
        let rtts = targets.compactMap { store.latestPing[$0.id]?.rtt }
        let countdownSuffix: String
        if let cd = countdown, cd > 0 {
            countdownSuffix = " (\(cd)s)"
        } else {
            countdownSuffix = ""
        }
        guard !rtts.isEmpty else { return "Latency: — · \(intervalStr)\(countdownSuffix)" }
        let avg     = rtts.reduce(0, +) / Double(rtts.count)
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
            attributes: [.foregroundColor: color, .font: _menuFont])
        return item
    }

    @MainActor
    private static func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.noop), keyEquivalent: "")
        item.isEnabled = true
        item.target    = ActionTarget.shared
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

final class InfoMenuItemView: NSView {
    private static let font12  = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
    override var isOpaque: Bool { false }
}

// MARK: - ActionTarget: bridges closures to @objc targets

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
