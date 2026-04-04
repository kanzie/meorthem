import AppKit
import SwiftUI

final class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private init() {
        let vc = NSHostingController(rootView: HelpView())
        vc.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: vc)
        window.title = "Me Or Them — Help"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 600))
        window.minSize = NSSize(width: 400, height: 400)
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - HelpView

private struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 12)
                metricSection(
                    title: "Ping Latency",
                    icon: "network",
                    eli5: "Think of it like shouting across a room and timing how long it takes to hear the echo. Latency is the round-trip time for a tiny packet of data to travel from your device to a server and back.",
                    normal: "< 20 ms — Excellent\n20–50 ms — Good\n50–100 ms — Fair\n> 150 ms — Poor",
                    concern: "A single spike is harmless — your router was briefly busy. Worry when latency stays high for more than 10 seconds, or is consistently above 100 ms.",
                    useCases: [
                        ("Video calls", "< 150 ms"),
                        ("Online gaming", "< 50 ms"),
                        ("Browsing", "< 300 ms"),
                    ]
                )
                Divider().padding(.vertical, 12)
                metricSection(
                    title: "Jitter",
                    icon: "waveform.path",
                    eli5: "Jitter measures how consistent your latency is. Low latency that varies wildly — say 10 ms one moment and 90 ms the next — still causes choppy audio and video, because packets arrive out of order.",
                    normal: "< 5 ms — Excellent\n5–15 ms — Good\n15–30 ms — Fair\n> 30 ms — Poor",
                    concern: "Brief jitter during large downloads is normal (your link is busy). Sustained jitter above 20 ms while idle suggests an unstable connection.",
                    useCases: [
                        ("Video calls", "< 30 ms"),
                        ("Online gaming", "< 15 ms"),
                        ("Browsing", "Doesn't matter much"),
                    ]
                )
                Divider().padding(.vertical, 12)
                metricSection(
                    title: "Packet Loss",
                    icon: "exclamationmark.triangle",
                    eli5: "Sometimes data packets simply vanish on the way — dropped by an overloaded router or a flaky cable. Even 1% loss causes visible glitches in calls and lag spikes in games, because the missing data must be re-sent.",
                    normal: "0% — Perfect\n< 0.5% — Acceptable\n1–3% — Noticeable\n> 5% — Severe",
                    concern: "1–2 lost packets in an hour is nothing. Loss above 1% that persists for minutes means something is wrong — check your WiFi signal or router.",
                    useCases: [
                        ("Video calls", "< 1%"),
                        ("Online gaming", "< 0.5%"),
                        ("Browsing", "< 3%"),
                    ]
                )
                Divider().padding(.vertical, 12)
                temporaryNote
                    .padding(.bottom, 20)
            }
            .padding(24)
        }
        .frame(minWidth: 400)
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Understanding Your Network Metrics")
                .font(.title2).bold()
            Text("What the numbers mean and when to care")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func metricSection(
        title: String,
        icon: String,
        eli5: String,
        normal: String,
        concern: String,
        useCases: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)

            Text(eli5)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Typical ranges", systemImage: "ruler")
                        .font(.caption).bold()
                        .foregroundColor(.secondary)
                    Text(normal)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 6) {
                    Label("When to act", systemImage: "exclamationmark.circle")
                        .font(.caption).bold()
                        .foregroundColor(.secondary)
                    ForEach(useCases, id: \.0) { useCase, threshold in
                        HStack {
                            Text(useCase)
                                .font(.caption)
                            Spacer()
                            Text(threshold)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            Text(concern)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var temporaryNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Normal temporary fluctuations", systemImage: "info.circle")
                .font(.headline)
            Text("Occasional latency spikes, a brief burst of jitter during a large download, or 1–2 lost packets per hour are all perfectly normal. Networks are shared resources — your neighbour downloading a game or your router running a firmware check can cause momentary blips. Me Or Them turns yellow or red only when problems are sustained, so a single-poll warning usually means nothing.")
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
