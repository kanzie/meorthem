# Changelog

All notable user-facing changes to Me Or Them, most recent first.
Website, scripts, and internal tooling changes are not listed here.

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
