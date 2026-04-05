import AppKit

enum StatusBarIconRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)

    // MARK: - Image cache
    //
    // Maps a compact Hashable key → pre-rendered NSImage.
    // Eliminates repeated NSImage allocations during 6 FPS blink animation and per-tick updates.
    // State space in practice: ~10–25 entries. Hard-capped at 64; evicted in bulk on overflow.
    private struct CacheKey: Hashable {
        let status: Int8          // MetricStatus.rawValue: 0=green 1=yellow 2=red
        let targetsPacked: UInt32 // bar-chart mode: 2 bits×16 statuses + count in top 4 bits
        let flags: UInt8          // bit 0=showBarChart, 1=pulse, 2=isLoading, 3=isPaused
        let barTag: Int8          // 0=none 1=green 2=orange 3=red 4=secondary/grey
    }

    nonisolated(unsafe) private static var cache = [CacheKey: NSImage]()
    private static let cacheMaxSize = 64

    static func invalidateCache() {
        cache.removeAll()
    }

    // MARK: - Public entry point

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

        let barTag = computeBarTag(
            isPaused: isPaused,
            showBandwidthBar: showBandwidthBar,
            bandwidthMbps: bandwidthMbps,
            bandwidthBarRunning: bandwidthBarRunning,
            bandwidthBarBlinkVisible: bandwidthBarBlinkVisible,
            bandwidthBarRedMbps: bandwidthBarRedMbps,
            bandwidthBarYellowMbps: bandwidthBarYellowMbps
        )

        let effectiveStatuses = showBarChart ? (targetStatuses.isEmpty ? [status] : targetStatuses) : []
        var flags: UInt8 = 0
        if showBarChart { flags |= 0x01 }
        if pulse        { flags |= 0x02 }
        if isLoading    { flags |= 0x04 }
        if isPaused     { flags |= 0x08 }

        let key = CacheKey(
            status: Int8(status.rawValue),
            targetsPacked: packStatuses(effectiveStatuses),
            flags: flags,
            barTag: barTag
        )

        if let cached = cache[key] { return cached }

        let image = renderUncached(
            status: status,
            effectiveStatuses: effectiveStatuses,
            showBarChart: showBarChart,
            pulse: pulse,
            isLoading: isLoading,
            isPaused: isPaused,
            barTag: barTag
        )

        if cache.count >= cacheMaxSize { cache.removeAll() }
        cache[key] = image
        return image
    }

    // MARK: - Cache helpers

    /// Computes a stable tag encoding the bandwidth bar's visual state.
    /// Accounts for the paused path (grey bar without blink) separately from
    /// the active path (color-coded or blinking grey).
    private static func computeBarTag(
        isPaused: Bool,
        showBandwidthBar: Bool,
        bandwidthMbps: Double?,
        bandwidthBarRunning: Bool,
        bandwidthBarBlinkVisible: Bool,
        bandwidthBarRedMbps: Double,
        bandwidthBarYellowMbps: Double
    ) -> Int8 {
        guard showBandwidthBar else { return 0 }

        if isPaused {
            // Paused: grey bar whenever any data or test exists (no blink)
            return (bandwidthMbps != nil || bandwidthBarRunning) ? 4 : 0
        }

        if bandwidthBarRunning {
            return bandwidthBarBlinkVisible ? 4 : 0
        }

        guard let mbps = bandwidthMbps else { return 0 }
        let color = bandwidthColor(mbps: mbps, redThreshold: bandwidthBarRedMbps,
                                   yellowThreshold: bandwidthBarYellowMbps)
        if color == .systemRed    { return 3 }
        if color == .systemOrange { return 2 }
        return 1
    }

    /// Converts a bar tag back to an NSColor for drawing.
    private static func barColor(for tag: Int8) -> NSColor? {
        switch tag {
        case 1: return .systemGreen
        case 2: return .systemOrange
        case 3: return .systemRed
        case 4: return .secondaryLabelColor
        default: return nil
        }
    }

    /// Packs up to 16 MetricStatus values into a UInt32: 2 bits each, count in top 4 bits.
    private static func packStatuses(_ statuses: [MetricStatus]) -> UInt32 {
        guard !statuses.isEmpty else { return 0 }
        var packed: UInt32 = 0
        for (i, s) in statuses.prefix(16).enumerated() {
            packed |= UInt32(s.rawValue) << (i * 2)
        }
        packed |= UInt32(min(statuses.count, 15)) << 28
        return packed
    }

    // MARK: - Uncached render (called only on cache miss)

    private static func renderUncached(
        status: MetricStatus,
        effectiveStatuses: [MetricStatus],
        showBarChart: Bool,
        pulse: Bool,
        isLoading: Bool,
        isPaused: Bool,
        barTag: Int8
    ) -> NSImage {
        // Paused: grey circle + optional grey bar (no blink, no color)
        if isPaused {
            let pausedBar: NSColor? = barTag != 0 ? .secondaryLabelColor : nil
            return hollowCircleIcon(color: .secondaryLabelColor, pulse: false, bandwidthBarColor: pausedBar)
        }

        let bColor = barColor(for: barTag)

        if isLoading {
            return hollowCircleIcon(color: .secondaryLabelColor, pulse: pulse, bandwidthBarColor: bColor)
        }

        if showBarChart {
            return barChartIcon(statuses: effectiveStatuses, bandwidthBarColor: bColor)
        }

        switch status {
        case .green:  return hollowCircleIcon(color: .systemGreen,  pulse: pulse, bandwidthBarColor: bColor)
        case .yellow: return hollowCircleIcon(color: .systemOrange, pulse: pulse, bandwidthBarColor: bColor)
        case .red:    return solidSquareIcon(color: .systemRed, bandwidthBarColor: bColor)
        }
    }

    // MARK: - Icon draw variants

    private static func hollowCircleIcon(color: NSColor, pulse: Bool, bandwidthBarColor: NSColor?) -> NSImage {
        draw { size in
            let margin: CGFloat = 2.5
            let bottomExtra: CGFloat = bandwidthBarColor != nil ? 2 : 0
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
                let cy = margin + bottomExtra + rect.height / 2
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
            let count = statuses.count
            guard count > 0 else { return }
            let topMargin: CGFloat    = 2
            let bottomMargin: CGFloat = bandwidthBarColor != nil ? 5 : 2
            let maxBarH = size.height - topMargin - bottomMargin
            let totalW  = size.width - 2
            let barW    = (totalW - CGFloat(count - 1)) / CGFloat(count)
            let gap: CGFloat = 1

            for (i, s) in statuses.enumerated() {
                let x    = 1 + CGFloat(i) * (barW + gap)
                let barH = maxBarH * Self.barHeightFraction(s)
                let rect = NSRect(x: x, y: bottomMargin, width: barW, height: barH)
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
