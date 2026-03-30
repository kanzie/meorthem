import AppKit

enum StatusBarIconRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)

    /// Renders the appropriate status bar icon.
    /// - Parameters:
    ///   - status: overall connection quality
    ///   - targetStatuses: per-target statuses for bar chart rendering
    ///   - showBarChart: if true, always render bar chart; if false, use circle/square
    static func render(
        status: MetricStatus,
        targetStatuses: [MetricStatus],
        showBarChart: Bool
    ) -> NSImage {
        let useBarChart = showBarChart || (status == .yellow && !targetStatuses.isEmpty)
        if useBarChart && !targetStatuses.isEmpty {
            return barChartIcon(statuses: targetStatuses)
        }
        switch status {
        case .green:  return hollowCircleIcon(color: .systemGreen)
        case .yellow: return barChartIcon(statuses: targetStatuses.isEmpty ? [.yellow] : targetStatuses)
        case .red:    return solidSquareIcon(color: .systemRed)
        }
    }

    // MARK: - Icon variants

    /// Hollow circle with colored stroke (good status)
    private static func hollowCircleIcon(color: NSColor) -> NSImage {
        draw { size in
            let margin: CGFloat = 2.5
            let rect = NSRect(x: margin, y: margin,
                              width: size.width - margin * 2,
                              height: size.height - margin * 2)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 2
            color.setStroke()
            path.stroke()
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

            // Height fraction per status: green=1.0, yellow=0.65, red=0.35
            let heightFraction: (MetricStatus) -> CGFloat = { s in
                switch s {
                case .green:  return 1.0
                case .yellow: return 0.60
                case .red:    return 0.30
                }
            }

            for (i, s) in statuses.enumerated() {
                let x     = 1 + CGFloat(i) * (barW + gap)
                let barH  = maxBarH * heightFraction(s)
                let y     = bottomMargin
                let rect  = NSRect(x: x, y: y, width: barW, height: barH)
                let path  = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                s.color.setFill()
                path.fill()
            }
        }
    }

    // MARK: - Helper

    private static func draw(_ block: (NSSize) -> Void) -> NSImage {
        let image = NSImage(size: iconSize)
        image.lockFocus()
        block(iconSize)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
