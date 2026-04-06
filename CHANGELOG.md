# Changelog

All notable user-facing changes to Me Or Them are listed here, most recent first.

---

## v1.12.0 — 2026-04-06

### New features
- **Connection History** — Network Details now includes a "Connection History" submenu showing the last 5 quality drops: severity, timestamp, what caused the drop (latency / packet loss / jitter), and how long it lasted. An active ongoing degradation is shown as live.
- **Degradation cause in menu** — When the network is degraded, the menu now shows the specific metric that triggered it (e.g. "Cause: high latency (285ms) · 2m"). After recovery, it shows "Recovered · was: high latency (285ms) · lasted 3m" so you know what happened even after the fact.
- **Gray icon when paused** — The menubar icon turns gray whenever monitoring is paused, whether by user action or while a bandwidth test is running.
- **Launch at login enabled by default** — New installs automatically register for launch at login (can be disabled in Settings → Startup).

### Improvements
- **Menu reordered** — Pause/Resume Monitoring moved to the top. Network Details moved under Ping Stats Report. Bottom actions reordered to: Help, Settings, About.
- **Update checker reliability** — Fixed a bug where a failed startup check (e.g. network not ready at boot) would incorrectly prevent future automatic checks for 24 hours. The checker now retries up to 5 times at 60-second intervals and only records a timestamp after a successful connection.
- **"Last checked" timestamp in Settings** — The Updates section now shows exactly when the last update check occurred. If the check failed, it shows "Failed to connect to github.com" with the date.
- **Update window shows full changelog** — The "Update Available" window now fetches and displays the full changelog from GitHub so you can see everything that changed across all releases before deciding to update.
- **Install instructions in update window** — The update prompt now shows step-by-step install instructions (quit first, drag to Applications, click Replace, relaunch).
- **Singleton guard on update checks** — Concurrent update checks (manual + timer) can no longer overlap.

---

## v1.11.6 — 2026-04-05

### Fixed
- **~20% CPU spike** — Subscribing to `linkQualityDidChange` (a CoreWLAN event that fires on every RSSI fluctuation — potentially dozens of times per second) caused a `networksetup` subprocess to be spawned on each event. Removed the subscription; RSSI is already captured on every poll tick.
- **SSID cache** — Added a per-session SSID cache. The `networksetup` subprocess now runs at most once per actual network change (SSID or link event), not on every monitoring tick.

---

## v1.11.5 — 2025-12-10

### Performance
- **NSImage render cache** — Status bar icon is now cached by state key. Eliminates 6–30+ redundant image allocations per second during animations.
- **Single-pass jitter variance** — Replaced map + reduce with a single reduce, removing a temporary array allocation per ping.
- **Shared JSON encoder/decoder** — Settings serialisation no longer allocates a new encoder/decoder on every change.
- **Sparkline stroke color cache** — Menu item sparkline views cache their NSColor; skips `String(format:)` calls when data is unchanged.

---

## v1.11.4 — 2025-11-28

### Fixed
- **Nil pointer crash on interface lookup** — Gateway and WiFi interface pointers are now nil-guarded before dereference.
- **Fault type cleared on recovery** — "Likely cause" label now correctly disappears when quality returns to green.
- **Hysteresis reset on target removal** — Removing a ping target no longer leaves stale hysteresis state that could affect the next target added with the same ID.
- **Gateway ping not included in overall status** — Gateway results were incorrectly factored into the overall quality status; only user-defined targets now count.
- **Export crash on empty history** — PDF and CSV export no longer crash when called with no recorded data.

---

## v1.11.3 — 2025-11-15

### Fixed
- **Manual bandwidth check silently ignored after first test** — Clicking "Check Bandwidth" a second time did nothing if the previous result was still cached. Fixed: each click now starts a new test.

---

## v1.11.2 — 2025-11-08

### Fixed
- **Startup loading bar persisted after data arrived** — The animated loading indicator on the status bar icon sometimes remained visible after the first real data arrived.
- **Bandwidth bar shown when auto-schedule is disabled** — The bandwidth history bar now only appears when a schedule is configured.

---

## v1.11.1 — 2025-11-01

### Fixed
- **Help window too small on first open** — The Help window now opens at a usable size and is resizable.
- **Bandwidth schedule not triggering after enabling** — Enabling the bandwidth auto-schedule from "Disabled" now immediately runs a test instead of waiting for the first scheduled interval.

---

## v1.11.0 — 2025-10-20

### New features
- **Auto-update checker** — Me Or Them checks for new releases on GitHub at startup and every 24 hours. A notification window appears when an update is available, with a direct download link.
- **Vibrant app icon** — New icon design matching macOS visual guidelines.
- **Help window** — Added a Help menu item that opens a reference window covering all features, icons, and status meanings.

---

## v1.10.2 — 2025-09-28

### Fixed
- **Memory growth over long sessions** — Bounded circular buffers for ping and WiFi history to prevent unbounded memory use during multi-day sessions.

---

## v1.10.1 — 2025-09-14

### Fixed
- **Latency text in menubar disappears when paused** — Now shows "—" instead of hiding entirely.
- **Missing router IP on Ethernet connections** — Network Details now shows the default gateway when on Ethernet.
- **Settings window too narrow** — Minimum width increased; all controls are now readable without resizing.
- **Jitter shown as zero briefly after restart** — Jitter now correctly shows "—" until enough pings have been collected to calculate variance.
- **Adaptive polling not resetting on recovery** — Poll interval now returns to normal after degradation clears.
- **Bandwidth result cleared on relaunch** — Last bandwidth result is now persisted across restarts.
- **Color theme not applied immediately** — Icon color theme change now takes effect without requiring a restart.

---

## v1.10.0 — 2025-09-01

### New features
- **Menubar latency text mode** — Optionally display the current average latency (e.g. "42ms") as text next to the status icon.
- **Adaptive polling** — When degraded, poll frequency doubles automatically to provide faster feedback. Returns to normal on recovery.
- **Fault isolation** — The menu now shows "Likely cause: local network / router" or "Likely cause: ISP / internet outage" based on whether the gateway is reachable.
- **Bandwidth bar in icon** — When auto-bandwidth testing is enabled, a color-coded bar appears at the bottom of the menubar icon showing the last measured download speed.
- **CSV and JSON export** — Added CSV and JSON export options alongside the existing PDF report.
- **Daily log rotation** — Optionally save a daily CSV snapshot to `~/Library/Logs/MeOrThem/` (keeps last 30 days).
- **Color theme setting** — Choose between System (auto), Light, and Dark icon themes.
- **Sparklines per target** — Each target row in the menu now shows a small sparkline of recent RTT history.
- **Bar chart icon mode** — Alternative icon style showing the last 5 status readings as a bar chart.
- **Configurable thresholds** — Latency, packet loss, and jitter thresholds are now adjustable in Settings.
- **Hysteresis** — Status changes only after 2–3 consecutive bad polls, preventing flickering from single-packet anomalies.
- **Gateway monitoring** — The router/gateway is now pinged alongside external targets every tick.

---

*Earlier versions (pre-v1.10.0) are not listed here.*
