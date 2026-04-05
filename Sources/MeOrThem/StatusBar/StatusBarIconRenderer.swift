import AppKit

enum StatusBarIconRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)

    static func invalidateCache() {
        // Reserved for future caching; loading frames are now rendered fresh each tick.
    }

    /// Renders the status bar icon.
    /// - Parameters:
    ///   - status: overall connection quality
    ///   - targetStatuses: per-target statuses for bar chart rendering
    ///   - showBarChart: render bar chart instead of circle/square
    ///   - pulse: heartbeat dot in circle centre
    ///   - isLoading: grey hollow circle while waiting for first data
    ///   - isPaused: monitoring is manually paused — renders grey circle + grey bar
    ///   - bandwidthMbps: last known download speed for the quality bar
    ///   - showBandwidthBar: whether the bandwidth bar feature is enabled
    ///   - bandwidthBarRunning: bandwidth test is in progress (bar blinks grey)
    ///   - bandwidthBarBlinkVisible: blink phase; alternates for animated grey bar
    ///   - bandwidthBarRedMbps / bandwidthBarYellowMbps: quality thresholds
    static func render(
        status: MetricStatus,
        targetStatuses: [MetricStatus],
        showBarChart: Bool,
        pulse: Bool = false,
        isLoading: Bool = false,
        isPaused: Bool = false,
        bandwidthMbps: Double? = nil,
        showBandwidthBar: Bool = false,
        bandwidthBarRunning: Bool = false,
        bandwidthBarBlinkVisible: Bool = false,
        bandwidthBarRedMbps: Double = 10,
        bandwidthBarYellowMbps: Double = 25
    ) -> NSImage {

        // Compute bandwidth bar colour first — used in all states including loading/paused.
        let barColor: NSColor?
        if showBandwidthBar {
            if bandwidthBarRunning {
                barColor = bandwidthBarBlinkVisible ? .secondaryLabelColor : nil
            } else if let mbps = bandwidthMbps {
                barColor = bandwidthColor(mbps: mbps, redThreshold: bandwidthBarRedMbps,
                                          yellowThreshold: bandwidthBarYellowMbps)
            } else {
                barColor = nil
            }
        } else {
            barColor = nil
        }

        // Paused: grey circle + grey bar (if data or test exists)
        if isPaused {
            let pausedBar: NSColor? = showBandwidthBar && (bandwidthMbps != nil || bandwidthBarRunning)
                ? .secondaryLabelColor : nil
            return hollowCircleIcon(color: .secondaryLabelColor, pulse: false, bandwidthBarColor: pausedBar)
        }

        // Loading: grey blinking circle + grey blinking bar (bar blink uses same phase as loading dot)
        if isLoading {
            return hollowCircleIcon(color: .secondaryLabelColor, pulse: pulse, bandwidthBarColor: barColor)
        }

        if showBarChart {
            return barChartIcon(statuses: targetStatuses.isEmpty ? [status] : targetStatuses,
                                bandwidthBarColor: barColor)
        }
        switch status {
        case .green:  return hollowCircleIcon(color: .systemGreen,  pulse: pulse, bandwidthBarColor: barColor)
        case .yellow: return hollowCircleIcon(color: .systemOrange, pulse: pulse, bandwidthBarColor: barColor)
        case .red:    return solidSquareIcon(color: .systemRed, bandwidthBarColor: barColor)
        }
    }

    // MARK: - Icon variants

    private static func hollowCircleIcon(color: NSColor, pulse: Bool, bandwidthBarColor: NSColor?) -> NSImage {
        draw { size in
            let margin: CGFloat = 2.5
            let bottomExtra: CGFloat = bandwidthBarColor != nil ? 2 : 0  // 2px gap between circle and bar
            let rect = NSRect(x: margin, y: margin + bottomExtra,
                              width: size.width - margin * 2,
                              height: size.height - margin * 2 - bottomExtra)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 2
            color.setStroke()
            path.stroke()

            if pulse {
                let dotR: CGFloat = 2
                let cx = size.width / 2
                let cy = (margin + bottomExtra + rect.height / 2)
                let dot = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR,
                                                      width: dotR * 2, height: dotR * 2))
                color.setFill()
                dot.fill()
            }

            drawBandwidthBar(color: bandwidthBarColor, in: size)
        }
    }

    private static func solidSquareIcon(color: NSColor, bandwidthBarColor: NSColor?) -> NSImage {
        draw { size in
            let margin: CGFloat = 3.0
            let bottomExtra: CGFloat = bandwidthBarColor != nil ? 2 : 0
            let rect = NSRect(x: margin, y: margin + bottomExtra,
                              width: size.width - margin * 2,
                              height: size.height - margin * 2 - bottomExtra)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.setFill()
            path.fill()

            drawBandwidthBar(color: bandwidthBarColor, in: size)
        }
    }

    private static func barChartIcon(statuses: [MetricStatus], bandwidthBarColor: NSColor?) -> NSImage {
        draw { size in
            let count      = statuses.count
            guard count > 0 else { return }
            let topMargin: CGFloat    = 2
            let bottomMargin: CGFloat = bandwidthBarColor != nil ? 5 : 2  // room for bar + 2px gap
            let maxBarH   = size.height - topMargin - bottomMargin
            let totalW    = size.width - 2
            let barW      = (totalW - CGFloat(count - 1)) / CGFloat(count)
            let gap: CGFloat = 1

            for (i, s) in statuses.enumerated() {
                let x    = 1 + CGFloat(i) * (barW + gap)
                let barH = maxBarH * Self.barHeightFraction(s)
                let y    = bottomMargin
                let rect = NSRect(x: x, y: y, width: barW, height: barH)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                s.color.setFill()
                path.fill()
            }

            drawBandwidthBar(color: bandwidthBarColor, in: size)
        }
    }

    // MARK: - Bandwidth bar

    private static func drawBandwidthBar(color: NSColor?, in size: NSSize) {
        guard let color else { return }
        let barH: CGFloat = 2
        let margin: CGFloat = 2.5
        let rect = NSRect(x: margin, y: 0.5,
                          width: size.width - margin * 2, height: barH)
        let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        color.setFill()
        path.fill()
    }

    private static func bandwidthColor(mbps: Double, redThreshold: Double, yellowThreshold: Double) -> NSColor {
        if mbps < redThreshold    { return .systemRed }
        if mbps < yellowThreshold { return .systemOrange }
        return .systemGreen
    }

    // MARK: - Helpers

    private static func barHeightFraction(_ s: MetricStatus) -> CGFloat {
        switch s {
        case .green:  return 1.0
        case .yellow: return 0.60
        case .red:    return 0.30
        }
    }

    private static func draw(_ block: (NSSize) -> Void) -> NSImage {
        let image = NSImage(size: iconSize)
        image.lockFocus()
        block(iconSize)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
