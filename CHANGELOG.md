# Changelog

All notable user-facing changes to Me Or Them, most recent first.
Website, scripts, and internal tooling changes are not listed here.

---

## v2.50.0 — 2026-04-29

### New Features
- **Latency p95 reference line** — The latency chart now shows a purple dashed "p95" line when at least 20 samples are available for the selected window. The line represents the 95th-percentile round-trip time across visible targets, making tail latency spikes visible even when the mean looks healthy.

---

## v2.49.0 — 2026-04-29

### New Features
- **Incident notes** — Each recorded incident can now have a free-text annotation. Expand any incident row in the Incidents tab to find a "Note" field where you can write context (e.g. "ISP maintenance window" or "router rebooted"). Notes are saved to the database and persist across sessions. A note icon appears on collapsed rows that have an annotation.

---

## v2.48.0 — 2026-04-29

### New Features
- **Bandwidth test quiet hours** — Automatic bandwidth tests can now be suppressed during a configurable time window (e.g. 9 AM to 5 PM). Configure it in Settings → Bandwidth Test → Quiet hours. Tests scheduled to fire inside the window are skipped and run at the next interval; no queuing or backlog occurs.

---

## v2.47.0 — 2026-04-29

### New Features
- **Captive portal detection** — Me Or Them now probes for captive portals (hotel, airport, coffee-shop Wi-Fi login pages) each time a new network session opens. Detection uses a single HTTP check against a known endpoint — zero steady-state overhead. When a portal is found, a notification fires immediately and a "⚠ Captive portal — browser login required" warning appears in the Network Details submenu.

---

## v2.46.0 — 2026-04-29

### New Features
- **Recovery notifications** — Me Or Them now sends a notification when the connection returns to normal after a degraded period. The notification includes the outage duration (e.g. "Connection restored after 3m 42s"), giving you a complete picture of the incident without opening the app.

### Changes
- **Fault attribution in degradation alerts** — Degradation notifications now include a plain-English cause derived from gateway vs. external-target analysis. For example, "Likely cause: ISP / internet outage" or "Likely cause: local network / router", replacing the previous generic message.

---

## v2.45.0 — 2026-04-29

### New Features
- **Network profile labels** — You can now assign a custom name (e.g. "Home", "Office") to any connection profile in the Profiles tab. The label replaces the auto-generated technical name throughout the sidebar and profile list. Labels can be edited or cleared at any time, and profiles can now also be deleted from the list.

### Changes
- **Incident details expand inline** — Clicking the chevron on an incident row now expands it in place to show the full cause text, precise start/end timestamps, severity level, and duration. This replaces the previous "View" button that only switched to the Graphs tab without context.
- **Target picker moved into Graphs tab** — The ping-target filter menu is no longer injected into the shared window toolbar (where it appeared for all tabs). It now lives inside the Graphs view itself, visible only when that tab is active.

### Bug Fixes
- **VPN false positive in Analysis** — The "VPN Active" finding was shown for WiFi sessions whenever a VPN tunnel happened to be running when the session opened. It is now only surfaced for sessions whose connection type is explicitly VPN.
- **0% uptime on historical sessions** — The uptime percentage displayed next to the session date range in the graphs toolbar has been removed for session-scoped views. It was computed from an incomplete sample set for most historical sessions and was systematically misleading.

---

## v2.44.1 — 2026-04-28

### Changes
- **Network Intelligence window redesign** — Replaced the narrow sidebar-with-dropdown layout with a standard macOS source-list + segmented-tab design. Sessions are now listed directly in a scrollable sidebar (grouped by date) rather than hidden behind a dropdown menu that cropped long network names. The four view tabs (Graphs, Analysis, Profiles, Incidents) move to a segmented control at the top of the content area.
- **Session list grouped by date** — The session browser in both the Network Intelligence window and the Network Analysis window now groups entries under "Today", "Yesterday", and older date headers, reducing visual noise when many sessions are recorded on the same day.

### Bug Fixes
- **Incidents shown as ACTIVE / ongoing** — Fixed two bugs that left `ended_at` unset in the database for the majority of recorded incidents. Severity transitions (e.g. yellow→red) were closing the previous incident in memory but not writing the close to the database. Additionally, the startup repair pass only healed the 20 most-recent open incidents; all older ones remained permanently unclosed. Both paths are now correct: every transition writes the close immediately, and a single pass at launch closes any incidents left open by a previous session.

---

## v2.44.0 — 2026-04-27

### New Features
- **Network Intelligence window** — Replaces the four separate Advanced menu windows (Graphs, Network Analysis, Incident History, Connection Profiles) with a unified tabbed window. A profile dropdown at the top selects which network session to review (defaults to the currently active connection, labelled "Active"). Selecting a session filters the Graphs and Network Analysis tabs to that session's time range.

### Changes
- **Connection Profiles: Type column** — The "Stealth" column has been renamed to "Type". It now shows "ICMP (Ping)" or "Stealth (RAW)" badges instead of the previous "TCP"/"ICMP" labels, making the probe mode immediately clear.

### Bug Fixes
- **Spurious Ethernet sessions** — Fixed a startup race where an Ethernet session was created in the database before the WiFi snapshot arrived, producing orphan "Ethernet ?.?.?.x" entries in the sessions list. Session creation is now debounced by 3 seconds; if WiFi is detected within that window the Ethernet session is never written.

---

## v2.43.0 — 2026-04-27

