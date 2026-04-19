# MeOrThem — Upgrade Implementation Plans

Each entry below is self-contained: no additional codebase research is required to execute it. File paths, function names, schema details, and integration points are all specified.

Status legend: `[ ]` = not started · `[~]` = in progress · `[x]` = done

---

## Tier 1 — High-Impact, Directly Missing

---

### T1-A · Bandwidth History Chart

**What:** Add a bandwidth (speedtest) timeline chart to the existing Charts window alongside the current latency/loss/jitter/WiFi/DNS charts. `speedtest_results` rows are already persisted in SQLite but never visualised.

**Files to modify:**
- `Sources/MeOrThem/UI/Charts/MetricsDataLoader.swift` — add speedtest data loading
- `Sources/MeOrThem/UI/Charts/MetricsChartsView.swift` — add the new chart section

**Files to create:** none

**SQLite:** No schema changes. `speedtest_results` table already exists. Add a query method to `SQLiteStore` if one doesn't already exist (check `querySpeedtestResults(from:to:)`). If absent, add to `Sources/MeOrThemCore/Storage/SQLiteStore.swift`:

```swift
public struct SpeedtestRow {
    public let timestamp: Date
    public let downloadMbps: Double
    public let uploadMbps: Double
    public let latencyMs: Double
    public let jitterMs: Double
    public let isp: String
    public let serverName: String
}

public func speedtestRows(from: Date, to: Date) -> [SpeedtestRow] {
    // SELECT timestamp, download_mbps, upload_mbps, latency_ms, jitter_ms, isp, server_name
    // FROM speedtest_results WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp ASC
}
```

**MetricsDataLoader changes:**
- Add `@Published var speedtestPoints: [SpeedtestRow] = []`
- In the existing `load(window:)` method (which already fetches other data for the selected time window), append a call to `db.speedtestRows(from: windowStart, to: windowEnd)` and assign the result to `speedtestPoints`
- The time window mapping already exists for all other chart types — reuse it exactly

**MetricsChartsView changes:**
- After the DNS chart section, add a `SpeedtestChartView` sub-view (follow the exact same pattern as `LatencyChartView` / `DNSChartView` already in the file)
- Chart type: two `LineMark` series — download (blue) and upload (orange) — plotted against time on the x-axis, Mbps on the y-axis
- Use `PointMark` overlays on each data point (speedtests are sparse — typically 1 per hour — so individual points need to be visible, not just a line)
- Tooltip: on hover, show timestamp + download Mbps + upload Mbps + ISP name (follow the existing `HoverTooltip` pattern with `hoveredDate` state)
- Section header: "Bandwidth" with a bolt SF Symbol, matching the style of the "Latency", "Packet Loss", etc. headers already in the file
- Show "No bandwidth tests recorded" empty state when `loader.speedtestPoints.isEmpty`, matching other charts' empty state pattern
- Threshold lines: draw horizontal `RuleMark` at `settings.bandwidthBarRedMbps` (red, dashed) and `settings.bandwidthBarYellowMbps` (yellow, dashed) for download series only — these thresholds are already in `AppSettings`

**Settings:** No new settings required.

**Tests:** Add to `MeOrThemTests`: insert 5 speedtest rows into an in-memory `SQLiteStore`, query `speedtestRows(from:to:)`, verify count and field values.

**DoD checklist:**
- [ ] `SQLiteStore.speedtestRows(from:to:)` implemented and tested
- [ ] `MetricsDataLoader` loads speedtest data on `load(window:)`
- [ ] Chart renders with two series (download/upload) and threshold lines
- [ ] Hover tooltip works
- [ ] Empty state shown correctly
- [ ] Test added and passing

---

### T1-B · Per-Target Custom Thresholds

**What:** Let each `PingTarget` carry optional threshold overrides. When overrides are present, that target's status is evaluated against its own thresholds instead of the global ones. The `ThresholdsTab` already manages global thresholds; per-target overrides live in `TargetsTab`.

**Files to modify:**
- `Sources/MeOrThemCore/Models/PingTarget.swift` — add optional threshold fields
- `Sources/MeOrThemCore/Storage/MetricStore.swift` — use per-target thresholds in status computation
- `Sources/MeOrThem/UI/Settings/TargetsTab.swift` — add threshold override UI
- `Sources/MeOrThem/UI/Settings/ThresholdsTab.swift` — minor label clarification ("Global Defaults")

**Files to create:** none

**Data model — `PingTarget.swift`:**

Add an `Optional<Thresholds>` field:
```swift
var thresholdOverride: Thresholds? = nil
```

Update `CodingKeys` to include `thresholdOverride`. Since the field is optional and defaults to `nil`, old persisted JSON without this key decodes correctly (the existing custom `init(from:)` already handles missing keys gracefully — follow the same `try? c.decodeIfPresent(...)` pattern).

`Thresholds` is already `Codable` (used in `AppSettings`), so no changes needed to that type.

