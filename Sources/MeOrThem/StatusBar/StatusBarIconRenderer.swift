import AppKit

enum StatusBarIconRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)

    /// Renders the appropriate status bar icon.
    /// - Parameters:
    ///   - status: overall connection quality
    ///   - targetStatuses: per-target statuses for bar chart rendering
    ///   - showBarChart: if true, always render bar chart; if false, use circle/square
    ///   - pulse: if true, draws a small heartbeat dot in the centre of the circle icon
    ///   - isLoading: if true, renders a grey hollow circle (no data yet)
    static func render(
        status: MetricStatus,
        targetStatuses: [MetricStatus],
        showBarChart: Bool,
        pulse: Bool = false,
        isLoading: Bool = false
    ) -> NSImage {
        if isLoading {
            return hollowCircleIcon(color: .secondaryLabelColor, pulse: false)
        }
        if showBarChart {
            return barChartIcon(statuses: targetStatuses.isEmpty ? [status] : targetStatuses)
        }
        switch status {
        case .green:  return hollowCircleIcon(color: .systemGreen, pulse: pulse)
        case .yellow: return hollowCircleIcon(color: .systemOrange, pulse: pulse)
        case .red:    return solidSquareIcon(color: .systemRed)
        }
    }

    // MARK: - Icon variants

    /// Hollow circle with colored stroke (good status).
    /// When `pulse` is true a small filled dot is drawn in the centre.
    private static func hollowCircleIcon(color: NSColor, pulse: Bool) -> NSImage {
        draw { size in
            let margin: CGFloat = 2.5
            let rect = NSRect(x: margin, y: margin,
                              width: size.width - margin * 2,
                              height: size.height - margin * 2)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 2
            color.setStroke()
            path.stroke()

            if pulse {
                let dotR: CGFloat = 2
                let cx = size.width / 2
                let cy = size.height / 2
                let dot = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR,
                                                      width: dotR * 2, height: dotR * 2))
                color.setFill()
                dot.fill()
            }
        }
    }

    /// Solid filled square (bad status)
    private static func solidSquareIcon(color: NSColor) -> NSImage {
        draw { size in
            let margin: CGFloat = 3.0
            let rect = NSRect(x: margin, y: margin,
                              width: size.width - margin * 2,
                              height: size.height - margin * 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.setFill()
            path.fill()
        }
    }

    /// Bar chart with per-target colored bars (unstable status)
    private static func barChartIcon(statuses: [MetricStatus]) -> NSImage {
        draw { size in
            let count     = statuses.count
            guard count > 0 else { return }
            let topMargin: CGFloat   = 2
            let bottomMargin: CGFloat = 2
            let maxBarH   = size.height - topMargin - bottomMargin
            let totalW    = size.width - 2
            let barW      = (totalW - CGFloat(count - 1)) / CGFloat(count)
            let gap: CGFloat = 1

            for (i, s) in statuses.enumerated() {
                let x     = 1 + CGFloat(i) * (barW + gap)
                let barH  = maxBarH * Self.barHeightFraction(s)
                let y     = bottomMargin
                let rect  = NSRect(x: x, y: y, width: barW, height: barH)
                let path  = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                s.color.setFill()
                path.fill()
            }
        }
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