### New Features
- **Shortcuts / Automation integration** — Me Or Them now exposes four actions to macOS Shortcuts (and Raycast): **Get Network Status** (returns current quality + average latency), **Run Bandwidth Test** (starts a Speedtest immediately), **Get Last Incident** (returns the most recent incident's time, duration, and cause), and **Export Network Report** (exports the last 24 hours as a CSV or JSON file). All four actions appear under "MeOrThem" in Shortcuts.app automatically on first launch.

---

## v2.42.0 — 2026-04-27

### New Features
- **Session comparison** — The Network Analysis window now has a "Compare Sessions" toolbar button. Click it to enter comparison mode, select any two sessions from the left panel (checkboxes replace single-selection), then click "Compare" to open a side-by-side comparison sheet. The sheet shows average latency, packet loss, jitter, WiFi signal, DNS latency, availability %, and best download speed for each session, with colour-coded delta values (green = improvement, red = degradation).

---

## v2.41.0 — 2026-04-27

### New Features
- **Local metrics endpoint** — Me Or Them can now serve live network metrics over a local HTTP server bound to 127.0.0.1 only (never exposed to the network). Enable it in Settings → General → Metrics Export. `GET /metrics` returns Prometheus text format (compatible with prometheus-node-exporter scrapers); `GET /metrics.json` returns the same data as JSON. Configurable port (1024–65535, default 9090). The server starts and stops immediately when toggled, and restarts automatically on port change.

---

## v2.40.0 — 2026-04-27

### New Features
- **Automatic ISP identification** — Me Or Them now resolves the ISP / AS name for your current session using DNS TXT lookups against the Cymru ASN database (no external service — pure DNS). The ISP name appears in the menu's Network Details row (e.g. "ISP: COMCAST-7922") and in the Network Analysis session list alongside the session date. Lookup runs asynchronously in the background at session open; private/loopback addresses are skipped immediately. Results are cached for the lifetime of the app.

---

## v2.39.0 — 2026-04-27

### New Features
- **Weekly pattern detection** — The Charts window now includes a "Weekly Pattern" bar chart showing average latency per day of week across the last 30 days, colour-coded against your latency thresholds. Network Analysis gains a new finding (pattern #17) that flags recurring weekly degradation when one weekday's average consistently exceeds the weekly mean by more than 1.5 standard deviations.

---

## v2.38.0 — 2026-04-26

### New Features
- **HTTP/HTTPS endpoint monitoring** — Ping targets can now be configured to use HTTP or HTTPS probing instead of ICMP. HTTP/HTTPS probes measure time-to-first-byte via a HEAD request (5-second timeout, ephemeral session, no cookies or cache). 2xx/3xx responses count as success; 4xx/5xx and network errors count as 100% loss. The probe mode (ICMP/TCP/HTTP/HTTPS) is selectable per target in Settings → Targets.

---

## v2.37.0 — 2026-04-26

### New Features
- **Battery-aware monitoring** — Me Or Them now adapts its behaviour when running on battery power. A new "On battery" setting in General → Monitoring offers three modes: Normal (no change), Reduced (polls at 2× the configured interval to halve subprocess activity), and Pause (monitoring suspends entirely until AC power is restored). The setting takes effect immediately when switching between AC and battery.

---

## v2.36.0 — 2026-04-26

### New Features
- **Uptime / Availability percentage** — Me Or Them now computes connection availability as a percentage of time spent in a non-degraded state, derived from the existing incidents journal. A "Uptime (24h)" row appears in the menu dropdown (green ≥ 99%, orange ≥ 95%, red below), and the Charts window shows an uptime badge next to the time window picker reflecting the selected window's availability. Updated hourly alongside existing maintenance.

---

## v2.35.0 — 2026-04-26

### New Features
- **Sleep/Wake event correlation** — Me Or Them now records system sleep and wake events to SQLite. The Charts window overlays dashed orange "Wake" and grey "Sleep" vertical markers on all time-axis charts (latency, loss, jitter, WiFi signal, DNS latency). Degradation incidents that begin within 90 seconds of a wake event are automatically tagged with "(post-wake)" in their cause string, explaining the most common "brief outage at 9am" pattern. Monitoring automatically pauses on sleep and resumes on wake.

---

## v2.34.0 — 2026-04-26

### New Features
- **VPN / Tunnel interface detection** — Me Or Them now detects active VPN or tunnel interfaces (utun*, ipsec*, ppp*) at session open time and approximately once per minute thereafter. The active tunnel name (e.g. "utun3") is shown in the Network Details submenu alongside WiFi info. Network Analysis findings for sessions where a VPN was active include an informational "VPN Active" notice explaining that latency readings include tunnel overhead.

---

## v2.33.0 — 2026-04-21

### New Features
- **Stealth Mode (ICMP throttling detection)** — Me Or Them now automatically detects when ICMP pings are blocked by a network (e.g. hotel or corporate Wi-Fi). After five consecutive all-target loss polls it runs a TCP probe (ports 443, 80, 53). If TCP succeeds while ICMP fails, it switches to TCP-based latency measurement and fires a "Stealth Mode Activated" notification. The per-network ICMP/stealth state persists across sessions.
- **Connection Profiles window** — A new "Connection Profiles…" entry in the Advanced submenu opens a window listing every network fingerprint the app has seen, including stealth mode status, ICMP health, probe port, session count, and last-seen time.

---

## v2.32.0 — 2026-04-21

### New Features
- **Per-target custom thresholds** — Each ping target can now have its own latency, packet loss, and jitter alert thresholds. When custom thresholds are set, that target's status is evaluated against its own values instead of the global defaults. Configure them in Settings → Targets by selecting a target and expanding "Custom Thresholds". Targets with active overrides show a "custom" badge in the list.

### Changes
- **Thresholds tab renamed to "Global Thresholds"** — The Settings tab previously labelled "Thresholds" is now "Global Thresholds" to clarify that it controls the defaults, not per-target overrides.

---

## v2.31.0 — 2026-04-21

### New Features
- **Incident History window** — A new "Incident History…" entry in the Advanced submenu opens a dedicated window listing all recorded network degradation incidents. Each row shows start time, severity, cause, and duration. Includes date-range filtering, a "Clear All" button with confirmation, and a "View" button per incident that opens the Network History charts window.

---

## v2.30.0 — 2026-04-21

### New Features
- **Bandwidth history chart** — The Network History window now includes a Bandwidth chart showing download and upload speed from past speed tests, with per-data-point markers, download/upload threshold reference lines, and hover tooltips. Shows "No bandwidth tests recorded" when no speed tests have been run.
- **"View Charts" notification action** — Degradation alerts now include a "View Charts" action button. Tapping it brings the app to the foreground and opens the Network History charts window directly.

---

## v2.28.0 — 2026-04-20

### New Features
- **Network Analysis shows connection type per session** — The session list in Network Analysis now displays an icon indicating whether each session was recorded on Wi-Fi, Ethernet, or VPN.
- **Network Analysis flags weak Ethernet fingerprints** — Sessions recorded without a router hardware address show an advisory warning that analysis data may combine measurements from multiple Ethernet networks sharing the same gateway IP.
- **Network Analysis notes when Wi-Fi analysis is unavailable** — For Ethernet and VPN sessions, a note at the bottom of the findings panel explains that Wi-Fi signal analysis does not apply to the current connection type.

---

## v2.27.0 — 2026-04-20

### New Features
- **PDF export shows network session history** — PDF reports now include a Network Sessions section listing each session in the export period with connection type, display name, and start/end times. Sessions recorded without a router hardware address (weak Ethernet fingerprint) are flagged with a warning.
- **PDF export handles non-WiFi connections** — The Wi-Fi History section in PDF reports now shows an informational message when no Wi-Fi data is present, rather than rendering an empty section.

---

## v2.26.0 — 2026-04-20

### New Features
- **JSON export includes network session metadata** — Exported JSON reports now contain a `sessions` array with each network session active during the export period, including connection type, display name, start and end times, and a warning for Ethernet sessions recorded without a router hardware address.

---

## v2.25.0 — 2026-04-20

### New Features
- **CSV export includes connection session summary** — Exported CSV reports now list the network sessions active during the export period (with connection type) in a comment header, making it easy to see what kind of connection was in use.
- **CSV export handles non-WiFi connections** — The Wi-Fi History section in CSV reports is now omitted when no Wi-Fi data is present, replaced by a note indicating an Ethernet or VPN connection was in use during the period.

---

## v2.24.0 — 2026-04-20

### New Features
- **Ethernet and VPN connections logged to daily CSV** — When using Ethernet or VPN, the daily activity log now records a snapshot row at each session start, capturing the connection type, interface name, and gateway IP for complete audit trails on non-WiFi connections.

---

## v2.23.1 — 2026-04-20

### Bug Fixes
- **Network Details menu shows VPN and unknown connection types** — The Network Details submenu now correctly identifies VPN connections (utun/ppp/tap interfaces) and displays tunnel interface name, IP address, and router. Unknown connection types show basic IP and router information. Non-WiFi connections explicitly note that Wi-Fi signal is not available.

---

## v2.23.0 — 2026-04-20

### New Features
- **Network sessions for Ethernet and VPN** — Session tracking now works for all connection types, not just Wi-Fi. Ethernet sessions are fingerprinted by gateway IP, subnet, and router hardware address; VPN sessions by tunnel interface, gateway IP, and subnet. Network Analysis history is now populated for Ethernet and VPN users.

---

## v2.22.3 — 2026-04-20

### Bug Fixes
- **Interface error monitoring uses correct adapter** — Interface error and drop counters now sample the interface that actually carries the default route (via the routing table), instead of falling back to the hardcoded `en0`. On Macs where the active Ethernet adapter is `en1` or where a VPN tunnel is active, the correct interface is now monitored.

---

## v2.22.2 — 2026-04-20

### New Features
- **Session connection type stored in database** — Each network session now records its connection type (Wi-Fi, Ethernet, VPN) and whether the Ethernet fingerprint was created without a router hardware address, enabling connection-aware display in analysis and export features.

---

## v2.22.1 — 2026-04-20

### New Features
- **Ethernet and VPN session fingerprinting** — Network sessions are now correctly created for Ethernet and VPN connections, not only for Wi-Fi. Ethernet sessions use the gateway IP, subnet, and router hardware address as the fingerprint; VPN sessions use the tunnel interface name, gateway IP, and subnet.
- **Weak fingerprint advisory** — When the router hardware address is unavailable at session creation time (ARP cache miss), the session is flagged so the Network Analysis window can warn that data from different Ethernet networks sharing the same IP and subnet may have been combined.

---

## v2.22.0 — 2026-04-20

### New Features
- **Default route interface detection** — The app can now identify which network interface carries the active default route (Wi-Fi, Ethernet, VPN tunnel, or PPP), enabling connection-type-aware behaviour throughout.
- **Gateway router hardware address lookup** — The gateway's MAC address is resolved from the ARP cache, providing a reliable hardware-level identifier for the connected router that distinguishes different routers even when they share the same IP address.

---

## v2.21.4 — 2026-04-18

### First public release since v1.11.6 — a major upgrade

Me Or Them is still a circle in your menubar. Green means everything is
fine, and you never need to touch a setting to get value from it. But
almost everything underneath has changed.

Since the last public release, Me Or Them has evolved from a lightweight
network status indicator into a network intelligence platform. The app
now runs 17 diagnostic algorithms continuously in the background. When
your network misbehaves, it no longer just changes colour — it tells you
why, with confidence scores and plain-English recommendations.

What's new at a high level:

- Network Analysis — A diagnostics engine that reviews each session
  against 17 patterns: elevated latency with gateway attribution, packet
  loss (burst vs. steady), jitter (congestion vs. instability), weak or
  unstable WiFi signal, session fault profiling (local vs. ISP, minute by
  minute), WiFi/latency correlation, per-target outlier detection,
  bufferbloat, five DNS-specific findings (failure rate, elevated
  latency, resolver divergence, complete failure, port 53 blocking),
  hardware interface errors, MTU/path fragmentation, latency trend via
  OLS regression, WiFi channel switching, recurring time-of-day
  congestion against 30 days of history, and automatic traceroute
  capture on degradation. Every finding is confidence-scored — only what
  the data actually supports is surfaced.

- Multi-Resolver DNS Monitoring — Raw UDP probes to up to 8 resolvers
  (Cloudflare, Google, Quad9, OpenDNS, AdGuard, system, gateway, and
  custom) bypass the OS cache entirely. Real resolver response times
  appear in the dropdown and are charted over time. Failing resolvers are
  auto-paused and re-probed in the background.

- Hardware-Level Visibility — MTU path fragmentation detection
  (1472-byte Don't-Fragment probes every ~2.5 min), kernel-level
  interface error and drop counter sampling every ~30 s, and automatic
  traceroute capture when connections degrade from green to red (at most
  once every 5 minutes, stored and surfaced in the analysis window).

- Network Session Tracking — Each network environment (gateway IP +
  WiFi band + channel + subnet) is fingerprinted automatically with no
  location permission required. Every sample is tagged to its session so
  the analysis engine draws accurate per-network conclusions across weeks
  of history.

- Dramatically Smaller Footprint — CPU dropped from ~1% at 5 s polling
  to ~0.4% at the new default 2 s interval. Memory fell from ~50 MB to
  ~14 MB. Test coverage grew from 193 to 325 passing tests.

If you're coming from v1.x: drag the new version to Applications and
launch — the install experience is identical. The circle is still the
circle. Everything new is waiting whenever you want it, quietly out of
the way when you don't.

The incremental changes across each release from v2.0.3 onward are
documented below.

### Changes
- **Smoother "Copied!" feedback** — The copy-to-clipboard button in the Ping Report window now resets using structured concurrency instead of a legacy GCD timer, keeping it consistent with the rest of the app's async model.
- **Faster WiFi–latency correlation** — The network analyser now uses binary search to pair ping rows with their nearest WiFi sample, reducing the per-analysis cost from O(n²) to O(n log n) on large history windows.

---

## v2.21.3 — 2026-04-18

### Bug Fixes
- **Loading animation on zero targets** — The status icon no longer skips its loading state when all ping targets have been removed; the loading blink now only stops once at least one target exists and has received its first result.
- **Network session stability on 5 GHz WiFi** — Resolved a floating-point precision issue where `channelBandGHz` values like `2.3999999...` or `5.0000001...` could produce a different session fingerprint on each poll tick, silently opening a new network session row every few seconds. Session history now groups correctly across 2.4, 5, and 6 GHz bands.
- **Sub-millisecond ping targets show correct loss** — Pings that return `time=0.000 ms` (localhost, loopback, very fast LAN) were previously treated as timeouts and recorded as 100% packet loss. They are now recorded correctly with 0 ms RTT and 0% loss.
- **Log rotation preserves correct files after restore** — Log pruning now sorts by the date embedded in the filename rather than the filesystem creation timestamp. Restoring from Time Machine or copying log files no longer causes current logs to be deleted while old ones are kept.
- **Interface error sampling on Ethernet-only Macs** — The interface error sampler now uses the active primary ethernet interface name when WiFi is off, rather than always falling back to `en0`. On Macs where `en0` is the WiFi adapter and `en1` is Ethernet, error deltas are now recorded correctly.

---

## v2.21.2 — 2026-04-17

### Bug Fixes
- **DNS menu item style** — The DNS row in the dropdown now uses the same non-selectable, non-hoverable style as the Latency, Packet Loss, and Jitter rows above it, matching their text colour and behaviour.
- **Graphs window stays visible** — The Network History window no longer hides when the user switches to another application; it remains on screen until explicitly closed.
- **Close button in Graphs window** — A Close button has been added at the bottom of the Network History window. The window can also be closed via the standard red traffic-light button in the title bar.

---

## v2.21.1 — 2026-04-17

### Bug Fixes
- **Cleaner DNS menu entry** — The DNS row in the dropdown now shows only the
  status dot and response time (e.g. "DNS ● 8ms"). The resolver name and
  responding-resolver count badge have been removed; they were confusing in
  context and added no actionable signal in the menu.

---

## v2.21.0 — 2026-04-17

### New Features
- **Daily Pattern chart** — The Graphs window now includes a bar chart showing
  average latency by hour of day across the last 30 days of recorded data. Bars
  are coloured green, orange, or red based on the configured latency thresholds,
  making peak congestion windows immediately visible. The chart appears once at
  least 4 hours of historical aggregate data are available.
- **Latency trend line** — The Latency chart in the Graphs window now overlays a
  dashed regression line when a meaningful upward or downward trend is present
  (slope > 0.3 ms per minute). A red line indicates a worsening trend; green
  indicates improving. The line is hidden when the data is too flat or too noisy
  to produce a reliable fit.

### Changes
- **DNS findings now use a distinct globe icon** — All DNS-related findings in
  the Network Analysis window (resolver unreliable, slow resolution, faster
  resolver available, complete DNS failure, port blocking) now appear with a
  globe icon rather than the generic network icon, making them easier to
  distinguish from routing and connectivity findings at a glance.
- **Network Analysis findings sorted by confidence** — Findings are now listed
  highest-confidence first, so the most actionable issues appear at the top
  regardless of which order the pattern checks run.
- **Issue count badge in Network Analysis header** — The session header now
  shows a badge with the number of issues found, giving a quick summary without
  having to scroll through the list.
- **Expandable raw traceroute output** — Traceroute snapshot findings in the
  Network Analysis window now include a "Show raw output" disclosure section
  that reveals the full hop-by-hop traceroute text. The text is selectable for
  copying into a support ticket or further analysis.

---

## v2.20.0 — 2026-04-17

### New Features
- **Latency trend detection** — The Network Analysis window now includes a finding
  when your latency increases at a steady rate over a session. It uses ordinary
  least-squares linear regression on the RTT sequence; the R² value is shown
  alongside the slope so you can judge how reliable the trend is. A persistent
  upward trend can indicate progressive router buffer saturation, thermal
  throttling on a network device, or a background process steadily consuming
  more bandwidth.
- **Recurring peak-hour congestion detection** — The Network Analysis window
  compares the selected session against up to 30 days of historical aggregate
  data to detect hours of the day that are consistently slower than your
  baseline. When specific hours show recurring elevated latency, the finding
  names them and notes that the pattern is consistent with time-of-day ISP or
  shared-segment congestion.
- **Automatic traceroute on degradation** — When the connection degrades from
  green to red (packet loss + high latency confirmed), the app automatically
  runs a traceroute in the background (at most once every five minutes) and
  saves the result. The Network Analysis window surfaces a Traceroute Snapshot
  finding for the session, summarising the hop count and the highest-latency
  hop to help pinpoint where on the path the problem is occurring.
- **Wi-Fi channel switching detection** — The Network Analysis window now
  detects when your Wi-Fi channel changed two or more times during a session.
  Frequent channel changes suggest RF interference forcing the access point to
  self-heal, the device roaming between access points, or DFS events on 5 GHz
  channels. Band switches (2.4 GHz ↔ 5 GHz) are called out separately as they
  force a full reassociation.

---

## v2.16.0 — 2026-04-17

### New Features
- **Multi-resolver DNS monitoring** — The app now probes up to 8 DNS resolvers
  concurrently every ~30 seconds using raw UDP queries that bypass the OS cache,
  giving an accurate per-resolver round-trip time. Cloudflare (1.1.1.1), Google
  (8.8.8.8), Quad9 (9.9.9.9), OpenDNS, AdGuard, their IPv6 equivalents, and the
  system and gateway resolvers are pre-configured; custom resolvers can be added
  in Settings → DNS Resolvers. The fastest responding resolver and its trimmed-
  mean RTT are shown in the menu bar dropdown. Resolvers that fail repeatedly are
  auto-paused and re-probed in the background.
- **DNS resolver settings tab** — A new DNS Resolvers tab in Settings lets you
  enable or disable individual resolvers, add custom IP addresses (IPv4 or IPv6),
  remove custom entries, and re-enable any that were auto-paused. A maximum of 8
  resolvers can be active simultaneously.
- **DNS latency chart** — The Graphs window now includes a DNS Resolver Latency
  chart showing per-resolver RTT over time as colour-coded series. Probe failures
  appear as gaps rather than zero values, making outages visually distinct from
  genuine low-latency responses.
- **DNS analysis patterns** — The Network Analysis window surfaces five new DNS-
  specific findings: high per-resolver failure rate, elevated resolver latency,
  significant latency divergence between resolvers, all resolvers failing
  simultaneously, and signs of DNS port blocking where UDP port 53 is unreachable.
- **DNS data in exports** — CSV exports now include a DNS Resolver Samples
  section with one row per probe (timestamp, resolver name, IP, RTT, RCODE).
  JSON exports include a dnsResolvers key with per-resolver trimmed-mean RTT,
  failure rate, sample count, and the full raw sample list. PDF reports include
  a DNS Resolvers summary table with average RTT and failure rate per resolver.

---

## v2.8.0 — 2026-04-16

### New Features
- **MTU / path fragmentation detection** — The app now periodically sends a
  large-packet probe (1472-byte payload, Don't-Fragment bit set) to the primary
  ping target, roughly every 2.5 minutes. The Network Analysis window surfaces a
  finding when the majority of these probes fail while normal pings succeed — a
  classic sign that something on the network path (a VPN tunnel, PPPoE DSL link,
  or strict firewall) is silently blocking or fragmenting oversized packets,
  causing slow page loads and stalled connections without any obvious ping loss.

---

## v2.7.0 — 2026-04-16

### New Features
- **Network interface error monitoring** — The app now samples hardware-level
  packet error and drop counters for the active network interface roughly every
  30 seconds. The Network Analysis window surfaces a new finding when repeated
  interface errors or driver-level drops are detected — a pattern indicating RF
  interference, hardware faults, or driver buffer overflows that ping-based
  metrics alone cannot reveal.

---

## v2.6.0 — 2026-04-16

### New Features
- **DNS resolution monitoring** — The app now periodically measures how
  long it takes the system resolver to look up a hostname, sampling roughly
  every 30 seconds. The Network Analysis window surfaces two new findings:
  slow DNS resolution (average > 200 ms) and DNS failure rate (> 10% of
  lookups failing). Slow DNS is a common hidden cause of sluggish browsing
  and app connections even when ping times to servers are normal.

---

## v2.5.0 — 2026-04-16

### New Features
- **Session fault profile** — Network Analysis now includes a
  "Connectivity" finding that classifies each minute of session
  degradation as local (gateway was also affected) or upstream (gateway
  was clean). Sessions with enough degraded time receive a clear verdict:
  primarily local network issues, primarily ISP issues, or a mixed picture.
- **Wi-Fi / latency correlation** — When Wi-Fi RSSI and ping RTT samples
  are time-aligned across a session, the analyser computes their Pearson
  correlation. A strong negative correlation (signal drops → latency
  rises) surfaces as a finding that confirms Wi-Fi is the root cause of
  latency problems — distinct from ISP or server-side issues.
- **Outlier target detection** — If one ping target consistently shows
  more than 2.5× the average latency of the other targets, a finding
  names that target and explains it likely reflects a routing, geographic,
  or CDN issue specific to that destination.
- **Bufferbloat detection** — Speed test latency (measured under full
  load) is compared against the idle baseline RTT. When load latency is
  at least 2× the idle average, a finding explains bufferbloat and
  recommends enabling SQM/FQ-CoDel on the router.

---

## v2.4.0 — 2026-04-16

### Changes
- **Jitter analysis uses inter-poll variance** — The jitter finding in
  Network Analysis now measures how much average latency varies between
  consecutive poll cycles rather than averaging the per-poll standard
  deviation of three ICMP packets. This inter-poll metric has far less
  sampling noise and accurately reflects the latency inconsistency a
  user experiences. The finding also distinguishes between a congestion
  pattern (only inter-poll variance is high) and severe instability
  (both inter-poll and intra-poll variance are elevated).

---

## v2.3.0 — 2026-04-16

### New Features
- **Wi-Fi signal instability detection** — Network Analysis now detects
  unstable Wi-Fi signals even when the average signal level looks
  acceptable. If RSSI swings more than 8 dBm, a dedicated finding
  explains that interference, obstacles, or roaming between access
  points may be the cause. When both average signal is weak and variance
  is high, a combined note is included in the existing weak-signal
  finding. SNR now modulates confidence: noisy environments (SNR < 20 dB)
  increase confidence; strong SNR reduces it slightly.

---

## v2.2.0 — 2026-04-16

### New Features
- **Gateway fault attribution** — The Network Analysis patterns for elevated
  latency and packet loss now compare external target metrics against gateway
  ping metrics. When the gateway is also degraded, the finding attributes the
  problem to the local network or router. When the gateway responds normally,
  the finding points upstream to the ISP or routing path. Attributable findings
  receive a confidence boost.

---

## v2.1.1 — 2026-04-16

### Bug Fixes
- **Network Analysis double data load** — Selecting a network session in the
  analysis window previously fetched all SQLite rows twice. The redundant fetch
  is eliminated; analysis now loads data in a single background pass.

---

## v2.1.0 — 2026-04-16

### New Features
- **Network Analysis** — A new analysis window (under Advanced in the menu)
  reviews historical data for each network session and surfaces findings for
  elevated latency, packet loss, jitter, weak Wi-Fi signal, and variable
  download speed. Each finding is rated High, Medium, or Low confidence based
  on data volume and metric severity.
- **Network session tracking** — Me Or Them now automatically identifies and
  records distinct network environments using a fingerprint derived from gateway
  IP, Wi-Fi band, channel, and subnet — no location permissions required. All
  ping and Wi-Fi samples are tagged to their session so the analyser can draw
  accurate per-network conclusions.

### Changes
- **Advanced submenu** — Graphs (formerly Network History), Network Analysis,
  Export Reports, and Network Details are now grouped under a new Advanced
  submenu to keep the main menu concise. Previous Disturbances and Settings
  sit in the same section beneath it; Help and About have their own section
  directly above Quit.

---

## v2.0.3 — 2026-04-13

### Apology!
There was a small bug making the update-window crazy wide. Sorry for this
inconvenience trying to get to the download button all the way to the right.
This release will fix this problem for future releases!

### Bug Fixes
- **Update window too wide** — The "Update Available" changelog text is now
  word-wrapped at 80 characters and the window has a maximum width, preventing
  long release-note lines from stretching the window off-screen.
- **App not closed before update install** — Clicking "Download & Install" now
  quits Me Or Them automatically once the DMG has been downloaded and opened,
  so
  the user can immediately replace the app without a separate manual quit
  step.
- **Notarization failure on fresh build** — The speedtest helper was being
  signed without the Hardened Runtime flag, which Apple rejects at
  notarization.
  It is now signed with Hardened Runtime and the required entitlements. A
  duplicate copy of the binary that SPM placed in the resource bundle is also
  removed at build time.
- **DMG installer window too narrow** — The installer window was sized larger
  than most screens, causing the Applications folder shortcut to be clipped.
  The
  window is now 660 × 400 points with both icons fully visible at launch.

---

## v2.0.2 — 2026-04-12

### Bug Fixes
- **Bandwidth test retry on transient failure** — When the speedtest binary is
  killed by the OS mid-run (exit code 15 / SIGTERM), the runner now
  automatically retries up to 3 times with a 4-second delay between attempts
  before reporting a failure. The menu shows "Retrying (2/3)…" during the wait
  so the status is always visible.

---

## v2.0.1 — 2026-04-11

### Bug Fixes
- **High CPU during network jitter** — The `$latestPing` publisher fired once
  per monitoring target on each poll tick, and each fire called the full icon-
  update path which unconditionally sent the status bar image to System UI
  Server via IPC — even when the icon was visually unchanged. The update path
  now separates the latency text (updated per tick) from the icon image
  (updated
  only when status actually changes). The image assignment is also guarded by
  pointer equality so cached images are never re-sent to the compositor.
  Additionally, the default-gateway lookup — which spawns `/sbin/route` and
  waits synchronously — was running on the main thread every 30 seconds; it
  now
  runs on a background thread.

---

## v2.0.0 — 2026-04-11

### Bug Fixes
- **Bandwidth check failing silently** — The bundled speedtest binary carried
  a
  quarantine extended attribute from its original download, which Gatekeeper
  blocked at launch time. The build script now strips the attribute after
  copying the binary into the app bundle.

---

## v1.28.4 — 2026-04-11

### New Features
- **1 Year chart view** — Network History now includes a "1 Year" time window
  button, backed by 366-day per-minute aggregate data.

### Bug Fixes
- **Threshold reset ignored bandwidth sliders** — "Reset to Defaults" in
  Settings → Thresholds now correctly resets bandwidth to Red < 25 Mbps /
  Yellow
  < 100 Mbps.
- **Duplicate targets allowed silently** — Adding a target with a host that
  already exists now shows an inline error instead of creating a duplicate
  entry
  that pings the same host twice.
- **Retention fields accepted invalid input** — Typing 0 or a negative number
  into the data retention fields in Settings is now clamped to a valid range
  (1–365 days for raw, 1–3650 for summaries and incidents).

---

## v1.28.3 — 2026-04-11

### Changes
- **Aggregate history extended to 366 days** — Per-minute roll-up retention
  increased from 90 to 366 days, allowing year-over-year comparison of the
  same
  day.

---

## v1.28.1 — 2026-04-10

### Bug Fixes
- **Hover tooltip causing CPU spike** — The hover tooltip card in Network
  History was using `.regularMaterial`, the same vibrancy background that
  caused
  the 46% CPU regression in v1.27.0. The chart cards were fixed at the time
  but
  the tooltip overlay was missed. Replaced with a solid system color,
  eliminating compositor re-blending on cursor movement.

### Changes
- **Hover rendering efficiency** — Nearest-point computation (`snappedPoints`)
  was called twice per hover frame — once for the cursor markers, once for the
  tooltip — each time iterating and grouping the full point set. The result is
  now computed once per frame and passed through to both consumers.
- **DateFormatter allocation eliminated** — Formatters in the update checker
  and
  incident list were being allocated on every call. Both are now static
  constants, removing repeated `DateFormatter` initialization.

---

## v1.28.0 — 2026-04-10

### Bug Fixes
- **Time range tabs enabled for empty windows** — The 1h/6h/24h/… buttons in
  Network History are now disabled per-target. Previously the availability
  check
  was global (any target has data), so switching to a specific target could
  show
  buttons as active even when that target had no data for that range. The
  check
  now filters to the selected target and re-runs whenever the target picker
  changes.
- **Tooltip showing only one target on hover** — The hover tooltip now shows
  all
  visible targets. The bug was that concurrent pings for different targets
  complete at slightly different timestamps; the tooltip was filtering for an
  exact timestamp match so only the target whose timestamp was used as the
  snap
  anchor appeared. Now uses nearest-per-target matching.
- **Incidents stuck as "Active" in Network History** — An incident left open
  from a crashed or force-quit session was closed in the in-memory history on
  startup, but the SQLite row was never updated. Since Network History reads
  directly from SQLite, it continued showing the incident as active. The
  `ended_at` column is now written on startup when orphaned incidents are
  found.
- **Background CPU not dropping after closing Network History** — The
  `NSWindow.willCloseNotification` observer token returned by
  `NotificationCenter.addObserver(forName:object:queue:using:)` was discarded,
  causing ARC to remove the observer before it ever fired. The window
  controller
  was therefore never released after closing, keeping a vibrancy-backed
  `NSHostingController` alive in the compositor indefinitely. The token is now
  retained and the window controller is correctly released on close, restoring
  background CPU to baseline.

---

## v1.27.1 — 2026-04-10

### Changes
- **Reduced CPU at high polling frequencies** — Ping subprocess packet count
  reduced from 5 to 3 (200ms interval unchanged). Subprocess duty cycle drops
  from ~50% to ~22% at the 2-second poll interval, bringing average CPU from
  ~2%
  closer to ~1.3%. Loss granularity changes from 20% steps to 33% steps per
  sample, which has no practical effect since evaluation windows average
  across
  multiple polls.

---

## v1.27.0 — 2026-04-10

### New Features
- **Update notification in menu** — When a newer release is available on
  GitHub,
  a notification item appears at the top of the dropdown with a link to
  Settings
  where the update can be downloaded.

### Bug Fixes
- **Network History CPU spike** — Opening the Network History window no longer
  causes 46–50% CPU usage. Root cause was
  `.ultraThinMaterial`/`.regularMaterial` backgrounds forcing the macOS
  compositor to continuously re-sample and blend vibrancy layers on every
  cursor
  movement. Replaced with solid system colors.
- **Background CPU elevated after first open** — The charts window controller
  was retained after closing, keeping a vibrancy-backed `NSHostingController`
  alive in the compositor indefinitely. The controller is now released when
  the
  window closes, dropping background CPU back to baseline.
- **Network History graphs appeared dark** — The overlapping translucent
  material backgrounds created a dark, murky appearance, especially in dark
  mode. Charts now use `controlBackgroundColor` cards on a
  `windowBackgroundColor` base for a bright, clear appearance.

### Changes
- **Network History hover performance** — Hover snap computation now uses
  binary
  search instead of linear scan, and is throttled to ≤60 FPS (down from the
  display refresh rate of up to 120 Hz). Data point cap reduced from 1500 to
  600, which is more than sufficient for chart resolution.

---

## v1.26.0 — 2026-04-10

### Changes
- **Network History graph style** — Charts now use area fills under each line
  (matching the reference design), removed background threshold zone bands,
  and
  increased line weight to 2pt for better readability.
- **Duplicate chart legend removed** — Labels no longer appear twice; the
  chart's auto-generated legend is suppressed and only the manual legend below
  each chart is shown.
- **Hover tooltip performance** — Tooltip and markers are now drawn in the
  lightweight overlay layer rather than inside the chart body, so charts do
  not
  re-render on every cursor pixel. `hoveredDate` snaps to actual data-point
  timestamps so state only updates when the cursor crosses into a new point's
  territory, eliminating the sluggishness.

### Bug Fixes
- **Time window buttons disabled when empty** — Time range segments in the
  Network History toolbar are now disabled (grayed out) when no data exists
  for
  that window, replacing the segmented picker with a custom implementation
  that
  supports per-item disabled state.

---

## v1.25.0 — 2026-04-10

### New Features
- **Hover markers in Network History** — Hovering over any chart snaps a
  marker
  to the nearest data point per target, with a floating tooltip showing
  timestamp and color-coded values for all visible targets.
- **Inline chart legend** — When multiple targets are visible, a color-coded
  legend appears below each chart.

### Changes
- **Network History redesigned for macOS 26** — Window now uses a native
  unified
  toolbar with the target picker in the leading area, segmented time-range
  control in the center, and refresh button trailing. Charts use
  `.regularMaterial` card backgrounds, `.ultraThinMaterial` window background,
  reduced zone opacity (6%), caption-weight axis labels, and subtle grid
  lines.
- **Network History default time range** — The window now opens on the 1-hour
  view instead of 24 hours.
- **Network History stays visible** — The window no longer hides when the app
  loses focus; it must be closed manually.

### Bug Fixes
- **Status bar icon could disappear** — All Combine publishers that update the
  status bar icon and menu items now explicitly deliver on the main queue.
  Without this guarantee, AppKit UI updates could be called off the main
  thread,
  silently corrupting or hiding the icon.
- **App freeze and keyboard lockup on GCD thread exhaustion** — Each
  `runAsync`
  subprocess call was blocking a GCD worker thread on `readDataToEndOfFile()`
  for the full subprocess lifetime. Under repeated polling with many
  simultaneous subprocesses (e.g. after opening the Network History window),
  this saturated the GCD thread pool at 512 threads, deadlocking the async
  runtime and trapping the keyboard inside NSMenu's modal event loop. Replaced
  with event-driven `readabilityHandler` I/O that holds no GCD thread while
  waiting for output.

---

## v1.24.0 — 2026-04-09

### Bug Fixes
- **SQLite fallback on corrupt database** — If the on-disk database cannot be
  reopened after a corruption wipe, the app now falls back to an in-memory
  database instead of silently operating on a null handle.
- **Chart time-range race condition** — The displayed start/end dates in the
  Network History window now update atomically with chart data, eliminating a
  brief window where the header showed stale dates for newly loaded data.
- **Process timeout** — External subprocesses (speedtest, route) are now
  forcibly terminated after 30 seconds if they do not exit cleanly, preventing
  the app from hanging indefinitely.
- **Adaptive polling state clobbered on restart** — Switching to faster
  polling
  during a degradation event no longer accidentally resets `isAdaptiveMode`,
  which previously caused the engine to enter an accelerated-polling loop
  without ever restoring the original interval.
- **NetworkInfo cache data race** — The gateway and IP-address caches shared
  across threads are now protected by a lock, eliminating a potential data
  race
  under concurrent access.
- **Non-finite jitter values** — Jitter calculation now filters out non-finite
  RTT samples and returns nil if the result is NaN or Inf, preventing corrupt
  values from reaching the threshold evaluator.
- **Non-positive RTT values** — Ping output parser now discards RTT values of
  zero or less, which can appear in malformed or synthetic ping output.
- **SQLite string binding with embedded NULs** — Text values are now bound
  with
  their exact UTF-8 byte length instead of relying on null-terminator
  scanning,
  correctly handling any string that contains embedded NUL characters.
- **CSV log write errors silently ignored** — Write failures in the append-
  mode
  log are now caught and logged via `os_log` instead of silently dropping
  data.
- **Concurrent ping cap** — The per-tick ping task group is now capped at 5
  concurrent pings, preventing resource exhaustion when many custom targets
  are
  configured.

---

## v1.23.0 — 2026-04-09

### New Features
- **Network History window** — A new "Network History…" menu item (and "View
  Charts" button in Export Reports) opens a full visualisation window with
  four
  live charts: Latency, Packet Loss, Jitter, and WiFi Signal. Charts use
  colour-
  coded threshold bands so healthy, degraded, and poor zones are immediately
  obvious. Vertical markers show where disturbances occurred. A disturbance
  log
  is shown beneath the charts.
- **Time window selector** — The chart window lets you switch between 1h, 6h,
  24h, 7d, 30d, and 90d views. Short windows use raw poll data; longer windows
  switch automatically to per-minute aggregates from the database. A per-
  target
  filter is available when multiple ping targets are configured.
- **Full-history CSV and JSON exports** — Export Reports now reads directly
  from
  the SQLite database, covering the full raw-data retention window (default 7
  days) instead of the last few hours in RAM.

---

## v1.22.0 — 2026-04-09

### Changes
- **Lower default latency thresholds** — Yellow now triggers at >60 ms (was
  100
  ms) and red at >150 ms (was 200 ms), giving earlier warnings on connections
  that affect video calls and real-time audio.
- **Export Reports** — The "Ping Stats Report" menu item is renamed to "Export
  Reports".

### New Features
- **Notification settings** — A new Notifications section in Settings lets you
  independently control the banner and sound for connection degradation
  alerts.
  Banners are on by default; the notification sound is off by default.

---

## v1.21.0 — 2026-04-09

### Changes
- **Settings: Data section redesigned** — The "Daily log rotation" toggle is
  renamed "Save CSV log files" with an updated description reflecting the new
  append-mode behaviour. A "Show in Finder" button opens the log directory
  directly. An "Advanced" disclosure group reveals configurable retention
  windows for raw data (default 7 days), per-minute summaries (default 90
  days),
  and the incident archive (default 365 days). When collapsed, the current
  retention values are shown inline as a summary.

---

## v1.20.0 — 2026-04-09

### New Features
- **Diagnostic burst query API** — The SQLite store now exposes a
  `diagnosticPingRows(for:incidentStart:incidentEnd:preSeconds:postSeconds:)`
  method that returns the raw ping samples surrounding a degradation event
  (default: 5 minutes before and after). Because all samples are written
  continuously, no extra capture overhead is needed — the surrounding data is
  always present.

---

## v1.19.0 — 2026-04-09

### Changes
- **Unlimited incident journal** — Previous Disturbances now loads from the
  SQLite database on launch instead of a 5-event UserDefaults cap. The in-
  memory
  menu list shows the last 20 events; the full history is retained in the
  database for up to one year (configurable). Clearing the history now removes
  records from the database as well.

---

## v1.18.0 — 2026-04-09

### Changes
- **Continuous append CSV logging** — The daily log file is now an unbroken
  append-mode record written on every poll tick, replacing the previous
  midnight
  snapshot. Data is no longer lost between restarts or between midnight runs.
  Existing daily CSV files are re-opened on launch and appended to; a new file
  is created at midnight. File retention now follows the same configurable
  window as the SQLite raw tier (default 7 days).

---

## v1.17.0 — 2026-04-09

### New Features
- **Live SQLite persistence** — Every poll tick now writes to the on-disk
  database in real time. Ping samples, WiFi snapshots, and degradation
  incidents
  are all persisted across app restarts. A maintenance job runs on launch and
  every hour to roll up and prune old data according to configurable retention
  windows (default: 7 days raw, 90 days aggregated, 1 year incidents).

---

## v1.16.0 — 2026-04-09

### New Features
- **Persistent SQLite storage layer** — Network metrics are now written to a
  local SQLite database (`~/Library/Application Support/MeOrThem/metrics.db`).
  Raw samples are kept for 7 days at full poll resolution, then automatically
  rolled up into per-minute aggregates retained for 90 days. A dedicated
  incident journal replaces the previous 5-event cap, retaining degradation
  events for 1 year by default.

---

## v1.15.1 — 2026-04-09

### Bug Fixes
- **Gateway always first** — The Gateway target row is now always displayed at
  the top of the target list in the dropdown, above user-configured targets.
- **Previous Disturbances updates while open** — The submenu now refreshes in
  real-time when a disturbance resolves, even if it is already open.
  Previously
  it required closing and reopening the menu.
- **Metric row alarm colors** — Latency, Packet Loss, and Jitter rows in the
  dropdown now turn orange when values exceed the yellow threshold and red
  when
  they exceed the red threshold, matching the user-configured limits. Default
  color is unchanged.

### Changes
- **Bandwidth bar threshold range extended** — Slider range for the bandwidth
  bar thresholds is now 10 Mbps – 2 Gbps (previously capped at 500 / 200
  Mbps).
- **SSID removed from exports** — WiFi history in CSV and PDF exports no
  longer
  includes an SSID column; the field was always "—" since reliable SSID
  extraction is unavailable without Location permissions.
- **Build without Apple Developer account** — `build.sh` and `make_dmg.sh` now
  fall back to ad-hoc (self) signing when no Apple Developer credentials are
  found, with verbose logging at each decision point. Allows building from
  source without an Apple Developer Program subscription.
- **Speedtest binary location** — The bundled speedtest CLI is now placed in
  `Contents/MacOS/` (previously `Contents/Resources/`) to align with Apple's
  recommended layout for signed helper executables in notarized apps.

---

## v1.15.0 — 2026-04-07

### New Features
- **System load detection** — Me Or Them now samples CPU utilisation on every
  poll tick. When network quality degrades and system load is ≥75%, the
  dropdown
  shows a "⚠ High system load (X%) — readings may be affected" advisory. If
  the
  degradation event is logged in Previous Disturbances, the cause also notes
  the
  high CPU (e.g. "high latency (180ms), high system load (82%)") so you know
  whether a bad reading was likely a network problem or the machine being
  resource-constrained.

---

## v1.14.0 — 2026-04-07

### New Features
- **Sidebar settings navigation** — Settings window redesigned with a macOS
  System Settings–style sidebar (NavigationSplitView), showing each section
  with
  an icon and subtitle.

### Changes
- **Trimmed mean quality evaluation** — When 3 or more ping targets are
  configured, the single best and worst per-metric value are discarded before
  averaging. This prevents a consistently-slow or unreachable target from
  inflating the overall network status.
- **"Recovered" timeout** — The "Recovered" label in the dropdown disappears
  automatically after 3 minutes, keeping the menu clean during stable periods.

---

## v1.13.0 — 2026-04-06

### New Features
- **Per-metric evaluation windows** — Latency, packet loss, and jitter are
  each
  averaged over an independent configurable time window before being compared
  to
  thresholds. A single noisy poll is diluted by surrounding good samples and
  never triggers a status change alone.
  - Default windows: Latency 15 s · Packet loss 10 s · Jitter 30 s
  - Jitter's 30-second default guards against AWDL (AirDrop/Handoff) channel
  scans that fire roughly every 60 seconds and cause brief spikes.

### Changes
- **Evaluation window sliders in Thresholds settings** — Each metric now has
  its
  own "Evaluation window" slider (range: poll interval → 300 s). "Reset to
  Defaults" also resets the windows.

---

## v1.12.0 — 2026-04-06

### New Features
- **Previous Disturbances** — A "Previous Disturbances" submenu in the main
  menu
  shows the last 5 network quality events: severity, timestamp, what caused
  the
  degradation, and how long it lasted. Active degradations show as "Ongoing";
  resolved ones as "Recovered". History persists across restarts.
- **Gray icon on manual pause** — The menubar icon turns gray when monitoring
  is
  manually paused. Pausing for a bandwidth test leaves the icon at its current
  quality color.
- **Launch at login enabled by default** — New installs automatically register
  for launch at login (can be disabled in Settings → Startup).

### Changes
- **Menu reordered** — Pause/Resume Monitoring moved to the top. Network
  Details
  moved below Ping Stats Report. Bottom actions: Help, Settings, About.
- **Update checker reliability** — A failed startup check no longer blocks
  future checks for 24 hours. Retries up to 5 times at 60-second intervals;
  timestamp only recorded after a successful response.
- **"Last checked" timestamp in Settings** — The Updates section now shows
  when
  the last check occurred and flags network errors.
- **Update window shows full changelog** — The "Update Available" window
  fetches
  and displays the changelog so you can review what changed before updating.

### Bug Fixes
- **Previous Disturbances submenu collapsed every second** — The 1-second
  countdown timer was refreshing (and collapsing) the submenu on every tick.
  Now
  only updates when connection history actually changes, and skips updates
  while
  the submenu is open.

---

## v1.11.6 — 2026-04-05

### Bug Fixes
- **~20% CPU spike** — WiFi monitoring subscribed to `linkQualityDidChange`,
  which fires on every RSSI fluctuation — potentially dozens of times per
  second
  on a busy network. Each event spawned a `networksetup` subprocess. Removed
  the
  subscription; RSSI and Tx rate are already captured on every poll tick. SSID
  is now cached per connection so the subprocess runs at most once per actual
  reconnect.

---

## v1.11.5 — 2026-04-05

### Changes
- **Reduced CPU and memory footprint** — Status bar icon rendering is now
  cached
  by state, eliminating redundant draw calls during animations. Jitter uses a
  single-pass calculation. Settings serialization reuses shared
  encoder/decoder
  instances. Sparklines skip string formatting when data is unchanged.
  Circular
  buffers use tighter capacity bounds (~5–6 MB memory reduction).

---

## v1.11.4 — 2026-04-05

### Bug Fixes
- **Crash on launch with VPN or tunnel adapters** — Network interface lookups
  now nil-guard socket address pointers before dereferencing.
- **Packet loss percentage wrong during startup** — The "Packet Loss" display
  divided by total configured targets instead of targets with available data;
  fixed so early readings are accurate.
- **Changing poll interval while paused resumed monitoring** — Adjusting the
  poll interval in Settings while manually paused no longer silently restarts
  monitoring.
- **Bandwidth bar color lost after restart** — Last measured download speed is
  now persisted so the bar retains its color across app restarts.
- **"Check Bandwidth" could not restart after a completed test** — Now
  correctly
  starts a new test on every click.
- **"Check Bandwidth" enabled while paused** — Button is now correctly
  disabled
  when monitoring is manually paused.
- **Launch at login infinite loop** — The LaunchAtLogin toggle no longer loops
  when SMAppService fails.
- **CSV export broken in spreadsheet apps** — Labels containing commas,
  quotes,
  or newlines now export as RFC 4180–compliant quoted fields.

---

## v1.11.3 — 2026-04-05

### Bug Fixes
- **Manual bandwidth check silently ignored after first test** — Clicking
  "Check
  Bandwidth" a second time did nothing if the previous result was still
  cached.
  Each click now starts a new test.

---

## v1.11.2 — 2026-04-05

### New Features
- **Startup loading indicator** — The menubar icon blinks gray until the first
  poll results arrive.

### Changes
- **Bandwidth bar tied to schedule** — The bandwidth quality bar now only
  appears when the auto-test schedule is enabled. The separate "Show bandwidth
  bar" toggle was removed.

---

## v1.11.1 — 2026-04-05

### Bug Fixes
- **Help window too small on first open** — Now opens at a usable size and is
  resizable.
- **Bandwidth schedule not triggering after enabling** — Enabling auto-
  schedule
  from "Disabled" now immediately runs a test instead of waiting for the first
  interval.

---

## v1.11.0 — 2026-04-05

### New Features
- **Auto-update checker** — Checks for new releases on GitHub at startup and
  every 24 hours. Shows a notification window with changelog, download, and
  skip
  options when an update is available.
- **Vibrant app icon** — New icon design.
- **Help window** — A Help menu item opens a reference covering all metrics,
  icons, and status meanings in plain English.

---

## v1.10.2 — 2026-04-05

### Bug Fixes
- **Excess memory use on long sessions** — WiFi history buffer was pre-
  allocated
  at 24 hours of capacity; reduced to 1 hour. Ping history reduced from 24
  hours
  to 6 hours per target (~5–6 MB savings at startup).

---

## v1.10.1 — 2026-04-05

### New Features
- **Bandwidth test auto-starts at launch** — When auto-schedule is enabled, a
  test runs immediately on startup.

### Bug Fixes
- **Help window content forced window too wide** — Text now wraps correctly.
- **Settings window too short** — Height increased; all controls visible
  without
  scrolling.
- **Settings tab highlight capsule clipped** — Fixed on first and last tabs.
- **Bandwidth thresholds inaccessible** — Moved from General to the Thresholds
  tab.
- **No visual gap between status circle and bandwidth bar** — Added a 2 px
  gap.
- **Status icon did not animate during bandwidth test** — Now blinks gray
  while
  a test is running.

---

## v1.10.0 — 2026-04-05

### New Features
- **Manual Pause** — Pause/Resume Monitoring in the main menu stops all ping
  tests on demand.
- **Gateway monitoring** — Your router is pinged every tick and appears as a
  non-removable row in the menu with its own sparkline and latency, used to
  distinguish local vs. ISP faults.
- **Bandwidth quality bar** — A thin colored bar beneath the status circle
  shows
  download quality after a bandwidth test (green ≥ 25 Mbps · yellow < 25 Mbps
  ·
  red < 10 Mbps). Thresholds configurable in Settings.
- **Fault isolation** — Menu shows "local network / router" or "ISP / internet
  outage" based on whether your gateway is reachable.
- **Sparklines per target** — Each target row in the menu shows a small
  sparkline of recent RTT history.
- **Bar chart icon mode** — Alternative icon showing the last 5 status
  readings
  as a bar chart.
- **Configurable thresholds** — Latency, packet loss, and jitter thresholds
  are
  adjustable in Settings.
- **Color theme setting** — Choose System (auto), Light, or Dark.
- **CSV and JSON export** — Added alongside the existing PDF report.
- **Daily log rotation** — Optionally save a daily CSV snapshot to
  `~/Library/Logs/MeOrThem/` (keeps last 30 days).

### Bug Fixes
- **Help window content forced window too wide** — Text now wraps correctly.
- **SSID detection failed on some macOS 14+ systems** — Switched to
  SCDynamicStore as the primary method; networksetup kept as last-resort
  fallback.
- **Loading indicator stuck gray on healthy networks** — Fixed the observer
  trigger.

---

*Earlier versions (pre-v1.10.0) are not listed here.*
