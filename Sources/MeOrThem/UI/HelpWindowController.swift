import AppKit
import SwiftUI

final class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private init() {
        let vc = NSHostingController(rootView: HelpView())
        let window = NSWindow(contentViewController: vc)
        window.title = "Me Or Them — Help & Reference"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 820))
        window.minSize = NSSize(width: 480, height: 500)
        window.maxSize = NSSize(width: 1100, height: 1800)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        if !(window?.isVisible ?? false) { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root view

private struct HelpView: View {
    var body: some View {
        TabView {
            MetricsTab()
                .tabItem { Label("Metrics", systemImage: "chart.bar") }
            TestsTab()
                .tabItem { Label("Tests & Probes", systemImage: "antenna.radiowaves.left.and.right") }
            StatusTab()
                .tabItem { Label("Status Logic", systemImage: "cpu") }
            AnalysisTab()
                .tabItem { Label("Analysis Engine", systemImage: "magnifyingglass") }
            ProblemsTab()
                .tabItem { Label("Problems & Fixes", systemImage: "wrench.and.screwdriver") }
        }
        .padding(4)
    }
}

// MARK: - Shared components

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle).font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.bottom, 6)
    }
}

private struct Callout: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).bold()
                Text(message).font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .cornerRadius(10)
    }
}

private struct DesignNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("WHY")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .cornerRadius(4)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct KVRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(key).font(.caption).foregroundColor(.secondary).frame(minWidth: 130, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundColor(.primary)
            Spacer()
        }
    }
}

private struct ProseSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
    }
}

// MARK: - Tab 1: Metrics

