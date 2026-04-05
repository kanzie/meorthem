import AppKit

/// Custom NSView for a per-target row inside the NSMenu.
final class TargetMenuItemView: NSView {
    private static let height: CGFloat = 24
    private static let width:  CGFloat = 320   // extended to fit sparkline

    private let dotView:     DotView
    private let rttLabel:    NSTextField
    private let lossLabel:   NSTextField
    private let sparkView:   SparklineView

    static func menuItem(target: PingTarget, result: PingResult?,
                         status: MetricStatus, sparkline: [Double] = []) -> NSMenuItem {
        let view = TargetMenuItemView(target: target, result: result,
                                      status: status, sparkline: sparkline)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    init(target: PingTarget, result: PingResult?, status: MetricStatus, sparkline: [Double]) {
        let dot = DotView(status: status)
        dot.frame = NSRect(x: 14, y: 7, width: 10, height: 10)

        let hostLabel = TargetMenuItemView._makeLabel(target.label, x: 32, width: 100, align: .left)

        let rttStr: String
        if let rtt = result?.rtt {
            rttStr = String(format: "%.1f ms", rtt)
        } else {
            rttStr = result == nil ? "—" : "timeout"
        }
        let rtt = TargetMenuItemView._makeLabel(rttStr, x: 136, width: 72, align: .right,
                                                color: result?.rtt == nil ? .secondaryLabelColor : .labelColor)

        let lossStr = (result?.lossPercent ?? 0) > 0
            ? String(format: "%.0f%% loss", result!.lossPercent)
            : ""
        let loss = TargetMenuItemView._makeLabel(lossStr, x: 212, width: 55, align: .right,
                                                 color: .secondaryLabelColor, size: 10)
        loss.isHidden = lossStr.isEmpty

        // Sparkline: last N RTT values rendered as a tiny line graph
        let spark = SparklineView(values: sparkline, status: status)
        spark.frame = NSRect(x: 272, y: 4, width: 40, height: 16)

        self.dotView   = dot
        self.rttLabel  = rtt
        self.lossLabel = loss
        self.sparkView = spark

        super.init(frame: NSRect(x: 0, y: 0,
                                 width: TargetMenuItemView.width,
                                 height: TargetMenuItemView.height))

        addSubview(dot)
        addSubview(hostLabel)
        addSubview(rtt)
        addSubview(loss)
        addSubview(spark)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Cache last rendered values to skip redundant String(format:) calls on unchanged data.
    private var _lastRTT: Double?       = .nan   // .nan sentinel = "never set"
    private var _lastResultNil: Bool    = true
    private var _lastLoss: Double       = -1     // -1 sentinel = "never set"

    func update(result: PingResult?, status: MetricStatus, sparkline: [Double] = []) {
        dotView.statusColor = status.color

        let rtt = result?.rtt
        let resultNil = result == nil
        if rtt != _lastRTT || resultNil != _lastResultNil {
            _lastRTT = rtt
            _lastResultNil = resultNil
            if let rtt {
                rttLabel.stringValue = String(format: "%.1f ms", rtt)
                rttLabel.textColor   = .labelColor
            } else {
                rttLabel.stringValue = resultNil ? "—" : "timeout"
                rttLabel.textColor   = .secondaryLabelColor
            }
        }

        let loss = result?.lossPercent ?? 0
        if loss != _lastLoss {
            _lastLoss = loss
            if loss > 0 {
                lossLabel.stringValue = String(format: "%.0f%% loss", loss)
                lossLabel.isHidden    = false
            } else {
                lossLabel.stringValue = ""
                lossLabel.isHidden    = true
            }
        }

        if !sparkline.isEmpty {
            sparkView.update(values: sparkline, status: status)
        }
    }

    private static let _font12 = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let _font10 = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private static func _makeLabel(_ text: String, x: CGFloat, width: CGFloat,
                                   align: NSTextAlignment,
                                   color: NSColor = .labelColor,
                                   size: CGFloat = 12) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.frame = NSRect(x: x, y: 4, width: width, height: 16)
        tf.font = size == 10 ? TargetMenuItemView._font10 : TargetMenuItemView._font12
        tf.textColor = color
        tf.alignment = align
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }
}

// MARK: - SparklineView

/// Draws a tiny 40×16 pt sparkline of recent RTT values.
private final class SparklineView: NSView {
    private var values: [Double]
    // strokeColor is pre-computed from status.color — avoids NSColor allocation on every draw().
    private var strokeColor: NSColor

    init(values: [Double], status: MetricStatus) {
        self.values      = values
        self.strokeColor = status.color.withAlphaComponent(0.7)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(values: [Double], status: MetricStatus) {
        self.values      = values
        self.strokeColor = status.color.withAlphaComponent(0.7)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count >= 2 else { return }
        let nonZero = values.filter { $0 > 0 }
        guard let maxVal = nonZero.max(), maxVal > 0 else { return }

        let w = bounds.width
        let h = bounds.height
        let step = w / CGFloat(values.count - 1)
        let path = NSBezierPath()
        path.lineWidth = 1.0
        path.lineJoinStyle = .round

        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let fraction = CGFloat(min(v / maxVal, 1.0))
            let y = 1 + fraction * (h - 2)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }

        strokeColor.setStroke()
        path.stroke()
    }

    override var isOpaque: Bool { false }
}

// MARK: - Small colored dot view
private final class DotView: NSView {
    var statusColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(status: MetricStatus) {
        self.statusColor = status.color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        statusColor.setFill()
        path.fill()
    }
}
