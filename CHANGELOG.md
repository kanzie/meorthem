# Changelog

All notable user-facing changes to Me Or Them, most recent first.
Website, scripts, and internal tooling changes are not listed here.

---

## v1.15.0 — 2026-04-07

### New Features
- **System load detection** — Me Or Them now samples CPU utilisation on every poll tick. When network quality degrades and system load is ≥75%, the dropdown shows a "⚠ High system load (X%) — readings may be affected" advisory. If the degradation event is logged in Previous Disturbances, the cause also notes the high CPU (e.g. "high latency (180ms), high system load (82%)") so you know whether a bad reading was likely a network problem or the machine being resource-constrained.

---

## v1.14.0 — 2026-04-07

### New Features
- **Sidebar settings navigation** — Settings window redesigned with a macOS System Settings–style sidebar (NavigationSplitView), showing each section with an icon and subtitle.

### Changes
- **Trimmed mean quality evaluation** — When 3 or more ping targets are configured, the single best and worst per-metric value are discarded before averaging. This prevents a consistently-slow or unreachable target from inflating the overall network status.
- **"Recovered" timeout** — The "Recovered" label in the dropdown disappears automatically after 3 minutes, keeping the menu clean during stable periods.

---

## v1.13.0 — 2026-04-06

### New Features
- **Per-metric evaluation windows** — Latency, packet loss, and jitter are each averaged over an independent configurable time window before being compared to thresholds. A single noisy poll is diluted by surrounding good samples and never triggers a status change alone.
  - Default windows: Latency 15 s · Packet loss 10 s · Jitter 30 s
  - Jitter's 30-second default guards against AWDL (AirDrop/Handoff) channel scans that fire roughly every 60 seconds and cause brief spikes.

### Changes
- **Evaluation window sliders in Thresholds settings** — Each metric now has its own "Evaluation window" slider (range: poll interval → 300 s). "Reset to Defaults" also resets the windows.

---

## v1.12.0 — 2026-04-06

### New Features
- **Previous Disturbances** — A "Previous Disturbances" submenu in the main menu shows the last 5 network quality events: severity, timestamp, what caused the degradation, and how long it lasted. Active degradations show as "Ongoing"; resolved ones as "Recovered". History persists across restarts.
- **Gray icon on manual pause** — The menubar icon turns gray when monitoring is manually paused. Pausing for a bandwidth test leaves the icon at its current quality color.
- **Launch at login enabled by default** — New installs automatically register for launch at login (can be disabled in Settings → Startup).

### Changes
- **Menu reordered** — Pause/Resume Monitoring moved to the top. Network Details moved below Ping Stats Report. Bottom actions: Help, Settings, About.
- **Update checker reliability** — A failed startup check no longer blocks future checks for 24 hours. Retries up to 5 times at 60-second intervals; timestamp only recorded after a successful response.
- **"Last checked" timestamp in Settings** — The Updates section now shows when the last check occurred and flags network errors.
- **Update window shows full changelog** — The "Update Available" window fetches and displays the changelog so you can review what changed before updating.

### Bug Fixes
- **Previous Disturbances submenu collapsed every second** — The 1-second countdown timer was refreshing (and collapsing) the submenu on every tick. Now only updates when connection history actually changes, and skips updates while the submenu is open.

---

## v1.11.6 — 2026-04-05

### Bug Fixes
- **~20% CPU spike** — WiFi monitoring subscribed to `linkQualityDidChange`, which fires on every RSSI fluctuation — potentially dozens of times per second on a busy network. Each event spawned a `networksetup` subprocess. Removed the subscription; RSSI and Tx rate are already captured on every poll tick. SSID is now cached per connection so the subprocess runs at most once per actual reconnect.

---

## v1.11.5 — 2026-04-05

### Changes
- **Reduced CPU and memory footprint** — Status bar icon rendering is now cached by state, eliminating redundant draw calls during animations. Jitter uses a single-pass calculation. Settings serialization reuses shared encoder/decoder instances. Sparklines skip string formatting when data is unchanged. Circular buffers use tighter capacity bounds (~5–6 MB memory reduction).

---

## v1.11.4 — 2026-04-05