private struct MetricsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Network Metrics",
                    subtitle: "What each number measures and when it matters"
                )

                metricBlock(
                    title: "Ping Latency (RTT)",
                    icon: "network",
                    color: .blue,
                    eli5: "Round-trip time — how long a tiny packet takes to travel from your Mac to a server and back. Think of shouting across a room and timing the echo. The lower the number, the more responsive your connection feels.",
                    ranges: [
                        ("< 20 ms", "Excellent — imperceptible"),
                        ("20–50 ms", "Good — suitable for all uses"),
                        ("50–100 ms", "Fair — noticeable in gaming"),
                        ("100–150 ms", "Poor — calls will feel delayed"),
                        ("> 150 ms", "Bad — serious usability impact"),
                    ],
                    thresholds: [
                        ("Yellow alert", "≥ 60 ms"),
                        ("Red alert", "≥ 150 ms"),
                        ("Video calls", "< 150 ms"),
                        ("Online gaming", "< 50 ms"),
                        ("Browsing", "< 300 ms"),
                    ],
                    insight: "A single latency spike is almost always harmless — your router was momentarily busy, or macOS ran an AWDL scan (AirDrop/Handoff). Me Or Them averages readings over a configurable window before changing status, so isolated spikes never trigger alerts."
                )

                Divider()

                metricBlock(
                    title: "Jitter",
                    icon: "waveform.path",
                    color: .orange,
                    eli5: "Jitter measures how consistent your latency is. If RTT is 20 ms one poll and 90 ms the next, jitter is high — even though the average looks fine. In real-time audio and video, packets that arrive out of order cause gaps and choppiness that you can't cover with good average latency.",
                    ranges: [
                        ("< 5 ms", "Excellent"),
                        ("5–15 ms", "Good"),
                        ("15–30 ms", "Fair — calls start to sound rough"),
                        ("30–60 ms", "Poor — perceptible glitches"),
                        ("> 60 ms", "Bad — calls break up"),
                    ],
                    thresholds: [
                        ("Yellow alert", "≥ 30 ms"),
                        ("Red alert", "≥ 80 ms"),
                        ("Video calls", "< 30 ms"),
                        ("Online gaming", "< 15 ms"),
                        ("Browsing", "Not significant"),
                    ],
                    insight: "Brief jitter during a large download is normal — your link is saturated and packets queue. Sustained jitter while idle across multiple polls is the signal to investigate. The 30-second default jitter window specifically filters Apple's AWDL channel scans, which spike jitter every ~60 seconds."
                )

                Divider()

                metricBlock(
                    title: "Packet Loss",
                    icon: "exclamationmark.triangle",
                    color: .red,
                    eli5: "Sometimes packets simply vanish — dropped by an overloaded router, a lossy WiFi link, or a failing cable. Protocols like TCP re-send lost data, but that causes stalls and retransmit delays. Even 1% loss causes visible glitches on video calls and lag spikes in games because every lost packet adds a full round-trip delay waiting for re-transmission.",
                    ranges: [
                        ("0%", "Perfect"),
                        ("< 0.5%", "Acceptable for most uses"),
                        ("0.5–1%", "Marginal — gaming and calls affected"),
                        ("1–3%", "Poor — significant impact"),
                        ("> 3%", "Bad — major degradation"),
                    ],
                    thresholds: [
                        ("Yellow alert", "≥ 1%"),
                        ("Red alert", "≥ 3%"),
                        ("Video calls", "< 1%"),
                        ("Online gaming", "< 0.5%"),
                        ("Browsing / streaming", "< 2%"),
                    ],
                    insight: "Each ping probe sends 3 packets. One lost packet per poll = 33% reported for that poll. Over a 10-second loss window (2 polls at 5s interval), that single drop contributes just 16.7% — below the 1% yellow threshold only if it's genuinely isolated. This design catches sustained loss but ignores transient radio interference."
                )

                Divider()

                metricBlock(
                    title: "DNS Response Time",
                    icon: "globe",
                    color: .teal,
                    eli5: "DNS translates domain names (google.com) into IP addresses your Mac can route to. Every new connection starts with a DNS lookup. Slow DNS makes everything feel sluggish even when your connection is fast — a 500 ms DNS delay adds half a second to every page load before the first byte is transferred.",
                    ranges: [
                        ("< 20 ms", "Excellent"),
                        ("20–80 ms", "Good"),
                        ("80–200 ms", "Fair — noticeable on page loads"),
                        ("200–500 ms", "Poor"),
                        ("> 500 ms / timeout", "Bad / broken"),
                    ],
                    thresholds: [
                        ("Probe timeout", "3 seconds"),
                        ("Elevated latency finding", "≥ 200 ms average"),
                        ("Failure rate finding", "≥ 20% timeouts"),
                        ("Concurrent resolvers", "Up to 8"),
                    ],
                    insight: "Me Or Them probes resolvers using raw UDP, bypassing the macOS DNS cache entirely. The time you see is the actual resolver response time — not a cached result from a previous lookup. Probes run every ~30 seconds across all enabled resolvers simultaneously."
                )

                Divider()

                metricBlock(
                    title: "WiFi Signal Strength (RSSI & SNR)",
                    icon: "wifi",
                    color: .green,
                    eli5: "RSSI (Received Signal Strength Indicator) is measured in dBm — a negative number where closer to 0 is stronger. SNR (Signal-to-Noise Ratio) is the margin between your signal and background radio noise; higher is better. Weak signal causes the radio to fall back to lower data rates, re-transmit frames, and increase effective latency — even while ping looks fine.",
                    ranges: [
                        ("RSSI > -55 dBm", "Excellent — full data rate"),
                        ("−55 to −65 dBm", "Good"),
                        ("−65 to −75 dBm", "Fair — rate fallback likely"),
                        ("−75 to −85 dBm", "Poor — significant impact"),
                        ("< −85 dBm", "Bad — frequent drops"),
                        ("SNR > 25 dB", "Excellent"),
                        ("SNR 15–25 dB", "Adequate"),
                        ("SNR < 10 dB", "Poor — high error rate"),
                    ],
                    thresholds: [
                        ("Weak signal finding", "RSSI < −75 dBm avg"),
                        ("Instability finding", "High RSSI variance"),
                        ("WiFi/latency correlation", "Pearson r < −0.5"),
                    ],
                    insight: "RSSI is sampled via CoreWLAN on every poll tick — not via WiFi event callbacks, which fire on every tiny RSSI fluctuation and caused ~20% CPU in testing. No Location permissions are needed; CoreWLAN provides full WiFi details without them."
                )

                Divider()

                ProseSection(title: "Bandwidth (Download / Upload)", icon: "arrow.up.arrow.down") {
                    Text("Measured on demand via the bundled Ookla Speedtest CLI. The result feeds into the bufferbloat diagnostic: the analysis engine compares your idle RTT baseline against RTT measured while the speed test is saturating your link. A ratio greater than 2× indicates excess queueing in your router.")
                        .font(.body)
                    Callout(icon: "lock.shield", color: .gray,
                            title: "Binary integrity",
                            message: "The speedtest binary is verified against a known code signature before every run. A tampered or substituted binary is rejected — not silently executed.")
                }
            }
            .padding(20)
        }
    }

    private func metricBlock(
        title: String, icon: String, color: Color,
        eli5: String,
        ranges: [(String, String)],
        thresholds: [(String, String)],
        insight: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(eli5).font(.body)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Typical ranges", systemImage: "ruler")
                        .font(.caption).bold().foregroundColor(.secondary)
                    ForEach(ranges, id: \.0) { val, label in
                        HStack(alignment: .top) {
                            Text(val)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minWidth: 90, alignment: .leading)
                            Text(label).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 5) {
                    Label("Thresholds & targets", systemImage: "target")
                        .font(.caption).bold().foregroundColor(.secondary)
                    ForEach(thresholds, id: \.0) { label, val in
                        HStack {
                            Text(label).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(val).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            DesignNote(text: insight)
        }
    }
}

// MARK: - Tab 2: Tests & Probes

private struct TestsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    title: "Tests & Probes",
                    subtitle: "What Me Or Them actually sends, how often, and why"
                )

                ProseSection(title: "ICMP Ping Probes", icon: "dot.radiowaves.left.and.right") {
                    Text("Every poll, Me Or Them spawns one `/sbin/ping` process per configured target running:")
                        .font(.body)
                    Text("ping -c 3 -i 0.2 -t 3 <target>")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "-c 3", value: "3 packets per probe")
                        KVRow(key: "-i 0.2", value: "200 ms between packets → ~450 ms minimum probe time")
                        KVRow(key: "-t 3", value: "3-second total timeout — probe gives up if all 3 are lost")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("From 3 packets, Me Or Them calculates: RTT (average of returned packets), and packet loss (how many of the 3 were not returned). All targets run concurrently — the total probe round takes as long as the slowest target, not the sum of all targets.")
                        .font(.body)
                    DesignNote(text: "3 packets is the minimum to meaningfully detect loss without inflating subprocess duty cycle. At a 5-second poll interval, 3 packets × 200 ms spacing = ~450 ms probe time — 9% of the poll window. 5 packets would be 15%, creating unacceptable subprocess overhead and blurring the line between the probe itself and what it's measuring.")
                    DesignNote(text: "/sbin/ping is used instead of raw ICMP sockets because macOS requires root privilege for raw sockets. /sbin/ping carries the necessary setuid entitlement. Arguments are always passed as an array — never as a shell string — which prevents any possibility of command injection.")
                }

                Divider()

                ProseSection(title: "HTTP / HTTPS Probes", icon: "globe") {
                    Text("Targets configured as HTTP or HTTPS URLs are probed by making a TCP connection and measuring time-to-first-byte. This is useful for monitoring internal endpoints, APIs, or services that block ICMP. Loss is recorded as a timeout if the connection fails or exceeds the probe timeout. HTTP probe times are comparable to ICMP RTT for the same host but will be slightly higher because they include TCP handshake overhead.")
                        .font(.body)
                }

                Divider()

                ProseSection(title: "Gateway Ping (Fault Isolation)", icon: "arrow.triangle.branch") {
                    Text("Every poll also pings your default gateway (router) using the same 3-packet probe. The gateway IP is discovered automatically via the routing table — it is never hardcoded.")
                        .font(.body)
                    Callout(icon: "mappin.and.ellipse", color: .blue,
                            title: "Fault attribution logic",
                            message: "Gateway failing + internet failing → local network or router problem. Gateway fine + internet failing → ISP or upstream problem. Some targets failing, others fine → CDN or routing issue specific to those destinations.")
                    DesignNote(text: "Without a gateway probe, you cannot tell whether a problem is on your LAN or beyond your router. This distinction is the core reason Me Or Them exists — other monitors report that something is wrong but not where.")
                }

                Divider()

                ProseSection(title: "Raw UDP DNS Probing", icon: "network.badge.shield.half.filled") {
                    Text("Every ~30 seconds, Me Or Them sends a wire-format DNS A-record query directly to each enabled resolver's IP address over UDP port 53 — bypassing macOS mDNSResponder and the OS DNS cache entirely.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Probe interval", value: "Every 6th poll tick (~30 s at default 5 s interval)")
                        KVRow(key: "Timeout per probe", value: "3 seconds")
                        KVRow(key: "Concurrent resolvers", value: "Up to 8, probed simultaneously")
                        KVRow(key: "Recorded values", value: "Response time (ms) and DNS rcode")
                        KVRow(key: "Timeout result", value: "nil — resolver unreachable or blocking UDP/53")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("Resolvers that fail repeatedly are automatically paused and re-probed in the background every ~5 minutes. This avoids wasting probe budget on persistently unreachable resolvers without permanently removing them.")
                        .font(.callout).foregroundColor(.secondary)
                    DesignNote(text: "Using getaddrinfo() or URLSession would hit the OS cache and mDNSResponder. The time returned would be cache hit time (often < 1 ms) or the OS resolver's internal latency — not the actual upstream resolver's response time. Raw UDP packets measure what the resolver itself does, which is what matters for diagnosing slow DNS.")
                }

                Divider()

                ProseSection(title: "MTU / Path Fragmentation Probes", icon: "ruler") {
                    Text("Every ~2.5 minutes, MTUChecker sends a single 1472-byte ICMP probe with the Don't-Fragment (DF) bit set:")
                        .font(.body)
                    Text("ping -D -s 1472 -c 1 <gateway>")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    Text("1472 bytes payload + 28 bytes IP/ICMP header = 1500 bytes — the standard Ethernet MTU. If any router on the path has a smaller MTU and cannot fragment the packet (because DF is set), it must silently drop it.")
                        .font(.body)
                    Callout(icon: "exclamationmark.triangle", color: .orange,
                            title: "Why this is insidious",
                            message: "Large-packet failures look completely different from normal packet loss. Small pings succeed, so ping looks fine. But downloads stall, TLS handshakes time out, and video streams buffer. Without a large-packet probe, this fault is invisible to all standard network tools.")
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Probe interval", value: "Every 30th tick, offset by 15 (~150 s at 5 s interval)")
                        KVRow(key: "Payload size", value: "1472 bytes (→ 1500-byte Ethernet frame)")
                        KVRow(key: "DF bit", value: "Set (-D flag) — routers must drop, not fragment")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                Divider()

                ProseSection(title: "Hardware Interface Error Monitoring", icon: "cpu") {
                    Text("Every ~30 seconds, InterfaceMonitor reads the kernel's hardware error and drop counters for the active network interface via ioctl/sysctl — the same counters shown by `netstat -i`.")
                        .font(.body)
                    Text("It records the delta since the last sample (not the cumulative total), storing one row in `interface_error_samples` per interval. The counters tracked are: input errors, output errors, input drops, output drops, and CRC errors.")
                        .font(.body)
                    DesignNote(text: "Cumulative counters grow monotonically from boot and reset on interface reinitialisation. Deltas tell you whether errors are happening right now — a delta of 0 means clean; a non-zero delta means the hardware made an error in the last 30 seconds. Repeated non-zero deltas across several samples are what the analysis engine flags.")
                }

                Divider()

                ProseSection(title: "Automatic Traceroute", icon: "point.3.connected.trianglepath.dotted") {
                    Text("When connection status transitions from green to red, a traceroute is captured automatically:")
                        .font(.body)
                    Text("traceroute -n -q 1 -w 2 -m 20 <first-external-target>")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "-n", value: "No DNS reverse lookups (faster, avoids poisoning DNS measurements)")
                        KVRow(key: "-q 1", value: "One probe per hop (fast)")
                        KVRow(key: "-w 2", value: "2-second timeout per hop")
                        KVRow(key: "-m 20", value: "Maximum 20 hops")
                        KVRow(key: "Rate limit", value: "At most once per 5 minutes")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("Results are stored in the `traceroute_events` table and surfaced in Network Analysis with the highest-latency hop highlighted and the full hop-by-hop output expandable for copying into a support ticket.")
                        .font(.callout).foregroundColor(.secondary)
                    DesignNote(text: "Traceroute is rate-limited to once per 5 minutes because it generates dozens of ICMP packets per run. Firing on every red poll would flood your network during an already-degraded incident.")
                }

                Divider()

                ProseSection(title: "ISP Identification", icon: "building.2") {
                    Text("When a new network session opens, Me Or Them queries the Cymru IP-to-ASN service to identify your ISP or network operator from your WAN IP. The result is stored with the session record and shown in Connection Profiles. No account or registration is required — Cymru provides this as a free DNS-based public service.")
                        .font(.body)
                }

                Divider()

                ProseSection(title: "CPU Sampling", icon: "gauge") {
                    Text("CPUSampler calls `host_statistics()` once at the start of each poll tick to record overall system CPU load. This reading is used to display a \"High system load\" advisory in the dropdown when load exceeds 75% during a degraded period — elevated CPU can delay ping process scheduling and inflate RTT and loss readings, giving a false picture of network health.")
                        .font(.body)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tab 3: Status Logic

private struct StatusTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    title: "How Status Is Calculated",
                    subtitle: "The complete pipeline from raw poll to green / yellow / red"
                )

                ProseSection(title: "Step 1 — Evaluation Windows", icon: "slider.horizontal.3") {
                    Text("Raw poll readings are not compared to thresholds directly. Instead, each metric is averaged over its own configurable window before any status decision is made.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Latency window", value: "Default 15 s — RTT average over the last N polls")
                        KVRow(key: "Loss window", value: "Default 10 s — packet loss average over the last N polls")
                        KVRow(key: "Jitter window", value: "Default 30 s — jitter average over the last N polls")
                        KVRow(key: "Window floor", value: "Always ≥ pollIntervalSecs (prevents divide-by-zero)")
                        KVRow(key: "Sample count N", value: "max(1, ceil(windowSecs ÷ pollIntervalSecs))")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Callout(icon: "info.circle", color: .blue,
                            title: "Worked example",
                            message: "At 5 s poll interval with the 10 s loss window, N = 2 polls. One poll with 33% loss (1 of 3 packets) contributes 33% ÷ 2 = 16.5% to the window average — still above the 1% yellow threshold, so it does fire. But a single AWDL spike with 0% loss after it dilutes the average back below threshold instantly.")
                    DesignNote(text: "The 30-second jitter window specifically guards against Apple AWDL channel scans (used by AirDrop, Handoff, Sidecar), which cause a jitter spike every ~60 seconds on 2.4 GHz. A 30-second window absorbs one spike without status change. A 10-second window would not.")
                }

                Divider()

                ProseSection(title: "Step 2 — Per-Target Status", icon: "circle.fill") {
                    Text("After windowing, each target's averaged metrics are compared against its configured thresholds. Targets with custom threshold overrides (Settings → Targets) are evaluated against those overrides. All others use the global thresholds.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Latency yellow", value: "≥ 60 ms")
                        KVRow(key: "Latency red", value: "≥ 150 ms")
                        KVRow(key: "Loss yellow", value: "≥ 1%")
                        KVRow(key: "Loss red", value: "≥ 3%")
                        KVRow(key: "Jitter yellow", value: "≥ 30 ms")
                        KVRow(key: "Jitter red", value: "≥ 80 ms")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("A target's status is the worst of its three metric statuses. A target with green latency and loss but yellow jitter is yellow overall.")
                        .font(.callout).foregroundColor(.secondary)
                }

                Divider()

                ProseSection(title: "Step 3 — Trimmed Mean Across Targets", icon: "chart.bar.xaxis") {
                    Text("With 3 or more non-gateway, non-override targets, the best and worst single-target metric readings are discarded before computing the overall status. The remaining readings are averaged.")
                        .font(.body)
                    Callout(icon: "checkmark.circle", color: .green,
                            title: "What this prevents",
                            message: "A CDN that is consistently slow for your region cannot push overall status to yellow on its own. An unreachable target cannot inflate loss to 100%. Status reflects your actual network experience across the majority of targets.")
                    Text("Targets with custom threshold overrides are excluded from the trimmed mean and evaluated independently. Their status is OR'd with the trimmed mean result — either can drive the overall status.")
                        .font(.callout).foregroundColor(.secondary)
                    DesignNote(text: "Trimmed mean is a standard statistical technique for reducing the influence of outliers. In a monitoring context: the worst-performing target is almost always a CDN/routing issue, not your ISP. The best-performing target is often a co-located server on your ISP's network that doesn't reflect real-world external connectivity.")
                }

                Divider()

                ProseSection(title: "Step 4 — Overall Status Rules", icon: "flag.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        statusRule("1", "Compute windowed averages for all targets.")
                        statusRule("2", "For non-override targets with 3+: apply trimmed mean per metric.")
                        statusRule("3", "Take worst override-target status independently.")
                        statusRule("4", "Take worst of gateway, trimmed mean, and override results.")
                        statusRule("5", "If gateway ping fails: status cannot be green regardless of other targets.")
                        statusRule("6", "Resulting status is green, yellow, or red.")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("There is no hysteresis beyond the evaluation window. When the windowed average crosses a threshold, status changes immediately. The window itself is the debounce mechanism — no additional delay or hysteresis is layered on top.")
                        .font(.callout).foregroundColor(.secondary)
                }

                Divider()

                ProseSection(title: "Step 5 — Transition Detection & Incidents", icon: "calendar.badge.clock") {
                    Text("Every poll, the new overall status is compared to the previous poll's status:")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 6) {
                        transitionRow("Green → Yellow/Red", "Opens a new connection event. Records timestamp, severity, and the specific metrics that triggered it (e.g. \"high latency (185 ms), packet loss (4.2%)\").")
                        transitionRow("Yellow/Red → Green", "Closes the open event. Records recovery time. Sets the transient Recovered banner for one poll interval.")
                        transitionRow("Yellow ↔ Red", "Updates the open event's peak severity without creating a new event.")
                        transitionRow("No change", "No action — the existing event (if any) remains open.")
                    }
                    Text("Up to 20 events are kept in memory for menu display. All events are persisted to SQLite for the full configured incident retention period (default: 365 days).")
                        .font(.callout).foregroundColor(.secondary)
                    DesignNote(text: "Recording severity transitions in-place (rather than creating a new event) means Incident History shows one contiguous event for a fault that worsens and then recovers, rather than three fragmented events. This matches how a human would describe the incident.")
                }

                Divider()

                ProseSection(title: "Adaptive Polling", icon: "speedometer") {
                    Text("Polling frequency increases automatically during active problems to provide higher-resolution data exactly when it matters.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Normal rate", value: "Configured interval (default 5 s, range 2–30 s)")
                        KVRow(key: "Trigger", value: "2 consecutive red polls")
                        KVRow(key: "Fast rate", value: "baseInterval ÷ 2 (minimum 2 s floor)")
                        KVRow(key: "Restore trigger", value: "3 consecutive green polls at the fast rate")
                        KVRow(key: "Restore", value: "Returns to configured interval silently")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    DesignNote(text: "Adaptive polling triggers only on red, not yellow. Yellow status is common and often transient — triggering speed-up on yellow would double polling frequency during normal congestion events, burning unnecessary CPU and subprocess budget. Red means something is actively broken and the extra resolution is warranted.")
                }

                Divider()

                ProseSection(title: "Network Session Fingerprinting", icon: "person.crop.rectangle") {
                    Text("Me Or Them automatically tracks which network you're connected to without requiring Location permissions. A fingerprint is derived from:")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Gateway IP", value: "Your router's LAN address")
                        KVRow(key: "WiFi channel", value: "The 802.11 channel number")
                        KVRow(key: "WiFi band", value: "2.4 GHz vs. 5 GHz vs. 6 GHz")
                        KVRow(key: "Subnet /24", value: "First three octets of your IP address")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("A fingerprint change opens a new `network_sessions` row. The same fingerprint extends the existing session via `last_seen`. Each ping sample carries a `session_id` foreign key, so the analysis engine always draws per-network conclusions from that network's own data.")
                        .font(.callout).foregroundColor(.secondary)
                    DesignNote(text: "The /24 subnet rather than exact IP is deliberate: DHCP can assign a different IP within the same subnet on reconnection. Using the exact IP would create spurious new sessions after every DHCP renewal on the same network.")
                }

                Divider()

                ProseSection(title: "Stability Score", icon: "star.fill") {
                    Text("Each session earns a 0–100 score and an A–F letter grade computed from four weighted components:")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Availability (40 pts)", value: "Fraction of time without an active incident")
                        KVRow(key: "Latency (25 pts)", value: "25 pts <20 ms · 21 pts <50 ms · 17 pts <100 ms · 12 pts <150 ms · 7 pts <200 ms · 0 pts ≥200 ms")
                        KVRow(key: "Packet loss (25 pts)", value: "25 pts <0.1% · 21 pts <0.5% · 16 pts <1% · 10 pts <2% · 5 pts <5% · 0 pts ≥5%")
                        KVRow(key: "Jitter (10 pts)", value: "10 pts <5 ms · 8 pts <15 ms · 6 pts <30 ms · 3 pts <50 ms · 0 pts ≥50 ms")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Grade A", value: "90–100 pts — excellent")
                        KVRow(key: "Grade B", value: "75–89 pts — mostly good")
                        KVRow(key: "Grade C", value: "60–74 pts — noticeable degradation")
                        KVRow(key: "Grade D", value: "40–59 pts — significant problems")
                        KVRow(key: "Grade F", value: "0–39 pts — severe or persistent issues")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    DesignNote(text: "Availability carries the most weight (40%) because a network that is fast but frequently down is worse for productivity than one that is slow but always up. Jitter carries the least (10%) because it primarily affects real-time audio/video — important, but less universally impactful than loss or latency.")
                }

                Divider()

                ProseSection(title: "Data Storage", icon: "internaldrive") {
                    Text("All data is stored locally in a SQLite database using WAL (Write-Ahead Logging) mode, which allows concurrent reads without blocking writes. All I/O is serialised on a private background queue.")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "ping_samples", value: "Raw samples — default 7-day retention")
                        KVRow(key: "wifi_samples", value: "WiFi snapshots — default 7-day retention")
                        KVRow(key: "dns_resolver_samples", value: "Per-resolver probe results")
                        KVRow(key: "ping_aggregates", value: "Per-minute roll-ups — default 90-day retention")
                        KVRow(key: "incidents", value: "Degradation event journal — default 365-day retention")
                        KVRow(key: "network_sessions", value: "One row per network fingerprint epoch, open-ended")
                        KVRow(key: "interface_error_samples", value: "~30 s cadence")
                        KVRow(key: "mtu_samples", value: "~2.5 min cadence")
                        KVRow(key: "traceroute_events", value: "Captured on green→red transitions, ≤ once per 5 min")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Text("Maintenance runs at launch and hourly: raw samples that exceed their retention window are aggregated into per-minute rows in `ping_aggregates`, then pruned. Charts automatically switch from raw to aggregate data for time windows beyond 24 hours.")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
    }

    private func statusRule(_ num: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor)
                .cornerRadius(9)
            Text(desc).font(.callout)
            Spacer()
        }
    }

    private func transitionRow(_ transition: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transition).font(.caption).bold().foregroundColor(.accentColor)
            Text(description).font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Tab 4: Analysis Engine

