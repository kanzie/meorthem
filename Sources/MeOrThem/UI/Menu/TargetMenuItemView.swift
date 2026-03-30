import AppKit

/// Custom NSView for a per-target row inside the NSMenu.
final class TargetMenuItemView: NSView {
    private static let height: CGFloat = 24
    private static let width:  CGFloat = 280

    static func menuItem(target: PingTarget, result: PingResult?, status: MetricStatus) -> NSMenuItem {
        let view = TargetMenuItemView(target: target, result: result, status: status)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    init(target: PingTarget, result: PingResult?, status: MetricStatus) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: TargetMenuItemView.width,
                                 height: TargetMenuItemView.height))

        // Dot
        let dot = DotView(status: status)
        dot.frame = NSRect(x: 14, y: 7, width: 10, height: 10)
        addSubview(dot)

        // Host label (left)
        let hostLabel = makeLabel(target.label, x: 32, width: 100, align: .left)
        addSubview(hostLabel)

        // RTT label (right-aligned)
        let rttStr: String
        if let rtt = result?.rtt {
            rttStr = String(format: "%.1f ms", rtt)
        } else {
            rttStr = result == nil ? "—" : "timeout"
        }
        let rttLabel = makeLabel(rttStr, x: 136, width: 72, align: .right,
                                 color: result?.rtt == nil ? .secondaryLabelColor : .labelColor)
        addSubview(rttLabel)

        // Loss label
        if let loss = result?.lossPercent, loss > 0 {
            let lossLabel = makeLabel(String(format: "%.0f%% loss", loss),
                                       x: 212, width: 60, align: .right,
                                       color: .secondaryLabelColor, size: 10)
            addSubview(lossLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let _font12 = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let _font10 = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private func makeLabel(_ text: String, x: CGFloat, width: CGFloat,
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
    private let status: MetricStatus

    init(status: MetricStatus) {
        self.status = status
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        status.color.setFill()
        path.fill()
    }
}