### Bug Fixes
- **Crash on launch with VPN or tunnel adapters** — Network interface lookups now nil-guard socket address pointers before dereferencing.
- **Packet loss percentage wrong during startup** — The "Packet Loss" display divided by total configured targets instead of targets with available data; fixed so early readings are accurate.
- **Changing poll interval while paused resumed monitoring** — Adjusting the poll interval in Settings while manually paused no longer silently restarts monitoring.
- **Bandwidth bar color lost after restart** — Last measured download speed is now persisted so the bar retains its color across app restarts.
- **"Check Bandwidth" could not restart after a completed test** — Now correctly starts a new test on every click.
- **"Check Bandwidth" enabled while paused** — Button is now correctly disabled when monitoring is manually paused.
- **Launch at login infinite loop** — The LaunchAtLogin toggle no longer loops when SMAppService fails.
- **CSV export broken in spreadsheet apps** — Labels containing commas, quotes, or newlines now export as RFC 4180–compliant quoted fields.

---

## v1.11.3 — 2026-04-05

### Bug Fixes
- **Manual bandwidth check silently ignored after first test** — Clicking "Check Bandwidth" a second time did nothing if the previous result was still cached. Each click now starts a new test.

---

## v1.11.2 — 2026-04-05

### New Features
- **Startup loading indicator** — The menubar icon blinks gray until the first poll results arrive.

### Changes
- **Bandwidth bar tied to schedule** — The bandwidth quality bar now only appears when the auto-test schedule is enabled. The separate "Show bandwidth bar" toggle was removed.

---

## v1.11.1 — 2026-04-05

### Bug Fixes
- **Help window too small on first open** — Now opens at a usable size and is resizable.
- **Bandwidth schedule not triggering after enabling** — Enabling auto-schedule from "Disabled" now immediately runs a test instead of waiting for the first interval.

---

## v1.11.0 — 2026-04-05

### New Features
- **Auto-update checker** — Checks for new releases on GitHub at startup and every 24 hours. Shows a notification window with changelog, download, and skip options when an update is available.
- **Vibrant app icon** — New icon design.
- **Help window** — A Help menu item opens a reference covering all metrics, icons, and status meanings in plain English.

---

## v1.10.2 — 2026-04-05

### Bug Fixes
- **Excess memory use on long sessions** — WiFi history buffer was pre-allocated at 24 hours of capacity; reduced to 1 hour. Ping history reduced from 24 hours to 6 hours per target (~5–6 MB savings at startup).

---

## v1.10.1 — 2026-04-05

### New Features
- **Bandwidth test auto-starts at launch** — When auto-schedule is enabled, a test runs immediately on startup.

### Bug Fixes
- **Help window content forced window too wide** — Text now wraps correctly.
- **Settings window too short** — Height increased; all controls visible without scrolling.
- **Settings tab highlight capsule clipped** — Fixed on first and last tabs.
- **Bandwidth thresholds inaccessible** — Moved from General to the Thresholds tab.
- **No visual gap between status circle and bandwidth bar** — Added a 2 px gap.
- **Status icon did not animate during bandwidth test** — Now blinks gray while a test is running.

---

## v1.10.0 — 2026-04-05

### New Features
- **Manual Pause** — Pause/Resume Monitoring in the main menu stops all ping tests on demand.
- **Gateway monitoring** — Your router is pinged every tick and appears as a non-removable row in the menu with its own sparkline and latency, used to distinguish local vs. ISP faults.
- **Bandwidth quality bar** — A thin colored bar beneath the status circle shows download quality after a bandwidth test (green ≥ 25 Mbps · yellow < 25 Mbps · red < 10 Mbps). Thresholds configurable in Settings.
- **Fault isolation** — Menu shows "local network / router" or "ISP / internet outage" based on whether your gateway is reachable.
- **Sparklines per target** — Each target row in the menu shows a small sparkline of recent RTT history.
- **Bar chart icon mode** — Alternative icon showing the last 5 status readings as a bar chart.
- **Configurable thresholds** — Latency, packet loss, and jitter thresholds are adjustable in Settings.
- **Color theme setting** — Choose System (auto), Light, or Dark.
- **CSV and JSON export** — Added alongside the existing PDF report.
- **Daily log rotation** — Optionally save a daily CSV snapshot to `~/Library/Logs/MeOrThem/` (keeps last 30 days).

### Bug Fixes
- **Help window content forced window too wide** — Text now wraps correctly.
- **SSID detection failed on some macOS 14+ systems** — Switched to SCDynamicStore as the primary method; networksetup kept as last-resort fallback.
- **Loading indicator stuck gray on healthy networks** — Fixed the observer trigger.

---

*Earlier versions (pre-v1.10.0) are not listed here.*
