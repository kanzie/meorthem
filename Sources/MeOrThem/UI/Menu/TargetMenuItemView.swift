import AppKit

/// Custom NSView for a per-target row inside the NSMenu.
final class TargetMenuItemView: NSView {
    private static let height: CGFloat = 24
    private static let width:  CGFloat = 280

    private let dotView:   DotView
    private let rttLabel:  NSTextField
    private let lossLabel: NSTextField

    static func menuItem(target: PingTarget, result: PingResult?, status: MetricStatus) -> NSMenuItem {
        let view = TargetMenuItemView(target: target, result: result, status: status)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    init(target: PingTarget, result: PingResult?, status: MetricStatus) {
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
        let loss = TargetMenuItemView._makeLabel(lossStr, x: 212, width: 60, align: .right,
                                                 color: .secondaryLabelColor, size: 10)
        loss.isHidden = lossStr.isEmpty

        self.dotView   = dot
        self.rttLabel  = rtt
        self.lossLabel = loss

        super.init(frame: NSRect(x: 0, y: 0,
                                 width: TargetMenuItemView.width,
                                 height: TargetMenuItemView.height))

        addSubview(dot)
        addSubview(hostLabel)
        addSubview(rtt)
        addSubview(loss)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(result: PingResult?, status: MetricStatus) {
        dotView.statusColor = status.color

        if let rtt = result?.rtt {
            rttLabel.stringValue = String(format: "%.1f ms", rtt)
            rttLabel.textColor   = .labelColor
        } else {
            rttLabel.stringValue = result == nil ? "—" : "timeout"
            rttLabel.textColor   = .secondaryLabelColor
        }

        if let loss = result?.lossPercent, loss > 0 {
            lossLabel.stringValue = String(format: "%.0f%% loss", loss)
            lossLabel.isHidden    = false
        } else {
            lossLabel.stringValue = ""
            lossLabel.isHidden    = true
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
