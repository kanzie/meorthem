# MeOrThem

> Is it *you*, or is it *them*?

A precision network monitor for macOS that lives quietly in your menubar and answers the question every remote worker, gamer, and developer asks a dozen times a day: "Is the problem on my side or their side?" Simply put, is it Me or Them!.
Supports both WiFi and Ethernet connections. 

**[Download the latest release →](https://github.com/kanzie/meorthem/releases/latest)**

---

## What it does

MeOrThem pings multiple targets (from a pre-existing list or ones the user wants) simultaneously and tells you — in real time — whether a problem is on your end (WiFi, router, local network) or upstream (ISP, internet outage). No guessing. No opening Terminal. One glance at the menubar icon.

- **Green circle** — all good
- **Orange circle** — degraded (latency, loss, or jitter above threshold)
- **Red square** — critical outage detected
- **Bar chart mode** — rolling history of the last five readings, visible without opening the menu

Optionally the app can also show your **bandwidth quality** by testing throughput at regular intervals and indicate quality with a small bar underneath the circle. 
Another option gives the user a average ping latency next to the circle in the taskbar.

**All information you need, in one convenient place**

## Optimized for tiny footprint
The application has undergone many passes to optimize how it consumes resources on your computer. A core tenet in the design was that this application should be as lean and secure as possible. Your CPU wont notice it running, at <1% load doing all its work and at most it consumes around 50MB of memory, which is mostly shared OSX resources cached to disk. 
Simply put, you wont know its there unless you look at your taskbar!

## Features

**Network monitoring**
- Real-time latency across multiple custom ping targets with per-target sparklines
- Packet loss and jitter tracking with configurable colour-coded thresholds
- Optionally display current average latency as a number directly in the menubar
- Intelligent hysteresis — status changes only after 2–3 consecutive bad polls, never on a single blip
- Adaptive polling — frequency doubles automatically when the network is degraded

**Fault isolation**
- Pings your gateway alongside external targets every tick
- Reports *"local network / router"* vs *"ISP / internet outage"* — not just "something is wrong"

**WiFi diagnostics**
- RSSI, SNR, channel, band, PHY mode, Tx rate, IP address, and router
- No Location permission required — uses CoreWLAN and SCDynamicStore

**Bandwidth testing**
- One-click speedtest via bundled Ookla CLI (no separate download)
- Results persist across restarts; colour-coded bar in the menubar icon
- Configurable thresholds and optional auto-schedule

**Reporting**
- Export full ping and WiFi history as PDF, CSV, or JSON
- Optional daily log rotation to `~/Library/Logs/MeOrThem/`

## Install

1. Download **MeOrThem.dmg** from the [latest release](https://github.com/kanzie/meorthem/releases/latest)
2. Open the DMG and drag **MeOrThem.app** to Applications
3. First launch: macOS will inform you that this Application is downloaded from the Internet, 
and then might ask if you want this added to your startup - it is recommended that you accept this. 
MeOrThem has been built with resource efficiency in its core and you will not notice it running on your machine.

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

115 unit tests covering core monitoring logic, metric status, fault isolation, CSV export, jitter calculation, and more. Uses a custom test runner — no XCTest dependency. 
This is why the application uses Dual Module Pattern for its architecture.

## Architecture

Two Swift modules:

| Module | Role |
|--------|------|
| `MeOrThemCore` | Pure logic library — no AppKit, fully unit-tested |
| `MeOrThem` | Executable app — AppKit/UI layer, wires everything together |

Key components: `AppEnvironment` (Combine wiring), `MonitoringEngine` (poll loop), `MenuBuilder` (in-place NSMenu updates), `MetricStore` (hysteresis + fault type), `SpeedtestRunner` (process lifecycle), `StatusBarIconRenderer` (cached NSImage drawing).

## Security

- **No shell injection** — all subprocesses use argument arrays, never string interpolation
- **Input validation** — IPs validated with `inet_pton`; hostnames pass a strict character whitelist
- **Binary integrity** — the bundled speedtest CLI is SHA-256 verified before execution
- **No Location permission** — WiFi details obtained via CoreWLAN/SCDynamicStore APIs
- **Hardened pointer handling** — every network interface pointer is nil-guarded before dereference
- **No telemetry** — no analytics, no network calls you didn't initiate, no cloud anything

## License

MIT — see [LICENSE](LICENSE) for details.