private struct AnalysisTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    title: "Network Analysis Engine",
                    subtitle: "How Me Or Them diagnoses problems rather than just reporting them"
                )

                ProseSection(title: "Overview", icon: "magnifyingglass") {
                    Text("The Network Analysis engine reviews a network session against 17 diagnostic patterns. It runs as a detached background task — not on the main thread — and is triggered when you open a session in the Network Intelligence window. It does not run continuously during monitoring.")
                        .font(.body)
                    Text("Every finding is scored using a confidence multiplier. Findings below 40% confidence are silently suppressed. The remainder are sorted by confidence descending and presented with a High / Medium / Low badge.")
                        .font(.body)
                }

                Divider()

                ProseSection(title: "Data Sufficiency", icon: "chart.bar.doc.horizontal") {
                    Text("Before any pattern is scored, the engine calculates how much data is available for the selected session. The sample count scales the confidence of every finding:")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 4) {
                        KVRow(key: "Insufficient (< 30 samples)", value: "Multiplier 0.0 — no findings surfaced")
                        KVRow(key: "Limited (30–119 samples)", value: "Multiplier 0.5 — confidence halved")
                        KVRow(key: "Adequate (120–359 samples)", value: "Multiplier 0.8 — slight reduction")
                        KVRow(key: "Strong (≥ 360 samples)", value: "Multiplier 1.0 — full confidence")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Callout(icon: "exclamationmark.triangle", color: .orange,
                            title: "Short sessions",
                            message: "A 2-minute session at 5s poll interval produces ~24 samples — insufficient. This is intentional: a single spike in 2 minutes does not justify a finding. Open longer sessions or wait for more data to accumulate before running analysis.")
                    DesignNote(text: "Data sufficiency multipliers prevent the analysis engine from producing high-confidence findings from statistically thin evidence. A finding that would be 80% confident given 500 samples is reported as 40% given 60 samples — Medium instead of High — because 60 samples genuinely cannot support 80% confidence.")
                }

                Divider()

                Text("The 17 Diagnostic Patterns")
                    .font(.headline)
                    .padding(.top, 4)

                patternBlock(
                    number: "1",
                    title: "Elevated Latency",
                    color: .blue,
                    description: "Average RTT compared to the yellow and red thresholds. Gateway attribution applied: if gateway RTT is also elevated, the finding is labelled local network cause; if gateway is fine, ISP or routing cause. Peak-hour breakdown adds to confidence if most high-latency samples cluster in a narrow time window."
                )

                patternBlock(
                    number: "2",
                    title: "Packet Loss — Burst vs. Steady",
                    color: .red,
                    description: "Determines whether loss is concentrated in a short burst (transient congestion event, or local radio interference) versus distributed evenly across the session (persistent fault). Burst loss with a fine gateway suggests transient external congestion. Steady loss with gateway attribution narrows the fault side."
                )

                patternBlock(
                    number: "3",
                    title: "Jitter — Congestion vs. Instability",
                    color: .orange,
                    description: "Inter-poll variance (how much RTT changes between consecutive polls) is compared to absolute jitter. Variance that spikes only during high-throughput periods suggests congestion. Uniform high variance throughout the session at all times suggests a physically unstable link."
                )

                patternBlock(
                    number: "4",
                    title: "Weak WiFi Signal",
                    color: .yellow,
                    description: "Fires when average RSSI falls below −75 dBm. Confidence scales with the depth below threshold and the consistency of readings across the session. Low RSSI causes the radio to fall back to lower modulation rates and retransmit frames, increasing effective latency and loss even when ping is fine."
                )

                patternBlock(
                    number: "5",
                    title: "WiFi Signal Instability",
                    color: .yellow,
                    description: "Fires when RSSI variance is high across the session, even if the average signal is acceptable. High variance indicates the device is at the edge of AP range, there is significant RF interference, or the AP is being overwhelmed by concurrent clients."
                )

                patternBlock(
                    number: "6",
                    title: "Session Fault Profile — Local vs. ISP",
                    color: .blue,
                    description: "Bins every minute of the session as local, ISP, or clean based on the fault attribution at that time. The ratio of local-attributed to ISP-attributed degraded minutes produces a session-level verdict: \"This session was mostly a local network problem\" or \"mostly ISP.\" Confidence scales with the ratio's strength."
                )

                patternBlock(
                    number: "7",
                    title: "WiFi–Latency Pearson Correlation",
                    color: .blue,
                    description: "Computes the Pearson correlation coefficient between RSSI samples and concurrent RTT readings. A strong negative correlation (r < −0.5, meaning lower signal consistently maps to higher latency) confirms WiFi signal quality as the root cause of latency problems, rather than ISP or server-side factors."
                )

                patternBlock(
                    number: "8",
                    title: "Per-Target Outlier Detection",
                    color: .orange,
                    description: "Computes average RTT per target and compares each against the session mean. A target showing 2.5× or more the mean RTT is flagged as an outlier. This pattern distinguishes a routing or CDN issue specific to one destination from a broad connection problem."
                )

                patternBlock(
                    number: "9",
                    title: "Bufferbloat",
                    color: .red,
                    description: "Compares idle RTT baseline (sampled during quiet periods) against RTT captured during a bandwidth speed test. A ratio > 2.0 (load RTT is more than double idle RTT) indicates bufferbloat — your router's buffer is so large that packets queue for hundreds of milliseconds under load. Recommends SQM/FQ-CoDel when confirmed. Requires at least one completed bandwidth test."
                )

                patternBlock(
                    number: "10a–10e",
                    title: "DNS Multi-Resolver Analysis (5 patterns)",
                    color: .teal,
                    description: "Five independent DNS patterns:\n\n10a. Failure rate — fraction of probes that timed out across resolvers.\n\n10b. Elevated latency — average response time above 200 ms.\n\n10c. Resolver divergence — one resolver consistently slower or less reliable than the others; recommends switching.\n\n10d. All resolvers failing — every configured resolver times out; no DNS resolution possible.\n\n10e. Port 53 blocking — all resolvers fail including Cloudflare and Google, but gateway ping succeeds; UDP port 53 is likely filtered by the network (common on hotel, airport, and corporate WiFi)."
                )

                patternBlock(
                    number: "11",
                    title: "Hardware Interface Error Deltas",
                    color: .orange,
                    description: "Repeated non-zero hardware counter deltas across multiple 30-second samples. Distinguishes RF interference on WiFi (where errors correlate with signal variance) from cable or switch faults on Ethernet (where errors are independent of signal)."
                )

                patternBlock(
                    number: "12",
                    title: "MTU / Path Fragmentation",
                    color: .red,
                    description: "When the majority of 1472-byte Don't-Fragment probes fail while normal small-packet pings succeed, something on the path is silently dropping oversized packets. The confidence scales with the fraction of MTU probe failures over the session."
                )

                patternBlock(
                    number: "13",
                    title: "Latency Trend (OLS Regression)",
                    color: .green,
                    description: "Runs ordinary least-squares linear regression on the RTT time series for the session. If the slope exceeds 0.3 ms/minute and the coefficient of determination R² exceeds 0.5 (i.e. RTT is genuinely drifting upward, not just noisy), the finding fires. Indicates thermal throttling in the network path, gradual buffer saturation, or slowly building background congestion."
                )

                patternBlock(
                    number: "14",
                    title: "WiFi Channel Switching",
                    color: .purple,
                    description: "Detects changes in the 802.11 channel across WiFi samples. Repeated channel changes indicate the access point is detecting RF interference and self-healing by moving. Band switches (2.4 ↔ 5 GHz or ↔ 6 GHz) are called out separately because they cause larger disruption than same-band channel hops."
                )

                patternBlock(
                    number: "15",
                    title: "Time-of-Day Congestion (Cross-Session)",
                    color: .blue,
                    description: "Queries 30 days of per-hour aggregate history. If the current session's elevated latency correlates with a pattern of consistently high average RTT at the same hours of day across many past sessions, the finding fires with a confidence that scales with the number of corroborating historical sessions. Consistent with ISP contention during peak hours."
                )

                patternBlock(
                    number: "16",
                    title: "Automatic Traceroute Snapshot",
                    color: .orange,
                    description: "When a traceroute was auto-captured during a green→red transition in the session window, the analysis surfaces it as a finding. The highest-latency hop and total hop count are shown in the finding card. The full hop-by-hop output is expandable and selectable for copying into a support ticket."
                )
            }
            .padding(20)
        }
    }

    private func patternBlock(number: String, title: String, color: Color, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(number)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(color)
                    .frame(width: 36, alignment: .leading)
                Text(title).font(.subheadline).bold()
            }
            Text(description)
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.leading, 46)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Tab 5: Problems & Fixes