**MetricStore changes:**
- `MetricStore` already receives the full `[PingTarget]` list (via `AppSettings.shared.pingTargets`)
- In the per-target status computation (wherever `thresholds.latencyYellow`, `.latencyRed`, etc. are compared against each target's RTT/loss/jitter), check if `target.thresholdOverride != nil` and use that struct's values instead of the global `settings.thresholds`
- The overall `overallStatus` is already the max across all target statuses — this needs no change

**TargetsTab UI changes:**
- In the target edit row/form (already exists), add an expandable "Custom Thresholds" disclosure group (use `DisclosureGroup` in SwiftUI)
- Inside: a toggle "Override global thresholds" — when off, `thresholdOverride = nil`; when on, show the same three threshold field pairs (latency yellow/red, loss yellow/red, jitter yellow/red) as `ThresholdsTab` already has, bound to a local `Thresholds` value that gets assigned to `target.thresholdOverride`
- Show a small badge or indicator ("custom") next to target names that have active overrides in the list view

**ThresholdsTab UI changes:**
- Change the section title from "Thresholds" to "Global Default Thresholds" to make the relationship clear

**Tests:**
- Add test: two targets, one with override (latency red = 5ms), one without; simulate a result with 10ms RTT for both; verify overriding target is `.red`, non-overriding target status uses global threshold

**DoD checklist:**
- [ ] `PingTarget.thresholdOverride` field added, Codable, backward-compatible
- [ ] `MetricStore` uses per-target thresholds when override is set
- [ ] `TargetsTab` UI for editing overrides, with disclosure group
- [ ] "custom" indicator badge in target list
- [ ] Test added and passing

---

### T1-C · Stealth Mode — Adaptive Per-Network Probe Detection

**What:** MeOrThem normally measures connectivity using ICMP ping (`/sbin/ping`). Some networks — corporate firewalls, hotel networks, certain ISPs — block or rate-limit ICMP entirely. When this happens, the app would report 100% packet loss or artificially inflated loss figures on a network that is actually working fine for real traffic.

This feature adds two complementary capabilities that work at the **network fingerprint** level (not the per-target level, because ICMP filtering is a network-wide firewall policy):

1. **Stealth Mode** — Automatically detects when ICMP is fully blocked on a network, switches to TCP connectivity probing on that fingerprint, and remembers this preference permanently. Named "Stealth Mode" in the UI.

2. **ICMP Rate Limiting Detection** — Detects when a network throttles (but does not fully block) ICMP, producing misleading loss readings. Surfaces a NetworkAnalyzer finding and suggests increasing the poll interval for that fingerprint, with one-tap confirmation.

Both modes are tracked per connection fingerprint in a new `connection_profiles` table and are fully user-overridable from a new **Connection Profiles** window.

A new **Help section** provides ELI5 explanations of both conditions, linked from all relevant UI surfaces.

---

#### Section A — Data Model: `connection_profiles` Table

**File to modify:** `Sources/MeOrThemCore/Storage/SQLiteStore.swift`

Add new table in `_createSchema()`:

```sql
CREATE TABLE IF NOT EXISTS connection_profiles (
    fingerprint              TEXT    PRIMARY KEY,
    display_name             TEXT    NOT NULL,
    -- Stealth Mode
    stealth_mode             INTEGER NOT NULL DEFAULT 0,   -- 0=ICMP, 1=TCP stealth
    stealth_probe_port       INTEGER,                       -- 443, 80, or 53 (whichever worked)
    stealth_detected_at      REAL,                          -- Unix timestamp of auto-detection
    stealth_source           TEXT,                          -- 'auto' | 'manual'
    icmp_last_ok_at          REAL,                          -- last time ICMP succeeded on this network
    -- ICMP Rate Limiting
    icmp_throttled           INTEGER NOT NULL DEFAULT 0,   -- 0=normal, 1=throttled detected
    icmp_throttled_at        REAL,                          -- Unix timestamp of detection
    preferred_poll_interval  REAL,                          -- override poll interval (nil = use global)
    poll_interval_source     TEXT,                          -- 'auto' | 'manual' | nil
    -- Lifetime stats
    first_seen               REAL    NOT NULL,
    last_seen                REAL    NOT NULL,
    total_sessions           INTEGER NOT NULL DEFAULT 1
);
```

Add public API to `SQLiteStore`:

```swift
public struct ConnectionProfile {
    public let fingerprint: String
    public let displayName: String
    public var stealthMode: Bool
    public var stealthProbePort: Int?
    public var stealthDetectedAt: Date?
    public var stealthSource: String?           // "auto" | "manual"
    public var icmpLastOkAt: Date?
    public var icmpThrottled: Bool
    public var icmpThrottledAt: Date?
    public var preferredPollInterval: Double?
    public var pollIntervalSource: String?      // "auto" | "manual"
    public let firstSeen: Date
    public let lastSeen: Date
    public let totalSessions: Int
}

// CRUD
public func upsertConnectionProfile(fingerprint: String, displayName: String)
public func connectionProfile(fingerprint: String) -> ConnectionProfile?
public func allConnectionProfiles() -> [ConnectionProfile]
public func setStealthMode(_ enabled: Bool, port: Int?, source: String, fingerprint: String)
public func setICMPThrottled(_ throttled: Bool, fingerprint: String)
public func setPreferredPollInterval(_ interval: Double?, source: String?, fingerprint: String)
public func touchConnectionProfile(fingerprint: String)  // updates last_seen + total_sessions
public func updateICMPLastOk(fingerprint: String)
```

All write methods are fire-and-forget (`queue.async`). Read methods are synchronous (`queue.sync`), called from background tasks.

---

#### Section B — TCPProber (core infrastructure)

**File to create:** `Sources/MeOrThemCore/Monitoring/TCPProber.swift`

```swift
public struct TCPProbeResult {
    public let rttMs: Double?       // nil = timeout / refused
    public let reachable: Bool
    public let port: Int
}

public struct TCPProber {
    /// Attempts a TCP connect to host:port and measures time-to-connect.
    /// Uses URLSessionStreamTask — no subprocess, no special entitlements.
    /// Timeout: 3 seconds. Cancels immediately after connect.
    /// Returns reachable=false on timeout or any network error.
    public static func probe(host: String, port: Int) async -> TCPProbeResult

    /// Tries ports [443, 80, 53] in order. Returns the first successful result,
    /// or nil if all fail. Used during stealth mode detection.
    public static func probeAny(host: String) async -> TCPProbeResult?
}
```

`probe(host:port:)` implementation: create `URLSession(configuration: .ephemeral)`, open a `streamTask(withHostName:port:)`, call `resume()`, record `Date()`, await `readData(ofMinLength:1 maxLength:1 timeout:3)`. On any data received or connection established, record elapsed time as RTT. Cancel the task immediately. On timeout or error, return `reachable: false`.

**Important:** `URLSessionStreamTask` connects over TCP — not raw SYN only. The remote must accept the connection to measure RTT. Hosts like `1.1.1.1:443` (Cloudflare) and `8.8.8.8:443` (Google) always accept connections, making them reliable probe targets.

---

#### Section C — Stealth Mode Detection State Machine

**File to modify:** `Sources/MeOrThem/App/AppEnvironment.swift`

Add a per-fingerprint detection state machine. The state is held in memory only (not persisted — it resets each time you join a network, which is the correct behavior):

```swift
private enum StealthDetectionState {
    case unknown                    // initial — haven't decided yet
    case probingICMP(failCount: Int) // counting consecutive all-target failures
    case testingTCP                  // running TCP probe now (one-shot gate)
    case confirmed                   // decision made; written to connection_profiles
}

private var stealthState: StealthDetectionState = .unknown
private let stealthDetectionThreshold = 5  // consecutive total-loss polls before probing TCP
```

**Detection logic — called from the `metricStore.$latestPing` sink (after each poll):**

```swift
private func evaluateStealthDetection(results: [UUID: PingResult]) {
    // Skip if already confirmed for this fingerprint
    guard case .confirmed = stealthState else { return }  // wrong — fix:
    // Skip if stealth decision already made for this fingerprint
    guard let fp = currentSessionFingerprint else { return }
    if let profile = sqliteStore.connectionProfile(fingerprint: fp), profile.stealthMode {
        // Already in stealth mode — nothing to detect
        return
    }

    // Skip detection if VPN is active (T2-A): tunnel alters ICMP behavior
    if metricStore.vpnInterface != nil { return }

    let allFailed = results.values.allSatisfy { r in
        r.lossPercent >= 100.0 && r.rtt == nil
    }

    switch stealthState {
    case .unknown, .probingICMP where !allFailed:
        // Any success resets the counter and confirms ICMP works
        stealthState = .unknown
        sqliteStore.updateICMPLastOk(fingerprint: fp)

    case .unknown where allFailed:
        stealthState = .probingICMP(failCount: 1)

    case .probingICMP(let n) where allFailed && n + 1 < stealthDetectionThreshold:
        stealthState = .probingICMP(failCount: n + 1)

    case .probingICMP(let n) where allFailed && n + 1 >= stealthDetectionThreshold:
        stealthState = .testingTCP
        Task.detached(priority: .utility) { [weak self] in
            await self?.runStealthProbe(fingerprint: fp)
        }

    default: break
    }
}
```

**`runStealthProbe(fingerprint:)`:**

```swift
private func runStealthProbe(fingerprint: String) async {
    // Must probe external hosts, not just the gateway (gateway TCP may be closed)
    let externalTargets = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    var successPort: Int? = nil

    for host in externalTargets {
        if let result = await TCPProber.probeAny(host: host) {
            successPort = result.port
            break
        }
    }

    await MainActor.run {
        stealthState = .confirmed
        if let port = successPort {
            // ICMP blocked, TCP works — switch to stealth mode
            sqliteStore.setStealthMode(true, port: port, source: "auto", fingerprint: fingerprint)
            metricStore.stealthModeActive = true
            metricStore.stealthProbePort = port
            notifyStealthModeEnabled()
        } else {
            // TCP also failed — genuine network outage, not ICMP filtering
            // Let the normal incident tracking handle it; do not set stealth mode
        }
    }
}
```

**On new session open** (in the `metricStore.$latestWifi` sink where `sqliteStore.openSession` is called):

```swift
// Reset detection state for the new network
stealthState = .unknown

// Apply previously remembered settings for this fingerprint
if let profile = sqliteStore.connectionProfile(fingerprint: newFingerprint) {
    let stealthActive = profile.stealthMode
    let pollOverride  = profile.preferredPollInterval
    metricStore.stealthModeActive = stealthActive
    metricStore.stealthProbePort  = profile.stealthProbePort ?? 443
    if let interval = pollOverride {
        monitoringEngine.restart(interval: interval)
    } else {
        monitoringEngine.restart(interval: settings.pollIntervalSecs)
    }
} else {
    // First visit to this network — upsert a profile row
    sqliteStore.upsertConnectionProfile(fingerprint: newFingerprint,
                                        displayName: key.displayName)
    metricStore.stealthModeActive = false
}
```

**On session leave** (when fingerprint changes away from a throttled network, restore global poll interval):

```swift
monitoringEngine.restart(interval: settings.pollIntervalSecs)
metricStore.stealthModeActive = false
```

**ICMP re-verification on reconnect to known stealth fingerprint:**

When `stealthState == .confirmed` and `profile.stealthMode == true`, on the first 3 polls quietly run one parallel ICMP ping to a single target alongside the TCP probes. If any ICMP reply arrives:
```swift
// ICMP now works — firewall rule changed
sqliteStore.setStealthMode(false, port: nil, source: "auto", fingerprint: fp)
metricStore.stealthModeActive = false
notifyICMPRestored()
```

---

#### Section D — PingMonitor: Stealth Mode Routing

**File to modify:** `Sources/MeOrThemCore/Monitoring/PingMonitor.swift`

Add a `stealthMode: Bool` and `stealthPort: Int` property (set by `AppEnvironment` before each tick via `MonitoringEngine`'s existing configuration path, or passed directly):

In `run(target:)`:
```swift
if stealthMode && !target.isSystem {
    // System targets (gateway) are skipped in stealth mode — gateway rarely has TCP ports open
    return await TCPProber.probe(host: target.host, port: stealthPort)
        .asPingResult()   // TCPProbeResult → PingResult adapter
} else {
    // Existing ICMP path
}
```

**Gateway in stealth mode:** Gateway monitoring returns a synthetic "N/A" result with a note. The menu target row for Gateway shows "Stealth — no gateway ping" instead of RTT. The fault-isolation logic (local vs ISP distinction) is suspended while stealth mode is active.

**Jitter in stealth mode:** TCP produces one measurement per poll. Jitter is `nil` in stealth mode — the `JitterCalculator` requires multiple samples from the same ping burst. Menu and charts display "—" for jitter when stealth mode is active.

**`PingResult` adapter:**
```swift
extension TCPProbeResult {
    func asPingResult() -> PingResult {
        PingResult(rtt: rttMs, lossPercent: reachable ? 0.0 : 100.0, jitter: nil)
    }
}
```

**MetricStore additions:**
```swift
@Published var stealthModeActive: Bool = false
@Published var stealthProbePort: Int = 443
```

---

#### Section E — ICMP Rate Limiting Detection

This is separate from full blocking. Rate limiting produces regular, partial loss (typically 20–66%) where successful pings have normal RTT.

**File to modify:** `Sources/MeOrThem/Analysis/NetworkAnalyzer.swift`

Add **Pattern #18 — ICMP Rate Limiting** (evaluated only when stealth mode is NOT active for the session):

Detection criteria (all must be true):
1. Average loss across all targets is between **15% and 80%** — above noise, below total block
2. Loss is **consistent across all targets simultaneously** — correlation coefficient > 0.7 between per-target loss time series. (Per-host failures that are uncorrelated suggest real packet loss, not rate limiting.)
3. Successful ping RTTs are **within normal range** (< latencyYellow threshold) — latency isn't elevated, just packets drop. Genuine congestion raises latency AND loss together.
4. The pattern persists for **at least 5 minutes** of samples — not a transient blip

When all four conditions are met, emit finding:
- Category: `.configuration`
- Confidence: `0.70` base, scaled by data sufficiency multiplier
- Title: "ICMP Rate Limiting Detected"
- Detail text (shown in Network Analysis panel): 
  > "This network appears to throttle ping traffic — about X% of pings are being silently dropped by the network, even though your connection is working normally. This makes packet loss readings unreliable. Increasing the monitoring interval reduces how often pings are sent, which may reduce how many are dropped. [Learn more…]"
  
  "Learn more…" is a `Button` that calls `HelpWindowController.show(section: .icmpRateLimiting)`.

**Actionable suggestion on finding:**

When this finding is surfaced, add a `suggestedAction` to the `Finding` struct (add this field if it doesn't exist):
```swift
struct Finding {
    // ... existing fields ...
    var suggestedAction: SuggestedAction?
}

enum SuggestedAction {
    case increasePollInterval(currentInterval: Double, suggestedInterval: Double, fingerprint: String)
}
```

In the Network Analysis UI (`NetworkAnalysisWindowController.swift` / `FindingCard`), when a finding has a `suggestedAction`, render an action button below the detail text. For `.increasePollInterval`:

```
[ Increase to Xs for this network ]
```

Tapping this button:
1. Calls `sqliteStore.setPreferredPollInterval(suggestedInterval, source: "auto", fingerprint: fp)`
2. If current fingerprint matches → calls `monitoringEngine.restart(interval: suggestedInterval)` immediately
3. Shows inline confirmation: "Poll interval set to Xs for this network."

**Suggested interval logic:** Round up to the next standard interval step above the current one:
- 2s → suggest 5s
- 5s → suggest 10s
- 10s → suggest 30s
- 30s → suggest 60s
- 60s → no suggestion (already at maximum; suggest Stealth Mode instead)

**File to modify:** `Sources/MeOrThem/App/AppEnvironment.swift`

Add a `metricStore.$latestPing` sink that also evaluates rate limiting in real time (separate from the NetworkAnalyzer which runs on completed sessions). When rate limiting is detected live (using simplified criteria — just criteria 1+2 above over a 2-minute rolling window), update `metricStore.icmpThrottledSuspected = true`. This is used by the menu to show a warning icon.

**MetricStore addition:**
```swift
@Published var icmpThrottledSuspected: Bool = false
```

**MenuBuilder:** When `metricStore.icmpThrottledSuspected == true` and stealth mode is not active, add a warning row in the summary section (above the Packet Loss row, since the loss figure is unreliable):
```
⚠ Loss readings may be unreliable (rate limited)
```
Tapping this menu item opens the Help section on ICMP rate limiting.

---

#### Section F — Stealth Mode Notifications

**File to modify:** `Sources/MeOrThem/Notifications/AlertManager.swift`

Add two new notification types alongside the existing degradation notifications. Register an additional `UNNotificationCategory` with identifier `"com.meorthem.stealth"`.

**Stealth mode enabled notification:**
```
Title: "Stealth Mode Enabled"
Body:  "Ping is blocked on this network. MeOrThem switched to TCP monitoring to keep measuring accurately."
Actions: [UNNotificationAction("LEARN_MORE", "Learn More", .foreground),
          UNNotificationAction("VIEW_PROFILES", "Network Settings", .foreground)]
```

**ICMP restored notification:**
```
Title: "Standard Monitoring Restored"
Body:  "Ping is working again on this network. Switched back from Stealth Mode."
```

**ICMP rate limiting notification** (fires once per fingerprint, not on every session):
```
Title: "Ping Traffic May Be Throttled"
Body:  "This network appears to limit ping traffic. Tap to see a suggested fix."
Actions: [UNNotificationAction("VIEW_ANALYSIS", "View Analysis", .foreground)]
```

In `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`:
- `LEARN_MORE` → `HelpWindowController.show(section: .stealthMode)`
- `VIEW_PROFILES` → `showConnectionProfilesWindow()`
- `VIEW_ANALYSIS` → `showNetworkAnalysis()`

---

#### Section G — Connection Profiles Window

**File to create:** `Sources/MeOrThem/UI/ConnectionProfilesWindowController.swift`
**File to create:** `Sources/MeOrThem/UI/ConnectionProfilesView.swift`

**Window:** 780×520, titled "Network Connections", resizable, follows same NSWindowController + NSHostingController pattern as `NetworkAnalysisWindowController`. Released on close via `NSWindow.willCloseNotification`. Added to `AppDelegate` with the same `private var connectionProfilesWindowController` + observer token pattern used for charts and network analysis.

**Menu entry:** Add "Network Connections…" to the Advanced submenu (tag 15) below "Network Analysis", using the next available tag.

**ConnectionProfilesView layout:**

Split panel (matching Network Analysis window style):
- **Left panel** — List of all `ConnectionProfile` rows from `allConnectionProfiles()`, sorted by `last_seen` descending. Each row shows:
  - Network display name (e.g., "Home WiFi · 5 GHz ch. 36")
  - Last seen timestamp (relative, e.g., "2 hours ago")
  - Status badge: "Stealth Mode" (blue) | "Throttled" (yellow) | "Normal" (grey)
  - Stealth Mode icon (lock symbol) when active

- **Right panel** — Detail view for the selected profile, with sections:

  **Identity**
  - Display name (editable `TextField`)
  - Fingerprint (read-only, monospaced, copyable)
  - First seen / Last seen / Total sessions

  **Probe Mode**
  - Current mode: "Standard (ICMP Ping)" or "Stealth Mode (TCP port 443)"
  - How it was set: "Auto-detected on [date]" or "Set manually"
  - Toggle: "Use Stealth Mode" (`Toggle`, updates `connection_profiles.stealth_mode`)
  - When toggled on manually: `stealth_source = "manual"`; when toggled off: reverts to ICMP on next session for this fingerprint
  - If stealth mode is active and current fingerprint matches: change takes effect immediately (calls `monitoringEngine` + `metricStore`)
  - Info button (ⓘ) → `HelpWindowController.show(section: .stealthMode)`

  **Ping Throttling**
  - Status: "Rate limiting detected on [date]" or "No throttling detected"
  - Preferred poll interval: "Xs (auto-suggested)" or "Xs (manual)" or "Global default (Ys)"
  - Stepper/Picker to manually set preferred interval: same options as global poll interval (2/5/10/30/60s), plus "Use global default"
  - When changed: `sqliteStore.setPreferredPollInterval(...)` + apply immediately if on this network
  - Info button (ⓘ) → `HelpWindowController.show(section: .icmpRateLimiting)`

  **Statistics** (loaded async from SQLite)
  - Avg latency / loss / jitter across all sessions on this fingerprint
  - Total uptime hours monitored
  - Number of incidents

  **Actions**
  - "Re-test Probe Mode" button — resets `stealthState = .unknown` for the current fingerprint (if currently connected), triggering a fresh detection run on the next 5 polls
  - "Forget This Network" button — deletes the `connection_profiles` row (confirmation alert first); also deletes associated `network_sessions` rows

---

#### Section H — Help Content (ELI5)

**File to modify:** `Sources/MeOrThem/UI/HelpWindowController.swift`

Add a `section` parameter to `show()`:
```swift
static func show(section: HelpSection = .overview)

enum HelpSection: String {
    case overview
    case stealthMode
    case icmpRateLimiting
}
```

When a section is specified, the help window scrolls to or highlights that section after opening.

**Help content to add — two new sections:**

---

**Section: "Stealth Mode — Monitoring on Restricted Networks"**

> **What's happening?**
> 
> The internet uses many different "languages" to send information. MeOrThem normally checks your connection using something called ICMP ping — think of it like knocking on a door and waiting to hear a knock back. It's a simple, fast, and reliable way to check if someone's home.
>
> Some networks — like those in offices, hotels, airports, and schools — have firewalls that don't allow ping traffic. It's not that the internet is broken; it's that the doorbell has been disconnected. If MeOrThem kept using ping on these networks, it would report 100% packet loss even though your connection is completely fine.
>
> **What does Stealth Mode do?**
>
> When MeOrThem detects that ping is blocked, it automatically switches to a different method: TCP probing. Instead of a knock, it tries to open a door (like the door your browser uses for HTTPS). This works on virtually every network because blocking it would also block all websites.
>
> MeOrThem remembers that this network needs Stealth Mode, so it switches automatically every time you connect. Your measurements stay accurate without you having to do anything.
>
> **Is this safe and legal?**
>
> Yes, completely. Stealth Mode doesn't do anything a web browser doesn't already do — it simply connects to well-known servers (like Cloudflare and Google) over the standard HTTPS port. It's the monitoring equivalent of visiting a website to check if your internet is working.
>
> **What's different in Stealth Mode?**
>
> - Jitter readings are not available (this method only takes one measurement per check, not three)
> - Gateway ping (your router) is not available (routers usually don't run web servers)
> - The fault-isolation feature ("Is it local or the ISP?") is suspended

---

**Section: "ICMP Rate Limiting — When Ping Traffic is Throttled"**

> **What's happening?**
>
> Some networks don't completely block ping traffic, but they do limit how much of it is allowed. Imagine sending 10 knocks on a door but only 4 get through — not because nobody's home, but because a doorman is only passing along some of the knocks.
>
> When this happens, MeOrThem sees artificially high packet loss (e.g., 40–60%) even though your actual connection is working fine. Videos play, websites load, calls work — but the ping numbers look bad.
>
> **How does MeOrThem detect this?**
>
> It looks for a specific pattern: packet loss that happens consistently across all monitored targets at the same time, while your actual round-trip times (for the pings that do get through) remain completely normal. Genuine network problems raise both latency AND loss together; rate limiting raises only loss.
>
> **What should you do?**
>
> Increasing the monitoring interval reduces how frequently pings are sent, which often means fewer are throttled (the doorman isn't as busy). MeOrThem can set a preferred interval just for this network — your other networks keep their normal settings.
>
> If the problem persists, enabling Stealth Mode entirely bypasses this issue by switching away from ping altogether.

---

**Link placements:**

| Location | Links to |
|----------|----------|
| NetworkAnalyzer finding card for ICMP Rate Limiting | `icmpRateLimiting` |
| NetworkAnalyzer finding card for ICMP Blocking / Stealth | `stealthMode` |
| Connection Profiles window, Probe Mode section (ⓘ button) | `stealthMode` |
| Connection Profiles window, Ping Throttling section (ⓘ button) | `icmpRateLimiting` |
| Menu warning row "⚠ Loss readings may be unreliable" | `icmpRateLimiting` |
| Stealth Mode enabled notification action "Learn More" | `stealthMode` |
| Status bar menu item for target row when in stealth mode (tooltip) | `stealthMode` |

---

#### Section I — index.html Updates

**File to modify:** `index.html`

Add "Stealth Mode" as a featured capability in the features section. Suggested placement: after the existing network diagnostics feature block and before export/reporting.

**Feature block copy:**

> **Stealth Mode — Works Everywhere**
>
> Some networks block traditional ping traffic — offices, hotels, airports. Most monitoring tools go blind. MeOrThem detects this automatically and switches to an alternative measurement method that works on any network, without any configuration. Your metrics stay accurate whether you're at home, in a café, or behind a corporate firewall.

Keep the tone consistent with existing copy. Add an appropriate icon (a shield or lock SF Symbol rendered as an SVG inline, consistent with other feature icons on the page).

---

#### Section J — `PingTarget.ProbeMode` (backward-compatible escape hatch)

**File to modify:** `Sources/MeOrThemCore/Models/PingTarget.swift`

The per-target `ProbeMode` enum is still useful as a manual override for the rare case where one specific target blocks ICMP but the network does not. It is NOT the primary feature — it's an advanced escape hatch.

```swift
enum ProbeMode: String, Codable, CaseIterable {
    case networkDefault = "Network Default"   // use whatever the network profile says
    case icmp           = "Force ICMP"
    case tcp443         = "Force TCP 443"
    case tcp80          = "Force TCP 80"
}

var probeMode: ProbeMode = .networkDefault
```

`networkDefault` defers to the fingerprint-level setting (stealth mode or standard). The other cases override it for that specific target regardless of network policy.

This field is hidden under an "Advanced" disclosure group in `TargetsTab` — not shown by default. The picker is disabled for system targets (Gateway).

---

#### Files Summary

**Create:**
- `Sources/MeOrThemCore/Monitoring/TCPProber.swift`
- `Sources/MeOrThem/UI/ConnectionProfilesWindowController.swift`
- `Sources/MeOrThem/UI/ConnectionProfilesView.swift`

**Modify:**
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — `connection_profiles` table + full CRUD API
- `Sources/MeOrThemCore/Models/PingTarget.swift` — `ProbeMode` enum (advanced override only)
- `Sources/MeOrThemCore/Monitoring/PingMonitor.swift` — stealth mode routing
- `Sources/MeOrThemCore/Storage/MetricStore.swift` — `stealthModeActive`, `stealthProbePort`, `icmpThrottledSuspected`
- `Sources/MeOrThem/App/AppEnvironment.swift` — detection state machine, session-open profile loading, rate limiting live evaluation
- `Sources/MeOrThem/Analysis/NetworkAnalyzer.swift` — pattern #18 (ICMP rate limiting), `Finding.suggestedAction`
- `Sources/MeOrThem/Notifications/AlertManager.swift` — stealth mode and rate limiting notifications
- `Sources/MeOrThem/UI/Menu/MenuBuilder.swift` — stealth mode indicator, rate limiting warning row, "Network Connections…" in Advanced submenu
- `Sources/MeOrThem/UI/Settings/TargetsTab.swift` — advanced ProbeMode picker (hidden by default)
- `Sources/MeOrThem/UI/HelpWindowController.swift` — two new ELI5 sections + `show(section:)` API
- `Sources/MeOrThem/App/AppDelegate.swift` — Connection Profiles window wiring, new notification action handlers
- `Sources/MeOrThem/UI/NetworkAnalysisWindowController.swift` — `suggestedAction` button rendering in FindingCard
- `index.html` — Stealth Mode feature block

---

#### Tests

- `TCPProber.probe`: test against `1.1.1.1:443` (live), assert `reachable == true` and `rttMs != nil`
- `TCPProber.probeAny`: test that it tries multiple ports and returns the first success
- `SQLiteStore` — `connection_profiles` table: upsert, update stealth mode, update throttled state, preferred interval round-trip
- Detection logic: mock `MonitoringEngine` + 5 consecutive all-loss results → verify `runStealthProbe` is triggered (use dependency injection or `@testable import`)
- NetworkAnalyzer pattern #18: construct session with synthetic ping_samples showing 40% uniform loss with normal RTT → verify finding is emitted at confidence ≥ 0.70
- Interval suggestion: verify 2s → 5s, 5s → 10s, 10s → 30s, 30s → 60s, 60s → no suggestion

---

#### DoD Checklist

- [ ] `connection_profiles` table created in schema with all columns
- [ ] Full CRUD API on `SQLiteStore` for profiles
- [ ] `TCPProber.swift` implemented (connect-and-cancel, RTT measurement, `probeAny`)
- [ ] Detection state machine in `AppEnvironment` transitions correctly through all states
- [ ] Stealth mode applied correctly on session open for known fingerprints
- [ ] ICMP re-verification runs on reconnect to stealth fingerprint
- [ ] VPN active → stealth detection suppressed
- [ ] Gateway shows "N/A — Stealth Mode" in menu and charts when stealth is active
- [ ] Jitter shows "—" in stealth mode
- [ ] NetworkAnalyzer pattern #18 (ICMP rate limiting) implemented with `suggestedAction`
- [ ] Suggested interval action button renders in Finding card and applies immediately
- [ ] Live rate limiting detection updates `metricStore.icmpThrottledSuspected`
- [ ] Menu warning row shown when throttling suspected
- [ ] Three new notification types (stealth enabled, ICMP restored, rate limiting)
- [ ] Notification actions route correctly (`LEARN_MORE`, `VIEW_PROFILES`, `VIEW_ANALYSIS`)
- [ ] Connection Profiles window opens from Advanced submenu
- [ ] All profile fields editable and applied immediately when on matching network
- [ ] "Re-test Probe Mode" resets detection state
- [ ] "Forget This Network" deletes profile + sessions with confirmation
- [ ] Help window has two new ELI5 sections, scrollable to by `show(section:)`
- [ ] All 7 help link placements wired correctly
- [ ] Per-target `ProbeMode` escape hatch in TargetsTab advanced section
- [ ] `index.html` updated with Stealth Mode feature block
- [ ] All tests passing

---

### T1-D · Incident History Window

**What:** A dedicated window listing all degradation incidents from the `incidents` SQLite table, with sortable columns, date filtering, severity icons, duration, and a "view in charts" button that opens the Charts window pre-loaded to that time range.

**Files to modify:**
- `Sources/MeOrThem/App/AppDelegate.swift` — add menu item + window controller wiring
- `Sources/MeOrThem/UI/Menu/MenuBuilder.swift` — add "Incident History" item in Advanced submenu

**Files to create:**
- `Sources/MeOrThem/UI/IncidentHistoryWindowController.swift` — NSWindowController wrapper
- `Sources/MeOrThem/UI/IncidentHistoryView.swift` — SwiftUI content view

**SQLiteStore — add public query method** (the `incidents` table exists; add a query API if absent):
```swift
public struct IncidentRow {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?        // nil = still open
    public let severity: Int         // 1 = yellow, 2 = red
    public let peakSeverity: Int
    public let cause: String
}

public func incidentRows(from: Date, to: Date, limit: Int = 500) -> [IncidentRow]
public func allIncidentRows(limit: Int = 500) -> [IncidentRow]
```

**IncidentHistoryWindowController.swift:**
- Follow the exact same NSWindowController + NSHostingController pattern as `NetworkAnalysisWindowController` and `MetricsChartsWindowController`
- Window size: 700×480, resizable, titled "Incident History"
- Released on close (do not cache) — follow `NSWindow.willCloseNotification` observer pattern used in `AppDelegate` for charts window

**IncidentHistoryView.swift:**
- State: `@State private var rows: [IncidentRow] = []`, `@State private var isLoading = true`
- Load incidents in `.task { }` on appear: `Task.detached { db.allIncidentRows(limit: 500) }` → assign on main
- Layout: `List` with each row showing:
  - Colored dot: yellow (severity 1) or red (severity 2/peak)
  - Start time formatted as `"MMM d, HH:mm"`
  - Duration: if `endedAt` is set → formatted duration (e.g. "2m 14s"); else "Ongoing"
  - Cause string (truncated to 60 chars with ellipsis)
  - "View in Charts" button: calls a closure/callback that opens `MetricsChartsWindowController` and jumps to the time range (pass `startedAt ± 5min` as the window)
- Toolbar: date range picker (from/to `DatePicker`) with "Filter" button that re-runs the query with `incidentRows(from:to:)`, and "Clear All" button (calls `sqliteStore.clearAllIncidents()` after `NSAlert` confirmation — `clearAllIncidents()` already exists)
- Empty state: "No incidents recorded" with secondary text

**AppDelegate wiring:**
- Add `private var incidentHistoryWindowController: IncidentHistoryWindowController?` (same pattern as `chartsWindowController`)
- Add method `showIncidentHistory()` that lazy-initialises and calls `window.makeKeyAndOrderFront`
- Store `NSWindow.willCloseNotification` observer token as `incidentHistoryWindowObserver` to nil out the controller on close (identical to `chartsWindowObserver` pattern)

**MenuBuilder wiring:**
- Add "Incident History…" item to the Advanced submenu (tag 15), immediately after "Network Analysis", using tag 16 (verify tag 16 is not already in use — if so, use the next available tag ≥ 17)

**Tests:** Add test: insert 3 incidents into in-memory `SQLiteStore`, call `allIncidentRows(limit:)`, verify count and field ordering.

**DoD checklist:**
- [ ] `SQLiteStore.allIncidentRows` / `incidentRows(from:to:)` implemented and tested
- [ ] `IncidentHistoryWindowController` and `IncidentHistoryView` created
- [ ] Window opens from Advanced submenu
- [ ] Date filter and Clear All work
- [ ] "View in Charts" button opens charts at the incident's time range
- [ ] Window releases on close (no memory leak)
- [ ] Test added and passing

---

### T1-E · Notification Actions

**What:** Add a "View Charts" `UNNotificationAction` to degradation alerts. Tapping it brings the Charts window to the foreground, pre-selected to the 1-hour window (which will show the degradation event). Low code change, high daily-use value.

**Files to modify:**
- `Sources/MeOrThem/Notifications/AlertManager.swift` — register category + action, set `categoryIdentifier`
- `Sources/MeOrThem/App/AppDelegate.swift` — implement `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`

**Files to create:** none

**AlertManager changes:**

1. Define constants at top of file:
   ```swift
   private let categoryID = "com.meorthem.degradation"
   private let actionViewCharts = "VIEW_CHARTS"
   ```

2. In `requestPermission()`, after requesting authorization, register the category:
   ```swift
   let action = UNNotificationAction(
       identifier: actionViewCharts,
       title: "View Charts",
       options: [.foreground]   // .foreground brings app to front
   )
   let category = UNNotificationCategory(
       identifier: categoryID,
       actions: [action],
       intentIdentifiers: [],
       options: []
   )
   UNUserNotificationCenter.current().setNotificationCategories([category])
   ```

3. In `fire(status:)`, set `content.categoryIdentifier = categoryID`

**AppDelegate changes:**

1. Add `UNUserNotificationCenterDelegate` conformance
2. Set `UNUserNotificationCenter.current().delegate = self` in `applicationDidFinishLaunching`
3. Implement:
   ```swift
   func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
       if response.actionIdentifier == "VIEW_CHARTS" {
           showChartsWindow()   // already exists in AppDelegate
       }
       completionHandler()
   }
   ```

**Note:** `UNNotificationAction` with `.foreground` option automatically brings the app to the front when tapped. The `showChartsWindow()` method already exists in `AppDelegate` — no new window management needed.

**Tests:** This feature is entirely notification-system wiring; no unit-testable logic. Manual verification is the test.

**DoD checklist:**
- [ ] Notification category registered with "View Charts" action
- [ ] `content.categoryIdentifier` set in `fire(status:)`
- [ ] `UNUserNotificationCenterDelegate` implemented in `AppDelegate`
- [ ] Tapping "View Charts" in notification opens Charts window
- [ ] Existing notification behavior (banner, sound toggle) unchanged

---

## Tier 2 — Backend Depth / Diagnostic Power

---

### T2-A · VPN / Tunnel Interface Detection

**What:** Detect when a VPN or tunnel interface is active (`utun*`, `ipsec*`, `ppp*`) using `getifaddrs`, tag network sessions with VPN state, and surface a warning in the NetworkAnalyzer findings and the menu's "Network Details" section. Prevents users from misattributing VPN tunnel overhead as ISP degradation.

**Files to modify:**
- `Sources/MeOrThemCore/Utilities/NetworkInfo.swift` — add VPN detection function
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — add `vpn_active` column to `network_sessions`
- `Sources/MeOrThem/App/AppEnvironment.swift` — detect VPN on session open and on each WiFi fingerprint change
- `Sources/MeOrThem/Analysis/NetworkAnalyzer.swift` — add VPN-active finding
- `Sources/MeOrThem/UI/Menu/MenuBuilder.swift` — show VPN indicator in Network Details section (tag 5)

**Files to create:** none

**NetworkInfo.swift — new function:**
```swift
/// Returns the name of the first active tunnel/VPN interface, or nil if none.
/// Checks for utun*, ipsec*, ppp* interface names that are UP and have an assigned address.
/// Uses getifaddrs — no entitlements required.
public static func activeVPNInterface() -> String?
```

Implementation: call `getifaddrs`, walk the linked list, filter for interface names matching the prefix patterns above that have `IFF_UP` flag set and at least one non-loopback address. Return the first match's name (e.g. "utun2"), or nil.

**SQLiteStore schema migration:**
- Add to `_runMigrations()`: `ALTER TABLE network_sessions ADD COLUMN vpn_interface TEXT;` (nullable — nil = no VPN at session open time)
- Update `openSession(id:fingerprint:displayName:)` to accept an optional `vpnInterface: String?` parameter and write it into the new column

**AppEnvironment changes:**
- In the `metricStore.$latestWifi` sink (where sessions are opened), call `NetworkInfo.activeVPNInterface()` synchronously (it's fast — microseconds) and pass the result to `sqliteStore.openSession(id:fingerprint:displayName:vpnInterface:)`
- Store the current VPN interface on `AppEnvironment`: `private(set) var currentVPNInterface: String? = nil`
- Update this value whenever a new session opens or on every tick (check once per minute rather than per-tick to avoid overhead — use a counter or a separate 60s timer)
- Publish via `@Published var vpnInterface: String? = nil` on `MetricStore` so UI can react

**MetricStore changes:**
- Add `@Published var vpnInterface: String? = nil` (set by AppEnvironment)

**NetworkAnalyzer — new finding (insert as check #0, evaluated first):**
- If the session's `vpn_interface` column is non-null, emit a finding:
  - Category: `.configuration`
  - Confidence: 1.0 (it's a fact, not a probability)
  - Title: "VPN Active"
  - Detail: "A VPN tunnel (\(interface)) was active during this session. Latency readings include tunnel overhead and do not reflect raw ISP performance."
- This finding should always surface regardless of data sufficiency, since it's factual

**MenuBuilder — Network Details (tag 5):**
- In `refreshNetworkDetails`, after the WiFi/IP/gateway rows, add a row: "VPN: \(interface)" if `metricStore.vpnInterface != nil`, else omit (don't show "VPN: None")

**Tests:**
- Unit test `NetworkInfo.activeVPNInterface()`: mock is hard; test at minimum that the function compiles and returns a `String?` without crashing (integration test only)
- Add schema migration test: open SQLiteStore, verify `network_sessions` has `vpn_interface` column after init

**DoD checklist:**
- [ ] `NetworkInfo.activeVPNInterface()` implemented
- [ ] `network_sessions.vpn_interface` column added via migration
- [ ] `AppEnvironment` detects VPN on session open and publishes to `MetricStore`
- [ ] VPN indicator in menu Network Details section
- [ ] NetworkAnalyzer emits VPN-active finding
- [ ] Schema migration test passing

---

### T2-B · HTTP/HTTPS Endpoint Monitoring

**What:** Extend `ProbeMode` (introduced in T1-C) with HTTP/HTTPS options. When a target uses HTTP probe mode, measure time-to-first-byte via `URLSession` instead of ICMP ping. Store results in the same `ping_samples` schema (RTT = TTFB in ms, loss = HTTP error rate). Surface the HTTP status code in the menu target row tooltip.

**Prerequisite:** T1-C must be implemented first (`ProbeMode` enum and `TCPProber` infrastructure must exist).

**Files to modify:**
- `Sources/MeOrThemCore/Models/PingTarget.swift` — add `.http` and `.https` cases to `ProbeMode`
- `Sources/MeOrThemCore/Monitoring/PingMonitor.swift` — add HTTP probe routing
- `Sources/MeOrThem/UI/Settings/TargetsTab.swift` — `.http` and `.https` now appear in picker automatically (no change if using `ProbeMode.allCases`)

**Files to create:**
- `Sources/MeOrThemCore/Monitoring/HTTPProber.swift` — new file

**ProbeMode additions (PingTarget.swift):**
```swift
case http  = "HTTP"
case https = "HTTPS"
```

**HTTPProber.swift (new file in `MeOrThemCore/Monitoring/`):**
```swift
struct HTTPProbeResult {
    let rttMs: Double?        // time-to-first-byte; nil on timeout/error
    let lossPercent: Double   // 0.0 on any 2xx/3xx response; 100.0 on error or 5xx
    let statusCode: Int?      // HTTP status code, nil on network error
}

struct HTTPProber {
    /// Measures time-to-first-byte for the given URL.
    /// Uses a dedicated URLSession with 5-second timeout.
    /// Follows up to 3 redirects. Counts 4xx/5xx as loss.
    static func probe(host: String, scheme: String) async -> HTTPProbeResult
}
```

Implementation:
- Construct URL as `"\(scheme)://\(host)"` (use `InputValidator` to confirm host is a valid hostname/IP before making the request)
- Use `URLSession(configuration: ephemeral)` with `timeoutIntervalForRequest = 5`
- Issue a `HEAD` request (avoids downloading body; still measures connection + SSL + server response time)
- Record `Date()` before the request and after receiving the response
- Map status codes: 2xx/3xx → lossPercent 0.0; 4xx/5xx → lossPercent 100.0; network error → nil rttMs + 100.0 loss
- Do NOT store cookies or cache (ephemeral session)

**PingMonitor routing:**
```swift
case .http:  return await HTTPProber.probe(host: target.host, scheme: "http")
case .https: return await HTTPProber.probe(host: target.host, scheme: "https")
```

The resulting `PingResult` (rtt, lossPercent, jitter) feeds into exactly the same MetricStore recording path — no downstream changes.

**Menu display:** The `TargetMenuItemView` sparkline shows RTT regardless of probe mode — no changes needed. The status code is not surfaced in the menu for now (would require schema changes); this is a deferred improvement.

**Tests:**
- Test `HTTPProber.probe` against a reliable HTTPS endpoint (can use `example.com`) in a live test, or mock `URLSession` using a custom `URLProtocol`
- Test that 5xx response maps to `lossPercent: 100.0`

**DoD checklist:**
- [ ] `ProbeMode.http` and `.https` added to enum
- [ ] `HTTPProber.swift` implemented with HEAD request + TTFB measurement
- [ ] `PingMonitor` routes to HTTP prober correctly
- [ ] Results stored in `ping_samples` without schema changes
- [ ] Tests added and passing

---

### T2-C · Sleep/Wake Event Correlation

**What:** Record macOS sleep and wake events in a new `system_events` SQLite table. Annotate the Charts window timeline with vertical marker lines at sleep/wake boundaries. Tag any incident that started within 90 seconds of a wake event with cause hint "post-wake." This explains the most common "brief outage at 9am" pattern users see.

**Files to modify:**
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — add `system_events` table + insert/query API
- `Sources/MeOrThem/App/AppEnvironment.swift` — subscribe to sleep/wake notifications
- `Sources/MeOrThem/UI/Charts/MetricsDataLoader.swift` — load sleep/wake events for the time window
- `Sources/MeOrThem/UI/Charts/MetricsChartsView.swift` — render wake markers on charts
- `Sources/MeOrThem/Analysis/NetworkAnalyzer.swift` — annotate findings with post-wake context

**Files to create:** none

**SQLiteStore — new table:**
```sql
CREATE TABLE IF NOT EXISTS system_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp  REAL    NOT NULL,
    event_type TEXT    NOT NULL   -- 'sleep' | 'wake'
);
CREATE INDEX IF NOT EXISTS idx_system_events_ts ON system_events(timestamp);
```

Add to `_createSchema()`.

Add public API:
```swift
public func insertSystemEvent(timestamp: Date, eventType: String) {
    // fire-and-forget, queue.async
}

public struct SystemEventRow {
    public let timestamp: Date
    public let eventType: String   // "sleep" | "wake"
}

public func systemEventRows(from: Date, to: Date) -> [SystemEventRow]
```

**AppEnvironment changes:**
Add to `init()`:
```swift
// Sleep/wake observation
NotificationCenter.default.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: NSWorkspace.shared,
    queue: .main
) { [weak self] _ in
    self?.sqliteStore.insertSystemEvent(timestamp: Date(), eventType: "sleep")
    self?.monitoringEngine.pause()   // optional: pause monitoring on sleep
}
NotificationCenter.default.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: NSWorkspace.shared,
    queue: .main
) { [weak self] _ in
    self?.sqliteStore.insertSystemEvent(timestamp: Date(), eventType: "wake")
    if self?.monitoringEngine.isPaused == true {
        self?.monitoringEngine.resume()
    }
    // Record wake timestamp for post-wake incident tagging
    self?.lastWakeDate = Date()
}
```

Add `private var lastWakeDate: Date? = nil` to `AppEnvironment`.

**Incident tagging:** In the `metricStore.$overallStatus` sink that calls `alertManager.handleStatusChange`, also check if `lastWakeDate` is within 90 seconds. If so, pass a hint to `sqliteStore.openIncident(cause:)` with cause suffix " (post-wake)". `openIncident(cause:)` already takes a `cause: String` parameter.

**MetricsDataLoader changes:**
- Add `@Published var systemEvents: [SystemEventRow] = []`
- In `load(window:)`, append: `systemEvents = db.systemEventRows(from: windowStart, to: windowEnd)`

**MetricsChartsView changes:**
- On each chart that has a time axis (latency, loss, jitter, WiFi, DNS), overlay `RuleMark` annotations for wake events:
  ```swift
  ForEach(loader.systemEvents.filter { $0.eventType == "wake" }, id: \.timestamp) { event in
      RuleMark(x: .value("Wake", event.timestamp))
          .foregroundStyle(.orange.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .annotation(position: .top) {
              Text("Wake").font(.caption2).foregroundStyle(.orange)
          }
  }
  ```
- Sleep events: lighter grey dashed line, label "Sleep"
- Follow the same `BarMark` annotation pattern already used for incident shading in the charts

**NetworkAnalyzer — optional finding:**
- When analyzing a session, check if `tracerouteEvents` or `ping_samples` show a degradation within 90 seconds of a `system_event` wake row for that session's time window
- If found, add to any relevant latency/loss finding's detail text: "Note: this degradation began within 90 seconds of a system wake event and may reflect DHCP re-negotiation or WiFi re-association delay."

**Tests:**
- Insert sleep + wake events into in-memory store, query with time range, verify order and types
- Verify `system_events` table created on schema init

**DoD checklist:**
- [ ] `system_events` table created in schema
- [ ] `insertSystemEvent` + `systemEventRows` implemented
- [ ] `AppEnvironment` subscribes to `willSleepNotification` / `didWakeNotification`
- [ ] Monitoring pauses on sleep, resumes on wake
- [ ] Charts show sleep/wake markers as dashed rule lines
- [ ] Post-wake incidents tagged in cause string
- [ ] Tests added and passing

---

### T2-D · Uptime / Availability Percentage

**What:** Compute and display connection availability % (time in green status / total elapsed time) for configurable time windows. Display in the menu dropdown summary section and in the Charts window header. No new data collection needed — derived from existing `incidents` + `ping_aggregates` tables.

**Files to modify:**
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — add `availabilityPercent(from:to:)` query
- `Sources/MeOrThem/UI/Charts/MetricsChartsView.swift` — add availability badge in header
- `Sources/MeOrThem/UI/Menu/MenuBuilder.swift` — add availability row in summary section

**Files to create:** none

**SQLiteStore — availability query:**

The calculation: availability % = 1 − (total seconds with `severity > 0` / total seconds in window).

The `incidents` table has `started_at` and `ended_at` (both as Unix timestamps). An open incident (`ended_at IS NULL`) uses `now` as its end.

```swift
/// Returns the fraction of time [0.0–1.0] spent in non-degraded state
/// over the given window. 1.0 = 100% uptime. nil if no data exists.
public func availabilityFraction(from: Date, to: Date) -> Double?
```

Implementation (runs on the storage queue, synchronous):
```sql
SELECT started_at, COALESCE(ended_at, :now) as end_at
FROM incidents
WHERE end_at > :from AND started_at < :to
  AND ended_at IS NOT NULL   -- exclude currently open incidents for simplicity
ORDER BY started_at ASC
```
Merge overlapping incident intervals (sweep-line in Swift), sum the degraded seconds, divide by `(to - from)` total seconds. Return `1.0 - ratio`. If `to - from == 0` or the table has no rows in range, return `nil` (not enough data).

**MetricStore — cached availability:**
Add:
```swift
@Published var availability24h: Double? = nil
@Published var availability7d: Double? = nil
@Published var availability30d: Double? = nil
```

Update these once per hour in `AppEnvironment.runSQLiteMaintenance()` (already called hourly) using a `Task.detached` block querying `sqliteStore.availabilityFraction(from:to:)` for each window.

**MenuBuilder changes:**
In the summary section (where latency/loss/jitter rows appear, around tag 1–3), add a row after jitter:
```
Uptime (24h): 99.4%   [green dot]
```
Only show if `metricStore.availability24h != nil`. Color: green ≥ 99%, yellow ≥ 95%, red < 95%.

Use `refreshLatency` / the incremental update path for this row (tag 7, verify it's free).

**MetricsChartsView changes:**
In the window picker toolbar (where "1h / 6h / 24h / 7d…" buttons are), add an availability badge next to the selected window label:
```
[24h ▾]   99.4% uptime
```
Use `loader.availabilityForWindow` — add `@Published var availabilityFraction: Double? = nil` to `MetricsDataLoader` and compute it in `load(window:)` using the selected window's time range.

**Tests:**
- Insert 2 incidents covering 10 minutes in a 24-hour window; verify `availabilityFraction` ≈ `1 - (600/86400)`
- Test interval merging with overlapping incidents

**DoD checklist:**
- [ ] `SQLiteStore.availabilityFraction(from:to:)` implemented with interval merging
- [ ] `MetricStore` publishes `availability24h/7d/30d`, updated hourly
- [ ] Menu shows "Uptime (24h)" row with color coding
- [ ] Charts window shows availability badge next to time window picker
- [ ] Tests for availability calculation and interval merging

---

### T2-E · Battery-Aware Monitoring

**What:** Automatically reduce poll frequency when the Mac is on battery power, to limit CPU/subprocess overhead. Restore the user's configured interval when on AC. Configurable in Settings → General: "On battery: Normal / Reduced (2× slower) / Paused".

**Files to modify:**
- `Sources/MeOrThemCore/Models/AppSettings.swift` — add `batteryBehavior` setting
- `Sources/MeOrThem/App/AppEnvironment.swift` — observe power source changes, adjust monitoring
- `Sources/MeOrThem/UI/Settings/GeneralTab.swift` — add battery behavior picker

**Files to create:** none

**AppSettings additions:**
```swift
enum BatteryBehavior: String, Codable, CaseIterable {
    case normal  = "Normal (no change)"
    case reduced = "Reduced (2× slower)"
    case paused  = "Pause monitoring"
}

@Published var batteryBehavior: BatteryBehavior {
    didSet { UserDefaults.standard.set(batteryBehavior.rawValue, forKey: "batteryBehavior") }
}
```

Default: `.normal` (no change from existing behavior).

**AppEnvironment changes:**

1. Import `IOKit` (already available on macOS — add `import IOKit.ps` at top)

2. Add power source monitoring:
   ```swift
   private var powerSourceObserver: CFRunLoopSource?
   private var isOnBattery: Bool = false
   ```

3. In `init()`:
   ```swift
   let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
   let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
   isOnBattery = sources.contains { source in
       let desc = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any]
       return (desc?[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
   }

   powerSourceObserver = IOPSNotificationCreateRunLoopSource({ context in
       // Called when power source changes
       guard let ctx = context else { return }
       let env = Unmanaged<AppEnvironment>.fromOpaque(ctx).takeUnretainedValue()
       Task { @MainActor in env.handlePowerSourceChange() }
   }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
   CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceObserver, .defaultMode)
   ```

4. Add `handlePowerSourceChange()`:
   ```swift
   @MainActor private func handlePowerSourceChange() {
       // Re-sample current power source state (same IOKit call as above)
       let nowOnBattery: Bool = /* ... */
       guard nowOnBattery != isOnBattery else { return }
       isOnBattery = nowOnBattery
       applyBatteryBehavior()
   }

   @MainActor private func applyBatteryBehavior() {
       guard isOnBattery else {
           // Restore configured interval and resume if we had paused
           if monitoringEngine.isPaused { monitoringEngine.resume() }
           monitoringEngine.restart(interval: settings.pollIntervalSecs)
           return
       }
       switch settings.batteryBehavior {
       case .normal:  break
       case .reduced: monitoringEngine.restart(interval: settings.pollIntervalSecs * 2)
       case .paused:  monitoringEngine.pause()
       }
   }
   ```

5. Also call `applyBatteryBehavior()` on `settings.$batteryBehavior` changes (so changing the setting takes effect immediately).

**GeneralTab additions:**
After the "Poll Interval" picker, add:
```swift
Picker("On Battery", selection: $settings.batteryBehavior) {
    ForEach(BatteryBehavior.allCases, id: \.self) { mode in
        Text(mode.rawValue).tag(mode)
    }
}
.pickerStyle(.menu)
```
Only show on machines that have a battery (check `ProcessInfo.processInfo.isLowPowerModeEnabled` or IOKit — can also show unconditionally since it's harmless on desktops).

**Tests:**
- Unit test `applyBatteryBehavior()` with a mock `MonitoringEngine` (or verify the interval by inspecting `monitoringEngine.currentInterval` after calling the method with mock `isOnBattery = true`)

**DoD checklist:**
- [ ] `BatteryBehavior` enum added to `AppSettings`, Codable, defaults to `.normal`
- [ ] `AppEnvironment` observes IOKit power source notifications
- [ ] Poll interval adjusts correctly on battery/AC transitions
- [ ] `GeneralTab` shows battery behavior picker
- [ ] Changing setting takes effect immediately
- [ ] Test added

---

## Tier 3 — Differentiators / Power-User Features

---

### T3-A · Prometheus/JSON Metrics Endpoint

**What:** Start a local HTTP server on a configurable port (default 9090) that serves current metrics in Prometheus text format at `GET /metrics` and in JSON at `GET /metrics.json`. Allows power users to feed data into Grafana, HomeAssistant, shell scripts, or any Prometheus-compatible collector.

**Files to modify:**
- `Sources/MeOrThemCore/Models/AppSettings.swift` — add `metricsServerEnabled: Bool`, `metricsServerPort: Int`
- `Sources/MeOrThem/App/AppEnvironment.swift` — start/stop server
- `Sources/MeOrThem/UI/Settings/GeneralTab.swift` — add toggle + port field

**Files to create:**
- `Sources/MeOrThem/Utilities/MetricsHTTPServer.swift` — local HTTP server

**MetricsHTTPServer.swift:**

Use `Network.framework` (`NWListener`) — already available on macOS 10.14+, no entitlements needed for localhost binding.

```swift
@MainActor
final class MetricsHTTPServer {
    private var listener: NWListener?
    private weak var metricStore: MetricStore?
    private weak var settings: AppSettings?

    init(metricStore: MetricStore, settings: AppSettings) { ... }

    func start(port: Int) throws
    func stop()

    // Generates Prometheus-format response string from MetricStore's latest values
    private func prometheusResponse() -> String
    // Generates JSON response string
    private func jsonResponse() -> String
}
```

Prometheus format output (subset):
```
# HELP meorthem_latency_ms Average latency across all targets
# TYPE meorthem_latency_ms gauge
meorthem_latency_ms{target="Cloudflare"} 12.4
meorthem_latency_ms{target="Google"} 11.8
meorthem_loss_percent{target="Cloudflare"} 0.0
meorthem_jitter_ms{target="Cloudflare"} 1.2
meorthem_wifi_rssi_dbm -58
meorthem_overall_status 0
meorthem_dns_latency_ms{resolver="Cloudflare (1.1.1.1)"} 8.3
```

`meorthem_overall_status`: 0 = green, 1 = yellow, 2 = red.

Implementation: `NWListener` accepts TCP connections on localhost only (bind to `127.0.0.1`). For each connection, read the incoming HTTP request line (parse method + path), write the appropriate response headers + body, then close the connection. This is intentionally minimal — no keep-alive, no concurrent request handling. Each request reads `MetricStore`'s `@Published` properties synchronously on the main actor (since `MetricsHTTPServer` is `@MainActor`).

**AppEnvironment changes:**
```swift
private var metricsServer: MetricsHTTPServer?

// In init(), after all other setup:
if settings.metricsServerEnabled {
    startMetricsServer()
}
settings.$metricsServerEnabled
    .dropFirst()
    .sink { [weak self] enabled in
        if enabled { self?.startMetricsServer() } else { self?.metricsServer?.stop() }
    }.store(in: &cancellables)
settings.$metricsServerPort
    .dropFirst()
    .sink { [weak self] _ in
        guard self?.settings.metricsServerEnabled == true else { return }
        self?.metricsServer?.stop()
        self?.startMetricsServer()
    }.store(in: &cancellables)

private func startMetricsServer() {
    let server = MetricsHTTPServer(metricStore: metricStore, settings: settings)
    try? server.start(port: settings.metricsServerPort)
    metricsServer = server
}
```

**AppSettings additions:**
```swift
@Published var metricsServerEnabled: Bool {
    didSet { UserDefaults.standard.set(metricsServerEnabled, forKey: "metricsServerEnabled") }
}
@Published var metricsServerPort: Int {
    didSet { UserDefaults.standard.set(metricsServerPort, forKey: "metricsServerPort") }
}
```
Defaults: `metricsServerEnabled = false`, `metricsServerPort = 9090`.

**GeneralTab additions:**
Add a new "Metrics Export" section (after Notifications):
- Toggle: "Enable local metrics endpoint"
- Port field (only enabled when toggle is on): `TextField("Port", value: $settings.metricsServerPort, format: .number)` with range validation 1024–65535
- Help text: "Access at http://localhost:PORT/metrics (Prometheus) or /metrics.json"

**Tests:**
- Unit test `prometheusResponse()` and `jsonResponse()` with a mock `MetricStore` containing known values — verify metric names and label formatting

**DoD checklist:**
- [ ] `MetricsHTTPServer` implemented with Prometheus + JSON endpoints
- [ ] Binds to 127.0.0.1 only (not exposed externally)
- [ ] `AppEnvironment` starts/stops server reactively
- [ ] `AppSettings` has `metricsServerEnabled` + `metricsServerPort`
- [ ] `GeneralTab` has metrics server section
- [ ] Port conflict handled gracefully (catch NWListener error, log, disable toggle)
- [ ] Tests for response format

---

### T3-B · Recurring Problem Detection (Day-of-Week Patterns)

**What:** Extend the existing time-of-day hourly heatmap (already in `MetricsChartsView`) with a day-of-week breakdown showing average RTT per day of week (Mon–Sun) across the last 30 days. Add a corresponding NetworkAnalyzer finding that flags recurring weekly degradation (e.g., "latency consistently elevated on Sunday evenings").

**Files to modify:**
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — add `weekdayRTTAverages(lookback:)` query
- `Sources/MeOrThem/UI/Charts/MetricsDataLoader.swift` — load weekly pattern data
- `Sources/MeOrThem/UI/Charts/MetricsChartsView.swift` — add day-of-week bar chart
- `Sources/MeOrThem/Analysis/NetworkAnalyzer.swift` — add weekly pattern finding

**Files to create:** none

**SQLiteStore — new query:**
```swift
/// Computes per-weekday (1=Sunday … 7=Saturday, matching strftime %w + 1)
/// average RTT across all ping_aggregates in the lookback window.
/// Returns only weekdays that have at least `minSampleCount` aggregate rows.
public func weekdayRTTAverages(lookback: TimeInterval,
                                minSampleCount: Int = 5) -> [Int: Double]
```

Implementation:
```sql
SELECT CAST(strftime('%w', datetime(timestamp_minute, 'unixepoch', 'localtime')) AS INTEGER) as wd,
       AVG(avg_rtt_ms) as avg_rtt
FROM ping_aggregates
WHERE timestamp_minute > :since AND avg_rtt_ms IS NOT NULL
GROUP BY wd
HAVING COUNT(*) >= :minCount
```

Returns a `[Int: Double]` dictionary where key is 0 (Sunday) through 6 (Saturday).

**MetricsDataLoader changes:**
- Add `@Published var weekdayPattern: [Int: Double] = [:]` (alongside the existing `@Published var hourlyPattern: [Int: Double]`)
- In `load(window:)`, when `selectedWindow` is `≥ .day7` (to ensure enough data), call `db.weekdayRTTAverages(lookback: 30 * 86400)` and assign

**MetricsChartsView changes:**
- After the existing "Daily Pattern (Hour of Day)" section, add "Weekly Pattern (Day of Week)" section
- Render as a horizontal bar chart (`BarMark`) with days on the x-axis (Mon, Tue … Sun) and avg RTT on the y-axis
- Color each bar using the existing status-color logic: green < latencyYellow threshold, yellow < red threshold, red otherwise
- Show only when `loader.weekdayPattern.count >= 4` (same guard as the hourly pattern uses)
- Gate visibility on `selectedWindow` being ≥ 7d (same as hourly pattern gates on `selectedWindow >= .day1`)

**NetworkAnalyzer — new finding (pattern #17):**
- Load `weekdayRTTAverages` for the session's time window
- Compute mean and standard deviation across weekdays
- If any single weekday's avg is > mean + 1.5 * stddev AND the delta is > 10ms, emit a finding:
  - Category: `.latency`
  - Confidence: 0.55–0.75 based on how many samples contributed
  - Title: "Recurring Weekly Pattern"
  - Detail: "Average latency on [Weekday] is X ms above the weekly average (Y ms vs Z ms). This pattern may reflect ISP congestion or maintenance on that day."

**Tests:**
- Insert ping_aggregates spread across multiple weekdays, call `weekdayRTTAverages`, verify correct grouping
- Test NetworkAnalyzer pattern emits when one weekday is significantly elevated

**DoD checklist:**
- [ ] `SQLiteStore.weekdayRTTAverages` implemented
- [ ] `MetricsDataLoader` loads weekly pattern
- [ ] Day-of-week bar chart added to Charts window
- [ ] NetworkAnalyzer pattern #17 implemented
- [ ] Tests added and passing

---

### T3-C · Session Comparison

**What:** Allow the user to select two network sessions from the Network Analysis window and view a side-by-side delta comparison: average latency, loss, jitter, WiFi signal, DNS latency, uptime, and speedtest results per session. Useful for "home network vs office" or "before vs after router firmware update" comparisons.

**Files to modify:**
- `Sources/MeOrThem/UI/NetworkAnalysisWindowController.swift` — add comparison mode

**Files to create:**
- `Sources/MeOrThem/UI/SessionComparisonView.swift` — new SwiftUI view

**NetworkAnalysisWindowController changes:**
- Add a "Compare" toolbar button in the Network Analysis window
- When clicked, toggle the left-panel session list into "comparison mode": sessions show a checkbox instead of being single-selection
- User selects exactly 2 sessions; "Compare" button becomes active; clicking it opens `SessionComparisonView` as a sheet or a new window

The existing `NetworkSessionRow` struct (already loaded into the session list) carries all needed identifiers.

**SessionComparisonView.swift:**

Takes two `NetworkSessionRow` values and loads per-session aggregates asynchronously.

Layout: two-column `Grid` or `HStack` with:
- Row 0 (header): Session A display name + date range | Session B display name + date range
- Row 1: "Avg Latency" label | A value (ms) | B value (ms) | delta (±X ms, colored)
- Row 2: "Packet Loss" | A | B | delta
- Row 3: "Avg Jitter" | A | B | delta
- Row 4: "WiFi Signal" | A (dBm) | B (dBm) | delta
- Row 5: "DNS (fastest)" | A (ms) | B (ms) | delta
- Row 6: "Availability" | A (%) | B (%) | delta
- Row 7: "Best Speed ↓" | A (Mbps) | B (Mbps) | delta (if speedtest rows exist for either session)

Delta column coloring: green = improvement, red = regression, grey = negligible (< 5%).

Data loading per session:
- Avg latency/loss/jitter: query `ping_samples` grouped by session_id (already have `queryPingRows(sessionID:)` or similar in SQLiteStore)
- WiFi: average RSSI from `wifi_samples` where session_id matches
- DNS: minimum avg RTT across resolvers from `dns_resolver_samples`
- Availability: use `availabilityFraction(from:to:)` (implemented in T2-D) with the session's time bounds
- Speedtest: `speedtestRows(from:to:)` (implemented in T1-A) with session time bounds, take max download

All queries run in a `Task.detached` block; results published to `@State` on main actor.

**Tests:** This feature is primarily UI composition — no new SQLite logic. Manual verification is the test.

**DoD checklist:**
- [ ] "Compare" button added to Network Analysis window toolbar
- [ ] Two-session selection mode in session list
- [ ] `SessionComparisonView` shows all 7 metric rows with delta coloring
- [ ] Data loads asynchronously without blocking UI
- [ ] Window/sheet releases on close

---

### T3-D · Automatic ISP Identification

**What:** At session open time, resolve the public IP's AS (Autonomous System) name via a local, offline lookup using the WHOIS/ASN database, or via a lightweight DNS-based ASN lookup (`origin.asn.cymru.com` TXT record). Tag each `network_sessions` row with `isp_name`. Show ISP name in the Network Analysis session list and in the menu's Network Details section.

**Files to modify:**
- `Sources/MeOrThemCore/Storage/SQLiteStore.swift` — add `isp_name` column to `network_sessions`
- `Sources/MeOrThem/App/AppEnvironment.swift` — perform ASN lookup at session open
- `Sources/MeOrThem/UI/NetworkAnalysisWindowController.swift` — show ISP name in session list

**Files to create:**
- `Sources/MeOrThemCore/Utilities/ASNLookup.swift` — DNS-based AS name resolver

**SQLiteStore schema migration:**
```sql
ALTER TABLE network_sessions ADD COLUMN isp_name TEXT;
```
Add to `_runMigrations()`. Update `openSession` to accept optional `ispName: String?`.

**ASNLookup.swift:**

DNS TXT record lookup against `origin.asn.cymru.com`:
- To look up public IP `203.0.113.5`, reverse the octets and query: `5.113.0.203.origin.asn.cymru.com` TXT
- Response contains: `ASN | IP range | Country | Registry | Date`
- Then query `AS{number}.asn.cymru.com` TXT for the org name
- Use `DNSProber`'s raw UDP capability (already exists) or a simple `getaddrinfo`-based TXT lookup

```swift
struct ASNLookup {
    /// Resolves the ISP/org name for a given public IP.
    /// Returns nil on timeout, lookup failure, or private IP.
    /// Async; runs on a background thread.
    static func resolve(ip: String) async -> String?
}
```

Steps:
1. Reject private/loopback ranges (10.x, 172.16–31.x, 192.168.x, 127.x) — return nil immediately
2. Reverse the IP octets and query `{reversed}.origin.asn.cymru.com` for TXT record
3. Parse ASN from response
4. Query `AS{asn}.asn.cymru.com` for TXT record, parse org name from field 5
5. Return org name (e.g., "COMCAST-7922, US")

Implementation uses `CFHost` or raw DNS query (can reuse `DNSProber`'s UDP socket infrastructure with TXT record type instead of A record type — `DNSProber` already has the wire-format query engine).

Timeout: 3 seconds total. Cache results in a `[String: String]` dictionary keyed by IP to avoid re-querying the same ISP on every session open.

**AppEnvironment changes:**
In the session-open block (where `sqliteStore.openSession` is called), after opening the session, fire an async task to resolve the ISP:
```swift
Task.detached(priority: .background) { [weak self] in
    guard let self else { return }
    // Use public IP — query NetworkInfo.publicIP() or use gateway's known external address
    // For simplicity: use the gateway's subnet to infer approximate public IP isn't reliable;
    // instead call a lightweight local resolution using the default gateway's IP
    let gatewayIP = await MainActor.run { self.metricStore.latestGatewayIP }
    guard let ip = gatewayIP else { return }
    let ispName = await ASNLookup.resolve(ip: ip)
    if let ispName {
        await MainActor.run {
            self.sqliteStore.updateSessionISP(id: newID, ispName: ispName)
        }
    }
}
```

Add `updateSessionISP(id:ispName:)` to `SQLiteStore`:
```swift
public func updateSessionISP(id: UUID, ispName: String) {
    // UPDATE network_sessions SET isp_name = ? WHERE id = ?
}
```

**NetworkAnalysis UI changes:**
- In the session list (left panel), show ISP name as a secondary line under the session display name (if non-nil)
- Example: "Home WiFi · Comcast" or just display name if ISP is nil

**Menu Network Details (tag 5):**
- Add "ISP: Comcast-7922" row in `refreshNetworkDetails` (read from `metricStore.currentSessionISPName` — new `@Published var` on MetricStore or AppEnvironment)

**Tests:**
- Unit test ASN lookup parsing with a known-good TXT response string (mock the network call)
- Test private IP rejection returns nil immediately

**DoD checklist:**
- [ ] `ASNLookup.swift` implemented with DNS TXT resolution and caching
- [ ] Private IP ranges rejected without network call
- [ ] `network_sessions.isp_name` column added via migration
- [ ] ISP name looked up asynchronously at session open
- [ ] Session list shows ISP name as secondary text
- [ ] Menu Network Details shows ISP name
- [ ] Parsing test added

---

### T3-E · Shortcuts / Automation Integration

**What:** Expose `AppIntent`-based Shortcuts actions for the most useful read and write operations. Allows users to query current network status in Raycast, build morning briefing shortcuts, or trigger exports automatically.

**Files to modify:**
- `Sources/MeOrThem/App/AppDelegate.swift` — add `NSApplicationDelegate` + App Intents registration
- `Package.swift` or `Info.plist` — declare `NSUserActivityTypes` or App Intents capability

**Files to create:**
- `Sources/MeOrThem/Intents/GetNetworkStatusIntent.swift`
- `Sources/MeOrThem/Intents/RunBandwidthTestIntent.swift`
- `Sources/MeOrThem/Intents/GetLastIncidentIntent.swift`
- `Sources/MeOrThem/Intents/ExportReportIntent.swift`

**Minimum iOS/macOS version requirement:** App Intents require macOS 13+. This app already uses Swift Charts (macOS 13+), so no deployment target change is needed.

**GetNetworkStatusIntent.swift:**
```swift
import AppIntents

struct GetNetworkStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Network Status"
    static var description = IntentDescription("Returns current connection quality and latency.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = MetricStore.shared   // or inject via AppEnvironment.shared
        let status = store.overallStatus.label   // "Green", "Yellow", "Red"
        let latency = store.latestPing.values.compactMap(\.rtt).average.map { "\(Int($0))ms" } ?? "N/A"
        return .result(value: "Status: \(status), Avg Latency: \(latency)")
    }
}
```

Note: `MetricStore` needs a `static var shared` accessor or App Intents need access to `AppEnvironment.shared`. Add `static weak var shared: AppEnvironment?` to `AppEnvironment` and assign in `AppDelegate.applicationDidFinishLaunching`.

**RunBandwidthTestIntent.swift:**
```swift
struct RunBandwidthTestIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Bandwidth Test"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let env = AppEnvironment.shared
        env?.speedtestRunner.run()
        return .result(value: "Bandwidth test started.")
    }
}
```

**GetLastIncidentIntent.swift:**
```swift
struct GetLastIncidentIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Incident"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let rows = AppEnvironment.shared?.sqliteStore.allIncidentRows(limit: 1) ?? []
        guard let row = rows.first else { return .result(value: "No incidents recorded.") }
        let formatter = RelativeDateTimeFormatter()
        let ago = formatter.localizedString(for: row.startedAt, relativeTo: Date())
        let duration = row.endedAt.map { Int($0.timeIntervalSince(row.startedAt)) }.map { "\($0)s" } ?? "ongoing"
        return .result(value: "Last incident: \(ago), duration \(duration), cause: \(row.cause)")
    }
}
```

**ExportReportIntent.swift:**
```swift
struct ExportReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Network Report"

    @Parameter(title: "Format", default: .csv)
    var format: ExportFormat

    enum ExportFormat: String, AppEnum {
        case csv, json, pdf
        static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Format")
        static var caseDisplayRepresentations: [ExportFormat: DisplayRepresentation] = [
            .csv: "CSV", .json: "JSON", .pdf: "PDF"
        ]
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        // Trigger ExportCoordinator.export(format:from:to:) for last 24h
        // Save to a temp file, return as IntentFile
    }
}
```

**AppDelegate registration:**
App Intents are discovered automatically by the system when the `AppIntent` protocol is implemented — no manual registration needed in macOS 13+.

**Shortcut actions in Shortcuts.app:** All four intents appear automatically under "MeOrThem" in the Shortcuts app after first launch on macOS 13+.

**Tests:** App Intents can't be unit-tested easily (they require the Shortcuts runtime). Manual verification is the test.

**DoD checklist:**
- [ ] `AppEnvironment.shared` weak reference added
- [ ] `GetNetworkStatusIntent` implemented and returns current status + latency
- [ ] `RunBandwidthTestIntent` triggers speedtest runner
- [ ] `GetLastIncidentIntent` returns last incident details
- [ ] `ExportReportIntent` exports last 24h to temp file
- [ ] All four intents appear in Shortcuts.app under MeOrThem
- [ ] No crash when intents are invoked while app is not frontmost

---

## Implementation Order Recommendation

Execute in this sequence to minimize merge conflicts and maximize reuse:

1. **T1-A** (Bandwidth Chart) — pure UI addition, no model changes
2. **T2-D** (Availability %) — pure query addition, feeds T1-D and others
3. **T1-E** (Notification Actions) — tiny change, immediate value
4. **T2-C** (Sleep/Wake) — schema addition, feeds chart annotations
5. **T1-D** (Incident History Window) — depends on availability % being useful; references wake events
6. **T1-B** (Per-Target Thresholds) — model change; no dependencies
7. **T1-C** (TCP Probing) — model change; prerequisite for T1-F (HTTP probing)
8. **T2-B** (HTTP Probing) — depends on T1-C
9. **T2-A** (VPN Detection) — schema addition + NetworkAnalyzer extension
10. **T2-E** (Battery-Aware) — independent; safe to do any time
11. **T3-B** (Weekly Patterns) — extends existing chart + analyzer
12. **T3-D** (ISP Identification) — schema addition + new utility
13. **T3-A** (Prometheus Endpoint) — independent; power-user feature
14. **T3-C** (Session Comparison) — depends on T2-D (availability %) being available
15. **T3-E** (Shortcuts) — depends on T1-D (incident history query) and T1-A (export)
