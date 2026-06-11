# MeOrThem

> Is it *you*, or is it *them*?

A network intelligence monitor for macOS that lives quietly in your menubar and answers the question every remote worker, gamer, and developer asks a dozen times a day — and tells you exactly *why*.

**[Download the latest release →](https://github.com/kanzie/meorthem/releases/latest)**

---

## What it does

Me Or Them pings multiple targets simultaneously, probes DNS resolvers with raw UDP packets, monitors hardware interface errors, and runs 17 diagnostic algorithms in the background. When your network misbehaves, it doesn't just change colour — it tells you what's wrong, why it's wrong, and what to do about it.

- **Green circle** — all good
- **Orange circle** — degraded (latency, loss, or jitter above threshold)
- **Red square** — critical outage detected
- **Bar chart mode** — rolling history of the last five readings, visible at a glance

## Resource footprint

Engineered to be invisible:

- **~0.4–1% CPU** — sustained at the default 2-second polling interval, running all 17 diagnostic loops
- **~14–30 MB memory** — stable under continuous 24/7 monitoring
- **Zero Dock presence** — lives entirely in the menubar

## Features

**Core network monitoring**
- Real-time latency, packet loss, and jitter across multiple custom ping targets with per-target sparklines
- Per-metric evaluation windows (default 15 s latency / 10 s loss / 30 s jitter) prevent single-poll blips from changing status
- Adaptive polling — doubles frequency automatically on degradation, restores quietly after three clean polls
- Trimmed outlier rejection — best and worst readings discarded before computing overall status

**Fault isolation**
- Gateway ping runs every tick alongside external targets
- Reports *local network / router* vs *ISP / internet outage* vs *mixed* — not just "something is wrong"

**Network Analysis — 17 diagnostic patterns**
- Elevated latency with gateway attribution and peak-hour breakdown
- Packet loss burst vs. steady detection
- Jitter: inter-poll variance distinguishes congestion from connection instability
- Weak and unstable WiFi signal (RSSI + variance + SNR modulation)
- Session fault profile: minute-by-minute local vs. ISP classification with a clear verdict
- WiFi / latency Pearson correlation (statistically confirms WiFi as root cause)
- Per-target outlier detection (2.5× average latency threshold)
- Bufferbloat (idle RTT baseline vs. latency under load)
- Five DNS-specific patterns: high failure rate, elevated latency, resolver divergence, complete failure, port 53 blocking
- Hardware interface error and drop counter deltas
- MTU / path fragmentation (large-packet probe failures alongside successful normal pings)
- Latency trend via OLS linear regression with R² confidence
- WiFi channel switching detection (band switches called out separately)
- Recurring time-of-day congestion against 30 days of cross-session history
- Automatic traceroute snapshots on green→red degradation (at most once every 5 minutes)

Every finding is confidence-scored against a data-sufficiency multiplier; findings below 40% are silently suppressed.

**Multi-resolver DNS monitoring**
- Raw UDP probes to up to 8 resolvers concurrently every ~30 seconds — bypasses the OS cache entirely
- Pre-configured: Cloudflare (1.1.1.1 + IPv6), Google, Quad9, OpenDNS, AdGuard, system resolver, gateway resolver
- Custom resolvers configurable in Settings; up to 8 active simultaneously
- Fastest responding resolver and trimmed-mean RTT shown in the dropdown; per-resolver chart in Network History
- Auto-pauses repeatedly failing resolvers and re-probes in the background
- DNS data included in all exports (CSV, JSON, PDF)

**WiFi diagnostics**
- BSSID, RSSI, SNR, channel, band, PHY mode, Tx rate, IP address, and router
- No Location permission required — sourced directly from CoreWLAN

**Hardware-level visibility**
- MTU path fragmentation detection via 1472-byte Don't-Fragment probes every ~2.5 minutes
- Kernel-level interface error and drop counter sampling every ~30 seconds
- Automatic traceroute capture on degradation, stored in SQLite and surfaced in Network Analysis

**Network session tracking**
- Each network environment fingerprinted from gateway IP + WiFi band + channel + subnet
- No location permission required
- All samples tagged to session; analysis engine draws accurate per-network conclusions across weeks of history

**Network History charts**
- Interactive charts for latency, packet loss, jitter, WiFi signal, and DNS resolver latency (per-resolver colour-coded series)
- Time windows from 1 hour to 1 year; incident markers and threshold reference lines
- Dashed OLS regression trend line on the latency chart; daily pattern bar chart (average RTT by hour of day)

**Bandwidth testing**
- One-click speed test via bundled Ookla CLI — no separate download required
- Colour-coded bar below the status icon; results included in bufferbloat analysis and all exports

**Exports**
- Gzip-compressed CSV, JSON, or formatted PDF — full history including DNS resolver samples
- Optional daily log rotation to `~/Library/Logs/MeOrThem/`

## Install

1. Download **MeOrThem.dmg** from the [latest release](https://github.com/kanzie/meorthem/releases/latest)
2. Open the DMG and drag **MeOrThem.app** to Applications
3. Launch — macOS will ask about adding it to login items; accept to keep it running in the background

**Requires macOS 14 Sonoma or later · Apple Silicon & Intel**

## Build from source

**Requirements:** macOS 14+, Swift 5.9+, Xcode Command Line Tools

```bash
git clone https://github.com/kanzie/meorthem.git
cd meorthem
bash scripts/build.sh        # → build/MeOrThem.app
bash scripts/make_dmg.sh     # → build/MeOrThem-x.y.z.dmg
```

**Run tests:**
```bash
swift run MeOrThemTests
```

325+ tests covering monitoring logic, metric evaluation, fault isolation, DNS probing, session fingerprinting, SQLite storage, and exports. Custom test runner — no XCTest dependency.

## Architecture

Two Swift modules:

| Module | Role |
|--------|------|
| `MeOrThemCore` | Pure logic library — no AppKit, fully unit-tested |
| `MeOrThem` | Executable app — AppKit/UI layer, wires everything together |

Key components: `AppEnvironment` (Combine wiring + singletons), `MonitoringEngine` (adaptive poll loop), `NetworkAnalyzer` (17 diagnostic patterns), `DNSProber` (raw UDP engine), `MenuBuilder` (in-place NSMenu updates via tags), `SQLiteStore` (WAL mode, five data tiers, one year of history), `MetricsChartsWindowController` (released on close to prevent background CPU).

## Security

- **No shell injection** — all subprocesses use argument arrays, never string interpolation
- **Input validation** — IPs validated with `inet_pton`; hostnames pass a strict shell-character whitelist before any process is spawned
- **Binary integrity** — the bundled speedtest CLI is verified before execution; a tampered or substituted binary is rejected outright
- **No Location permission** — full WiFi details obtained via CoreWLAN without requesting location access
- **No telemetry** — no analytics, no network calls you didn't initiate, no cloud anything
- **Open source and notarized** — every line of code on GitHub; binary signed and notarized by Apple

## License

MIT — see [LICENSE](LICENSE) for details.