private struct ProblemsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    title: "Problems & What To Do",
                    subtitle: "Matching what Me Or Them shows to the correct remediation"
                )

                problemBlock(
                    title: "Local Network / Router",
                    icon: "house.fill",
                    color: .red,
                    trigger: "Dropdown shows \"Local network / router\". Gateway ping is failing or very high latency. All external targets also fail.",
                    causes: "Router overloaded or crashed, WiFi connection dropped, LAN cable fault, DHCP lease expiry, ISP modem/ONT issue.",
                    actions: [
                        "Restart your router — power off for 30 seconds, then back on. Wait 90 seconds for full boot.",
                        "Check WiFi signal in the Me Or Them dropdown. RSSI below −75 dBm means you are too far from the AP.",
                        "Try switching to a wired Ethernet connection to rule out WiFi as the cause.",
                        "Check the router admin page (usually 192.168.1.1 or 10.0.0.1) for error logs or high CPU.",
                        "If on a modem+router: try rebooting the modem first, then the router.",
                    ]
                )

                problemBlock(
                    title: "ISP / Internet Outage",
                    icon: "antenna.radiowaves.left.and.right.slash",
                    color: .red,
                    trigger: "Dropdown shows \"ISP / internet outage\". Gateway responds quickly. All external targets fail or have very high latency.",
                    causes: "ISP infrastructure failure, upstream routing issue, DNS failure (see DNS section below), BGP route withdrawal.",
                    actions: [
                        "Check your ISP's status page or outage map. Twitter/X often has real-time outage reports by area.",
                        "Try switching DNS to Cloudflare (1.1.1.1) in Settings → DNS Resolvers — a DNS failure can look like a full outage.",
                        "Test with a different DNS: run `nslookup google.com 1.1.1.1` in Terminal. If that works but normal browsing doesn't, it is DNS.",
                        "If this happens at the same time of day regularly: the Analysis Engine's Time-of-Day Congestion pattern will confirm ISP peak-hour contention. Contact your ISP.",
                    ]
                )

                problemBlock(
                    title: "Weak or Unstable WiFi Signal",
                    icon: "wifi.exclamationmark",
                    color: .orange,
                    trigger: "Analysis shows \"Weak WiFi signal\" or \"WiFi signal instability\" finding. RSSI below −75 dBm or high RSSI variance in the dropdown.",
                    causes: "Distance from access point, physical obstructions (concrete walls, appliances), RF interference (other APs, microwaves, Bluetooth), too many clients on the same AP.",
                    actions: [
                        "Move closer to the access point. RSSI should reach −65 dBm or better for good performance.",
                        "Switch to the 5 GHz band — shorter range but far less congested than 2.4 GHz in most homes.",
                        "Check the current WiFi channel in Me Or Them's dropdown. In the 2.4 GHz band, use only channels 1, 6, or 11 to avoid overlap with neighbours.",
                        "If WiFi Channel Switching is flagged in Analysis, your AP is experiencing RF interference. Consider a mesh AP or a wired Ethernet run to a better location.",
                        "Disable or move away from sources of 2.4 GHz interference: microwave ovens, Bluetooth devices, wireless cameras, baby monitors.",
                    ]
                )

                problemBlock(
                    title: "High Jitter",
                    icon: "waveform.path",
                    color: .orange,
                    trigger: "Jitter reading above 30 ms at rest (not during a bandwidth test). Calls sound choppy. Video frames drop despite adequate average latency.",
                    causes: "WiFi signal instability, shared network saturation, router buffer too small or too large, ISP link congestion.",
                    actions: [
                        "Check whether jitter correlates with WiFi signal changes — the Analysis Engine's WiFi–Latency Correlation pattern will confirm or rule this out.",
                        "If jitter spikes only during downloads: this is normal (link saturation). Enable SQM/FQ-CoDel on your router — see Bufferbloat below.",
                        "If jitter is high even when idle: focus on WiFi signal quality first, then check if other devices on the network are causing congestion.",
                        "Verify other devices are not running large background syncs (iCloud, Time Machine, Windows Update) during calls.",
                    ]
                )

                problemBlock(
                    title: "Bufferbloat",
                    icon: "square.stack.3d.up",
                    color: .red,
                    trigger: "Analysis shows a Bufferbloat finding. Latency spikes during downloads or uploads. RTT doubles or triples when the link is saturated.",
                    causes: "Router buffer sized too large. Under load, packets queue in the buffer for hundreds of milliseconds before being sent. TCP flow control cannot compensate fast enough.",
                    actions: [
                        "Enable SQM (Smart Queue Management) on your router. Look for QoS, FQ-CoDel, or CAKE in router settings. OpenWrt and DD-WRT support this natively.",
                        "If your ISP router does not support SQM: place a second router running OpenWrt behind it and enable SQM there.",
                        "As a short-term workaround: cap your router's upload speed to slightly below your actual upload speed. This prevents the upload buffer from overwhelming your download path.",
                        "Consider a router with built-in AQM: Eero, Firewalla, Untangle, or any OpenWrt-compatible device.",
                    ]
                )

                problemBlock(
                    title: "DNS Problems",
                    icon: "globe.badge.chevron.backward",
                    color: .teal,
                    trigger: "DNS response time above 200 ms. DNS failure rate finding. Browsing feels slow even when ping is fine. Sites fail to load but IP addresses work.",
                    causes: "Slow ISP resolver, resolver unreachable, UDP port 53 blocked by network, DNS hijacking by router or ISP.",
                    actions: [
                        "Enable Cloudflare (1.1.1.1) or Google (8.8.8.8) in Settings → DNS Resolvers. These are generally faster and more reliable than ISP default resolvers.",
                        "If all resolvers are failing (pattern 10d) and you are on hotel, airport, or corporate WiFi: UDP port 53 is likely blocked. The network may require you to connect through a captive portal first.",
                        "If DNS Resolver Divergence is flagged (pattern 10c): switch to the faster resolver shown in the dropdown's DNS row.",
                        "If multiple resolvers return the same unexpected answer: your ISP or router may be intercepting DNS queries (DNS hijacking). Use a DNS-over-HTTPS or DNS-over-TLS client such as NextDNS or Cloudflare's 1.1.1.1 for iOS.",
                        "Disable DNS rebind protection on your router if local addresses are being blocked.",
                    ]
                )

                problemBlock(
                    title: "MTU / Path Fragmentation",
                    icon: "ruler",
                    color: .red,
                    trigger: "Analysis shows MTU/path fragmentation finding. Large downloads stall. HTTPS connections are slow to establish or time out. Ping looks clean.",
                    causes: "VPN tunnel with too-small MTU, PPPoE DSL overhead, misconfigured firewall blocking large ICMP packets, corporate middlebox.",
                    actions: [
                        "If on a VPN: reduce the VPN tunnel MTU. Common values — WireGuard: 1420, OpenVPN: 1400, IPsec: 1350. Check your VPN client's advanced settings.",
                        "If on PPPoE DSL: enable MSS clamping in your router's WAN settings. Set the MSS clamp value to 1452 or lower.",
                        "Try lowering your router's WAN MTU setting from 1500 to 1492 or 1480 and test whether large downloads recover.",
                        "Contact your ISP if reducing MTU resolves the symptom — they may have a misconfigured middlebox.",
                    ]
                )

                problemBlock(
                    title: "Hardware Interface Errors",
                    icon: "cpu",
                    color: .orange,
                    trigger: "Analysis shows Hardware interface errors finding. Non-zero error or drop deltas appearing every ~30 seconds.",
                    causes: "On WiFi: RF interference, failing adapter. On Ethernet: faulty cable, bad switch port, failing NIC.",
                    actions: [
                        "On WiFi: try a different WiFi channel. In the 2.4 GHz band use only channels 1, 6, or 11. Error deltas that drop to zero after a channel change confirm RF interference.",
                        "On Ethernet: swap the cable. If errors stop, the cable was faulty.",
                        "If errors persist after cable swap: try a different switch port. If errors stop, the port was failing.",
                        "Persistent errors on Ethernet despite cable and port changes may indicate a failing NIC. Try a USB-to-Ethernet adapter to test an alternative interface.",
                    ]
                )

                problemBlock(
                    title: "Captive Portal (Hotel / Airport WiFi)",
                    icon: "lock.icloud",
                    color: .yellow,
                    trigger: "Connected to WiFi but no internet access. Me Or Them may show all external targets failing while gateway is reachable. A captive portal login page has not yet been completed.",
                    causes: "Network requires browser-based authentication before granting internet access.",
                    actions: [
                        "Open any http:// URL (not https://) in a browser — the captive portal redirect usually requires HTTP. Try http://neverssl.com.",
                        "If the portal page doesn't appear: go to System Settings → Wi-Fi → the connected network → and look for an \"Open Network Preferences\" or \"Join Network\" prompt.",
                        "Once authenticated, Me Or Them will detect connectivity restored on the next poll and update status.",
                    ]
                )

                Divider()

                ProseSection(title: "Exports & External Integration", icon: "square.and.arrow.up") {
                    VStack(alignment: .leading, spacing: 6) {
                        exportRow("CSV (gzip)", "All raw samples with timestamps. For spreadsheet analysis or importing into custom tools.")
                        exportRow("JSON (gzip)", "Full history including session metadata and all resolver samples. For scripting, custom dashboards, or data pipelines.")
                        exportRow("PDF report", "Formatted diagnostic summary with charts and incident history. For ISP support tickets or employer documentation.")
                        exportRow("Daily CSV log", "Continuous append at ~/Library/Logs/MeOrThem/. Opt in via Settings → General. For long-running log aggregation.")
                        exportRow("Prometheus / JSON endpoint", "Optional local HTTP server on port 9090. Exposes live metrics for scraping by Grafana, custom scripts, or any OpenMetrics-compatible collector. Disabled by default; enable in Settings → Advanced. Binds to 127.0.0.1 only — no authentication.")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    Callout(icon: "exclamationmark.shield", color: .orange,
                            title: "Metrics endpoint security notice",
                            message: "When the local metrics server is enabled, any process on your Mac can query it without authentication. The metrics include your configured target hostnames, resolver IPs, and network session fingerprints. Do not port-forward or proxy this port to an untrusted network.")
                }

                Divider()

                ProseSection(title: "Apple Shortcuts & Automation", icon: "arrow.triangle.2.circlepath") {
                    Text("Me Or Them exposes four actions to macOS Shortcuts and compatible automation tools:")
                        .font(.body)
                    VStack(alignment: .leading, spacing: 5) {
                        shortcutRow("Get Network Status", "Returns current overall status, RTT, loss, jitter, and DNS response time.")
                        shortcutRow("Run Bandwidth Test", "Triggers the Ookla speed test and returns download/upload speeds and ping.")
                        shortcutRow("Get Last Incident", "Returns the most recent degradation event: start time, cause, severity, and duration.")
                        shortcutRow("Export Network Report", "Generates and saves a report in the chosen format (CSV, JSON, or PDF).")
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            .padding(20)
        }
    }

    private func problemBlock(
        title: String, icon: String, color: Color,
        trigger: String, causes: String, actions: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("WHEN YOU SEE THIS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Text(trigger).font(.callout)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("COMMON CAUSES")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Text(causes).font(.callout).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT TO DO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(color)
                            .frame(width: 18, alignment: .trailing)
                        Text(action).font(.callout)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func exportRow(_ format: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(format)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 140, alignment: .leading)
            Text(description).font(.caption).foregroundColor(.secondary)
        }
    }

    private func shortcutRow(_ action: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action).font(.caption).bold()
            Text(description).font(.caption).foregroundColor(.secondary)
        }
    }
}
