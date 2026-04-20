# Network Connection Type Support — Implementation Plan

**Goal:** Make MeOrThem fully support WiFi, Ethernet, and VPN connections with seamless
switching between them. Features that are genuinely WiFi-only (RSSI, channel, etc.) should
gracefully degrade and inform the user. All other features — session tracking, interface
diagnostics, exports, analysis, logs — must work regardless of connection type.

---

## Commit and Version Bump Rule

**After completing each task, before moving to the next:**

1. Run `swift run MeOrThemTests` — all tests must pass.
2. Increment `CFBundleShortVersionString` in `Info.plist`:
   - Z (patch) for fixes to existing behaviour (Tasks 5, 6, 7)
   - Y (minor) for new capabilities (Tasks 1, 2, 3, 4, 8, 9, 10, 11, 12, 13)
3. Update the Status line in `CLAUDE.md`, `PROGRESS.md`, and all version references
   in `index.html` (hero button sub-label, eyebrow, download button sub-label).
4. Add a section for the new version in `CHANGELOG.md` (user-facing changes only —
   follow the Changelog Rules in CLAUDE.md).
5. `git commit` with a detailed message (no references to Claude).
6. `git push origin main`.

Do not batch multiple tasks into one commit. Each task is one commit and one version bump.

---

## Background and Problem Summary

The app was developed with WiFi as the assumed connection type. The following systemic issues
affect Ethernet and VPN users:

| Issue | Impact |
|---|---|
| Session tracking only triggers on `$latestWifi` changes | Ethernet/VPN users never get a `network_sessions` row; Network Analysis is useless for them |
| Interface error monitoring falls back to hardcoded `"en0"` | Wrong interface on many Macs; false positives/negatives for error sampling |
| `NetworkInfo.ethernetInfo()` only matches `"en*"` prefixes | VPN interfaces (`utun*`, `ppp*`) are invisible; menu shows "No network connection" |
| Menu Network Details has no VPN branch | VPN-only users see nothing useful |
| `NetworkSessionKey.fromEthernet()` exists but is never called | Dead code |
| No gateway MAC in Ethernet fingerprint | Two different routers sharing the same IP/subnet look identical |
| Exports (CSV, JSON, PDF) have no non-WiFi interface section | Ethernet/VPN reports are missing connection metadata |
| LogExporter only writes WiFi rows, no Ethernet/VPN equivalent | CSV logs sparse for non-WiFi users |
| WiFiObserver fires on BSSID/link change only; no non-WiFi event | No OS event exists for Ethernet switch — needs polling-based detection |

---

## Ethernet Fingerprinting Decision

Ethernet presents a unique fingerprinting challenge because many routers share the same
gateway IP (192.168.1.1, 10.0.0.1, etc.). For WiFi the channel + band disambiguates
otherwise identical IPs; no such extra dimension exists for Ethernet.

**Solution:** Use the gateway MAC address (from the ARP cache) as the primary discriminator.
The gateway MAC is the hardware address of the router — unique to each physical device even
when two routers share the same IP.

- **With MAC available:** fingerprint = `eth|<gatewayIP>|<subnet/24>|<gatewayMAC>`
  → strongly unique across different routers
- **Without MAC (ARP miss):** fingerprint = `eth|<gatewayIP>|<subnet/24>`
  → weak, may merge two different networks. Session is flagged `hasWeakFingerprint = true`.

**When a weak fingerprint is used**, display a yellow advisory in the Network Analysis session
panel: *"Router hardware address unavailable — if you have connected to multiple different
Ethernet networks sharing the same gateway IP and subnet, analysis data may combine
measurements from more than one network."*

**VPN fingerprinting:** Use `vpn|<interfaceName>|<gatewayIP>|<subnet/24>`. The interface
name (e.g. `utun3`) together with the VPN-assigned IP is sufficiently unique.

---

## Files to Change

```
Sources/MeOrThemCore/Utilities/NetworkInfo.swift       — add defaultGatewayInterface(), gatewayMACAddress()
Sources/MeOrThem/Utilities/NetworkInfo.swift           — mirror same additions (app-target copy)
Sources/MeOrThem/Models/NetworkSessionKey.swift        — add ConnectionType, hasWeakFingerprint, fromVPN()
Sources/MeOrThemCore/Storage/SQLiteStore.swift         — add connection_type column, update NetworkSessionRow
Sources/MeOrThem/App/AppEnvironment.swift              — rewire session tracking; subscribe to gatewayIP too
Sources/MeOrThem/Monitoring/MonitoringEngine.swift     — remove ?? "en0" fallback
Sources/MeOrThem/Monitoring/WiFiMonitor.swift          — review/confirm "en0" fallback acceptable
Sources/MeOrThem/UI/Menu/MenuBuilder.swift             — add VPN branch in networkDetailsSubmenu()
Sources/MeOrThem/Export/CSVExporter.swift              — add non-WiFi interface metadata note
Sources/MeOrThem/Export/JSONExporter.swift             — add connectionType to root object
Sources/MeOrThem/Export/PDFExporter.swift              — replace WiFi-only block with conditional section
Sources/MeOrThem/Storage/LogExporter.swift             — add appendInterfaceSnapshot() for Ethernet/VPN
Sources/MeOrThem/UI/NetworkAnalysisWindowController.swift — show connection type + weak-fingerprint warning
```

Tests (MeOrThemTests — new or extended):
```
NetworkSessionKeyTests.swift                           — Ethernet/VPN/WiFi factory methods; equality; weak flag
NetworkInfoTests.swift                                 — defaultGatewayInterface() parsing; MAC parsing
```

---

## Task 1 — NetworkInfo: Add `defaultGatewayInterface()` and `gatewayMACAddress()` ✅ DONE (v2.22.0)

**Files:** `Sources/MeOrThemCore/Utilities/NetworkInfo.swift` AND
`Sources/MeOrThem/Utilities/NetworkInfo.swift` (make identical changes in both; only the
access level differs — `public` in Core, internal in App).

### 1a — `defaultGatewayInterface()`

Add a cached function that parses the `interface:` line from `route -n get default`.
The existing `fetchDefaultGateway()` private function already runs this command and parses
`gateway:`. Refactor the private layer to parse both fields in one pass.

**Implementation approach:**

1. Change `private static func fetchDefaultGateway() -> String?` to
   `private static func fetchDefaultRouteInfo() -> (gateway: String, interface: String)?`
   that parses both `gateway:` and `interface:` from the route output in one subprocess call.

2. Add a second cache pair alongside the existing gateway cache:
   ```swift
   nonisolated(unsafe) private static var _cachedGatewayInterface: String? = nil
   // Reuse _gatewayFetchedAt for both — they come from the same subprocess call.
   ```

3. Both `defaultGateway()` and the new `defaultGatewayInterface()` call `fetchDefaultRouteInfo()`
   and cache both results atomically. This means the route subprocess is never called twice.

4. In `fetchDefaultRouteInfo()`, iterate lines:
   - Line starting with `"gateway:"` → strip prefix, trim → gateway
   - Line starting with `"interface:"` → strip prefix, trim → interface
   Return nil if gateway is missing (interface may also be nil for some VPN setups).

**Cache note:** Both values share `_gatewayFetchedAt`. On cache hit, read both from the
two cached variables. Thread safety: use the existing `cacheLock` (Core) or add it to the
App target copy (which currently uses `nonisolated(unsafe)` without a lock — add `cacheLock`
there too for consistency).

### 1b — `gatewayMACAddress(for:)`

Add a function that returns the gateway's ARP-cache MAC address.

```swift
/// Returns the MAC address of the specified IPv4 gateway from the ARP cache.
/// Runs `arp -n <ip>` — the IP argument is validated before use.
/// Returns nil on ARP miss, timeout, or invalid input.
/// Results are cached for 30 seconds (MAC rarely changes; ARP TTL is typically 20 min).
static func gatewayMACAddress(for ip: String) -> String?
```

**Implementation:**
1. Validate `ip` using `inet_pton(AF_INET, ip, &buf) == 1` to prevent any injection.
   Return nil immediately if validation fails.
2. Run `Process` with `executableURL = /usr/sbin/arp`, `arguments = ["-n", ip]`.
3. Parse the first non-empty output line. Expected format:
   `? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]`
   or `? (192.168.1.1) at (incomplete)` on ARP miss.
   Extract the segment after `" at "` and before `" on "` (or end of string).
   Reject `"(incomplete)"` and return nil.
4. Cache: add `nonisolated(unsafe) private static var _cachedGatewayMAC: String? = nil`
   and `_macFetchedAt: Date = .distantPast`, using `kCacheTTL = 30` like the gateway cache.
   Include the gateway IP in the cache key so a gateway change invalidates the MAC cache:
   `nonisolated(unsafe) private static var _macCacheKey: String = ""`

**Core target:** add `cacheLock` protection identical to `defaultGateway()`.

---

## Task 2 — NetworkSessionKey: Add ConnectionType, VPN factory, hasWeakFingerprint ✅ DONE (v2.22.1)

**File:** `Sources/MeOrThem/Models/NetworkSessionKey.swift`

Replace the entire file with the updated version:

```swift
struct NetworkSessionKey: Equatable {

    enum ConnectionType: String {
        case wifi     = "wifi"
        case ethernet = "ethernet"
        case vpn      = "vpn"
        case unknown  = "unknown"
    }

    let fingerprint:       String
    let displayName:       String
    let connectionType:    ConnectionType
    /// True when the Ethernet fingerprint lacks a gateway MAC address.
    /// In this case the session may silently merge two different Ethernet
    /// networks that share the same gateway IP and /24 subnet.
    let hasWeakFingerprint: Bool

    // MARK: - Factory (WiFi — unchanged logic)

    static func from(wifi: WiFiSnapshot) -> NetworkSessionKey? {
        guard let gw = wifi.routerIP, !gw.isEmpty else { return nil }
        let subnet = subnetPrefix(ip: wifi.ipAddress)
        let ghzStr = bandLabel(wifi.channelBandGHz)
        let fp     = "\(gw)|\(wifi.channelNumber)|\(ghzStr)|\(subnet)"
        let name   = "\(ghzStr) • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .wifi, hasWeakFingerprint: false)
    }

    // MARK: - Factory (Ethernet)

    /// `gatewayMAC` should be the ARP-cache MAC of the gateway router.
    /// When nil the fingerprint is weaker; `hasWeakFingerprint` is set to true.
    static func fromEthernet(gatewayIP: String,
                              localIP: String?,
                              gatewayMAC: String?) -> NetworkSessionKey {
        let subnet  = subnetPrefix(ip: localIP)
        let mac     = gatewayMAC?.lowercased() ?? ""
        let hasMAC  = !mac.isEmpty && mac != "—" && mac != "(incomplete)"
        let fp      = hasMAC
            ? "eth|\(gatewayIP)|\(subnet)|\(mac)"
            : "eth|\(gatewayIP)|\(subnet)"
        let name    = "Ethernet • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .ethernet, hasWeakFingerprint: !hasMAC)
    }

    // MARK: - Factory (VPN)

    static func fromVPN(gatewayIP: String,
                        localIP: String?,
                        interfaceName: String) -> NetworkSessionKey {
        let subnet = subnetPrefix(ip: localIP)
        let fp     = "vpn|\(interfaceName)|\(gatewayIP)|\(subnet)"
        let name   = "VPN • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .vpn, hasWeakFingerprint: false)
    }

    // MARK: - Helpers (unchanged)

    private static func subnetPrefix(ip: String?) -> String {
        guard let ip else { return "?.?.?" }
        let parts = ip.split(separator: ".", maxSplits: 3)
        guard parts.count >= 3 else { return "?.?.?" }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private static func bandLabel(_ ghz: Double) -> String {
        if abs(ghz - 2.4) < 0.05 { return "2.4 GHz" }
        if abs(ghz - 5.0) < 0.05 { return "5 GHz" }
        if abs(ghz - 6.0) < 0.05 { return "6 GHz" }
        return String(format: "%.1f GHz", ghz)
    }
}
```

**Equatable:** `NetworkSessionKey` derives `Equatable` via synthesis. Since `fingerprint`
uniquely identifies the network, that is fine for session change detection.

---

## Task 3 — SQLiteStore: Add `connection_type` to `network_sessions` ✅ DONE (v2.22.2)

**File:** `Sources/MeOrThemCore/Storage/SQLiteStore.swift`

### 3a — Schema migration

In `_runMigrations()`, add:
```swift
_exec("ALTER TABLE network_sessions ADD COLUMN connection_type TEXT NOT NULL DEFAULT 'wifi';")
_exec("ALTER TABLE network_sessions ADD COLUMN weak_fingerprint INTEGER NOT NULL DEFAULT 0;")
```
These are idempotent (SQLite returns an error if the column already exists; `_exec` silently
discards errors, which is the existing pattern).

### 3b — Update `NetworkSessionRow`

```swift
public struct NetworkSessionRow: Identifiable, Sendable {
    public let id:              UUID
    public let fingerprint:     String
    public let displayName:     String
    public let startedAt:       Date
    public let lastSeen:        Date
    public let connectionType:  String   // "wifi", "ethernet", "vpn", "unknown"
    public let weakFingerprint: Bool
}
```

### 3c — Update `openSession()` public API

```swift
public func openSession(id: UUID,
                        fingerprint: String,
                        displayName: String,
                        connectionType: String = "wifi",
                        weakFingerprint: Bool = false,
                        startTime: Date = .init())
```

Default values ensure all existing call sites continue to compile without changes.

### 3d — Update `_openSession()` private implementation

Bind two additional columns when inserting:
```sql
INSERT OR IGNORE INTO network_sessions
    (id, fingerprint, display_name, started_at, last_seen, connection_type, weak_fingerprint)
VALUES (?, ?, ?, ?, ?, ?, ?);
```

### 3e — Update `_sessionRows()` private query

Read the two new columns and populate `connectionType` and `weakFingerprint` in the row struct.
For rows created before the migration, SQLite returns the DEFAULT values (`'wifi'` and `0`),
so old sessions silently inherit `connectionType = "wifi"` which is correct for most users.

---

## Task 4 — AppEnvironment: Rewire session tracking for all connection types

**File:** `Sources/MeOrThem/App/AppEnvironment.swift`

### 4a — Replace the WiFi-only session pipeline

**Remove** the existing `metricStore.$latestWifi.sink { ... }` block (lines 70–96).

**Replace** with a `CombineLatest` pipeline that reacts to either a WiFi change or a
gateway IP change:

```swift
Publishers.CombineLatest(
    metricStore.$latestWifi,
    metricStore.$latestGatewayIP
)
.sink { [weak self] wifi, gatewayIP in
    guard let self else { return }
    self.updateNetworkSession(wifi: wifi, gatewayIP: gatewayIP)
}
.store(in: &cancellables)
```

### 4b — Add `updateNetworkSession(wifi:gatewayIP:)` helper

```swift
@MainActor
private func updateNetworkSession(wifi: WiFiSnapshot?, gatewayIP: String?) {
    let key: NetworkSessionKey?

    if let wifi {
        // WiFi: use existing fingerprint logic
        key = NetworkSessionKey.from(wifi: wifi)

    } else if let gatewayIP {
        // Non-WiFi: determine interface type from the active default-route interface
        // These calls are cached (30 s TTL) so they don't block long.
        // Run on a detached task to avoid blocking MainActor during ARP/route lookups.
        Task { [weak self] in
            guard let self else { return }
            let (ifaceName, gatewayMAC) = await Task.detached(priority: .utility) {
                let iface = NetworkInfo.defaultGatewayInterface()
                let mac   = NetworkInfo.gatewayMACAddress(for: gatewayIP)
                return (iface, mac)
            }.value

            await MainActor.run {
                let sessionKey: NetworkSessionKey
                if let iface = ifaceName,
                   iface.hasPrefix("utun") || iface.hasPrefix("ppp") || iface.hasPrefix("tap") {
                    // VPN tunnel
                    let localIP = NetworkInfo.ipAddress(for: iface)
                    sessionKey = NetworkSessionKey.fromVPN(
                        gatewayIP: gatewayIP, localIP: localIP, interfaceName: iface)
                } else {
                    // Ethernet (or unknown interface type — treat as Ethernet)
                    let wifiIfaceName = WiFiMonitor.interfaceName()
                    let ethInfo = NetworkInfo.ethernetInfo(excluding: wifiIfaceName)
                    sessionKey = NetworkSessionKey.fromEthernet(
                        gatewayIP: gatewayIP, localIP: ethInfo?.ip, gatewayMAC: gatewayMAC)
                }
                self.applySessionKey(sessionKey)
            }
        }
        return  // async path handles the rest
    } else {
        // No connectivity — don't open a session
        return
    }

    if let key { applySessionKey(key) }
}

@MainActor
private func applySessionKey(_ key: NetworkSessionKey) {
    guard key.fingerprint != currentSessionFingerprint else {
        if let sid = metricStore.currentSessionID {
            sqliteStore.touchSession(id: sid)
        }
        return
    }
    let newID = UUID()
    currentSessionFingerprint    = key.fingerprint
    metricStore.currentSessionID = newID
    sqliteStore.openSession(id: newID,
                             fingerprint:     key.fingerprint,
                             displayName:     key.displayName,
                             connectionType:  key.connectionType.rawValue,
                             weakFingerprint: key.hasWeakFingerprint)
    settings.resetDNSResolverFailureCounts()
}
```

**Important:** `metricStore.$latestGatewayIP` fires every time `recordGatewayPing(_:gatewayIP:)`
is called (each tick). To avoid opening spurious new sessions on every tick, the fingerprint
equality check in `applySessionKey()` acts as the gate — only a fingerprint change (meaning
gateway IP, subnet, or MAC changed) actually opens a new session.

**CombineLatest throttle:** `CombineLatest` fires whenever *either* upstream changes. Since
`latestGatewayIP` changes ~every 5 s (each tick), this pipeline will run frequently. Because
the fingerprint check is O(1) string equality, the per-tick overhead is negligible. However,
the `Task.detached` inside the non-WiFi path (for ARP/route lookups) should not be spawned
on every tick if the gateway IP hasn't changed. Add a guard:

```swift
// At the top of updateNetworkSession, for the non-WiFi path:
private var lastNonWifiGatewayIP: String?

// In the non-WiFi branch:
guard gatewayIP != lastNonWifiGatewayIP ||
      currentSessionFingerprint?.hasPrefix("eth|") == false  // also re-check on first run
else {
    // Same gateway IP as last tick — just touch the session
    if let sid = metricStore.currentSessionID {
        sqliteStore.touchSession(id: sid)
    }
    return
}
lastNonWifiGatewayIP = gatewayIP
// ... proceed with detached task
```

---

## Task 5 — MonitoringEngine: Remove `?? "en0"` interface fallback

**File:** `Sources/MeOrThem/Monitoring/MonitoringEngine.swift`

**In the interface error sampling block (around line 252):**

Current:
```swift
let iface = store.latestWifi?.interfaceName
         ?? NetworkInfo.ethernetInfo()?.interface
         ?? "en0"
```

Replace with:
```swift
// Prefer the interface name from the WiFi snapshot (most reliable).
// If WiFi is not active, ask the routing table which interface carries the default route.
// This handles Ethernet, VPN (utun/ppp), and unusual interface names correctly.
// Do NOT fall back to a hardcoded "en0" — if no interface is found, skip this sample.
guard let iface = store.latestWifi?.interfaceName
               ?? NetworkInfo.defaultGatewayInterface() else { return }
```

**Note:** `NetworkInfo.defaultGatewayInterface()` is cached with a 30 s TTL and runs
on the detached utility task that already wraps this block, so it's safe to call here.

---

## Task 6 — WiFiMonitor.snapshot(): Confirm `"en0"` fallback is acceptable

**File:** `Sources/MeOrThem/Monitoring/WiFiMonitor.swift` (line 29)

```swift
let ifaceName = iface.interfaceName ?? "en0"
```

**Assessment:** This is inside the `snapshot()` function which only executes when
`client.interface()` returned a non-nil CWInterface with a valid `wlanChannel()`. If
CoreWLAN returned a valid interface object, `interfaceName` will virtually always be
non-nil. The `"en0"` fallback here is defensive and poses no real-world risk.

**Action:** Add a clarifying comment but do not change the fallback:

```swift
// CWInterface.interfaceName should never be nil when interface() returned non-nil,
// but guard against it defensively. "en0" is the canonical WiFi interface on Apple Silicon.
let ifaceName = iface.interfaceName ?? "en0"
```

---

## Task 7 — MenuBuilder: Add VPN branch in `networkDetailsSubmenu()`

**File:** `Sources/MeOrThem/UI/Menu/MenuBuilder.swift`

**Locate `networkDetailsSubmenu(store:)` (around line 448).** The current else-branch only
checks for `ethernetInfo()`. Extend it with a VPN branch:

```swift
} else {
    let wifiIfaceName = WiFiMonitor.interfaceName()
    // Check for active default-route interface — covers VPN, Ethernet, and unusual setups.
    let activeIface   = NetworkInfo.defaultGatewayInterface()
    let isVPN = activeIface.map {
        $0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("tap")
    } ?? false

    if isVPN, let vpnIface = activeIface {
        sub.addItem(infoItem("VPN — \(vpnIface)", bold: true))
        sub.addItem(.separator())
        if let localIP = NetworkInfo.ipAddress(for: vpnIface) {
            sub.addItem(infoItem("IP Address:  \(localIP)"))
        }
        if let gw = NetworkInfo.defaultGateway() {
            sub.addItem(infoItem("Router:      \(gw)"))
        }
        sub.addItem(infoItem("WiFi signal: Not available (VPN)"))

    } else if let eth = NetworkInfo.ethernetInfo(excluding: wifiIfaceName) {
        // Ethernet (existing code — unchanged)
        sub.addItem(infoItem("Ethernet — \(eth.interface)", bold: true))
        sub.addItem(.separator())
        sub.addItem(infoItem("IP Address:  \(eth.ip)"))
        if let gw = NetworkInfo.defaultGateway() {
            sub.addItem(infoItem("Router:      \(gw)"))
        }
        sub.addItem(infoItem("MAC Address: \(eth.mac)"))
        sub.addItem(infoItem("WiFi signal: Not available (Ethernet)"))

    } else if let iface = activeIface {
        // Unknown interface type (e.g., bridge, cellular USB modem)
        sub.addItem(infoItem("Connected — \(iface)", bold: true))
        sub.addItem(.separator())
        if let ip = NetworkInfo.ipAddress(for: iface) {
            sub.addItem(infoItem("IP Address:  \(ip)"))
        }
        if let gw = NetworkInfo.defaultGateway() {
            sub.addItem(infoItem("Router:      \(gw)"))
        }

    } else {
        sub.addItem(infoItem("No network connection"))
    }
}
```

**Note:** `NetworkInfo.defaultGatewayInterface()` is cached (30 s TTL) so calling it here
during menu construction does not spawn a subprocess on every menu open.

---

## Task 8 — CSVExporter: Non-WiFi interface metadata

**File:** `Sources/MeOrThem/Export/CSVExporter.swift`

In `exportFromDB()`, the WiFi section currently reads:
```swift
lines.append("# Wi-Fi History")
lines.append("Timestamp,RSSI_dBm,SNR_dB,Channel,Band_GHz,TxRate_Mbps")
let wifiRows = sqliteStore.wifiRows(from: from, to: to)
```

Make this conditional, and add a note when no WiFi data is present:

```swift
let wifiRows = sqliteStore.wifiRows(from: from, to: to)
if !wifiRows.isEmpty {
    lines.append("")
    lines.append("# Wi-Fi History")
    lines.append("Timestamp,RSSI_dBm,SNR_dB,Channel,Band_GHz,TxRate_Mbps")
    for w in wifiRows {
        let ts = isoFormatter.string(from: w.timestamp)
        lines.append("\(ts),\(w.rssi),\(w.snr),\(w.channelNumber)," +
                     "\(String(format:"%.1f",w.bandGHz)),\(String(format:"%.0f",w.txRateMbps))")
    }
} else {
    lines.append("")
    lines.append("# Wi-Fi History")
    lines.append("# No Wi-Fi data in this period (Ethernet or VPN connection)")
}
```

Also add session summary at the top of the report (after the period line):

```swift
// After the period line:
let sessions = sqliteStore.sessionsInRange(from: from, to: to)
if !sessions.isEmpty {
    lines.append("# Sessions: \(sessions.map { "\($0.displayName) (\($0.connectionType))" }.joined(separator: ", "))")
}
```

This requires `sessionsInRange(from:to:)` to be publicly available — confirm it is
(`SQLiteStore.sessionsInRange` is already public per the existing code).

---

## Task 9 — JSONExporter: Add `connectionType` and session metadata

**File:** `Sources/MeOrThem/Export/JSONExporter.swift`

In `exportFromDB()`, update the root dictionary:

```swift
// Add sessions array
let sessionsJSON: [[String: Any]] = sqliteStore.sessionsInRange(from: from, to: to).map { s in
    var obj: [String: Any] = [
        "id":             s.id.uuidString,
        "displayName":    s.displayName,
        "connectionType": s.connectionType,
        "startedAt":      iso.string(from: s.startedAt),
        "lastSeen":       iso.string(from: s.lastSeen),
    ]
    if s.weakFingerprint {
        obj["weakFingerprintWarning"] = "Ethernet session without router hardware address — " +
            "may contain data from multiple networks with the same gateway IP and subnet."
    }
    return obj
}

let root: [String: Any] = [
    "exportedAt":     iso.string(from: Date()),
    "periodFrom":     iso.string(from: from),
    "periodTo":       iso.string(from: to),
    "appVersion":     Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
    "sessions":       sessionsJSON,          // NEW
    "targets":        targetsJSON,
    "bandwidthTests": speedtestJSON,
    "wifi":           wifiJSON,
    "dnsResolvers":   dnsResolversJSON,
]
```

---

## Task 10 — PDFExporter: Replace WiFi-only section with conditional block

**File:** `Sources/MeOrThem/Export/PDFExporter.swift`

Locate the WiFi history block (around line 120):

```swift
let wifiRows = sqliteStore.wifiRows(from: from, to: to)
if !wifiRows.isEmpty {
    // ... existing WiFi table rendering ...
} else {
    // Add a simple informational line instead of a blank section
    if !page.hasRoom(30) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
    page.sectionHeader("WI-FI HISTORY")
    page.text("No Wi-Fi data in this period. Connection type: Ethernet or VPN.", color: .secondaryLabelColor)
    page.gap(6); page.hline(); page.gap(10)
}
```

Also add a session summary section just after the title/period block (before Ping Targets):

```swift
let sessions = sqliteStore.sessionsInRange(from: from, to: to)
if !sessions.isEmpty {
    page.sectionHeader("NETWORK SESSIONS")
    for s in sessions {
        let start = localFmt.string(from: s.startedAt)
        let end   = localFmt.string(from: s.lastSeen)
        var line  = "\(s.displayName)  [\(s.connectionType)]  \(start) – \(end)"
        page.dotRow(color: .secondaryLabelColor, text: line)
        if s.weakFingerprint {
            page.text("  ⚠ Router hardware address unavailable — session may combine multiple networks.",
                      color: .systemOrange)
        }
    }
    page.gap(8); page.hline(); page.gap(12)
}
```

**Note:** `page.text(color:)` may not exist — add it to `PageCanvas` if needed, or use
`page.dotRow(color:text:)` with appropriate indentation.

---

## Task 11 — LogExporter: Add `appendInterfaceSnapshot()` for non-WiFi

**File:** `Sources/MeOrThem/Storage/LogExporter.swift`

Add a new method alongside `appendWiFi()`:

```swift
/// Appends a non-WiFi interface snapshot row to the CSV log.
/// Called once per session open for Ethernet/VPN sessions.
func appendInterfaceSnapshot(interfaceName: String,
                              connectionType: String,
                              localIP: String?,
                              gatewayIP: String?) {
    guard settings.enableLogRotation, let fh = fileHandle else { return }
    let ts  = Self._isoFormatter.string(from: Date())
    let ip  = localIP  ?? ""
    let gw  = gatewayIP ?? ""
    let row = "\(ts),interface,\(csvQuote(interfaceName)),\(csvQuote(connectionType))," +
              "\(csvQuote(ip)),\(csvQuote(gw)),,\n"
    writeRow(row, to: fh)
}
```

**Call site in AppEnvironment:** In `applySessionKey()`, after opening a new session,
call `logExporter.appendInterfaceSnapshot(...)` when the connection type is not `.wifi`.

---

## Task 12 — NetworkAnalysisWindowController: Connection type display + weak-fingerprint warning

**File:** `Sources/MeOrThem/UI/NetworkAnalysisWindowController.swift`

### 12a — Session list: Show connection type icon/badge

In `SessionListPanel`, each row currently shows `session.displayName` and date range.
Add a connection-type indicator:

```swift
// In the session row view:
let icon: String = switch session.connectionType {
    case "wifi":     "wifi"
    case "ethernet": "cable.connector"
    case "vpn":      "lock.shield"
    default:         "network"
}
Image(systemName: icon)
    .foregroundColor(.secondary)
    .imageScale(.small)
```

### 12b — Findings panel: Weak-fingerprint advisory

In `FindingsPanel`, when `session.weakFingerprint == true`, prepend an advisory before the
findings list:

```swift
if session.weakFingerprint {
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
            .foregroundColor(.orange)
        Text("Router hardware address was unavailable when this session was created. " +
             "If you have connected to multiple different Ethernet networks sharing " +
             "the same gateway IP (\(gatewayIPFromFingerprint(session.fingerprint))) " +
             "and subnet, analysis data may combine measurements from more than one network.")
            .font(.callout)
            .foregroundColor(.secondary)
    }
    .padding(.horizontal)
    .padding(.top, 8)
}
```

Helper `gatewayIPFromFingerprint()`:
```swift
private func gatewayIPFromFingerprint(_ fp: String) -> String {
    // Format: "eth|<gatewayIP>|<subnet>"
    let parts = fp.split(separator: "|")
    return parts.count >= 2 ? String(parts[1]) : "unknown"
}
```

### 12c — Findings panel: WiFi-not-available notice for non-WiFi sessions

When `session.connectionType != "wifi"` and no WiFi-category findings are present
(which will always be the case for Ethernet/VPN since wifiRows will be empty), add
an informational note at the bottom of the findings list:

```swift
// After rendering all findings:
if session.connectionType != "wifi" {
    Divider().padding(.horizontal)
    HStack(spacing: 6) {
        Image(systemName: "wifi.slash")
            .foregroundColor(.secondary)
        Text("Wi-Fi signal analysis not available — \(session.connectionType) connection.")
            .font(.callout)
            .foregroundColor(.secondary)
    }
    .padding(.horizontal)
    .padding(.bottom, 8)
}
```

---

## Task 13 — Tests

**Location:** `Tests/MeOrThemTests/` (or wherever existing tests live — check with Glob).

### NetworkSessionKeyTests.swift (new file)

```swift
// WiFi factory
testFromWifi_returnsNilWhenNoGateway()
testFromWifi_buildsCorrectFingerprint()

// Ethernet factory — with MAC
testFromEthernet_withMAC_strongFingerprint()
// Ethernet factory — without MAC
testFromEthernet_withoutMAC_weakFingerprintFlagged()
testFromEthernet_withoutMAC_fingerprintExcludesMAC()

// VPN factory
testFromVPN_buildsCorrectFingerprint()
testFromVPN_weakFingerprintIsFalse()

// Equality / session change detection
testSameFingerprint_isEqual()
testDifferentGateway_isNotEqual()
testEthernetSameIPDifferentMAC_isNotEqual()

// ConnectionType rawValues
testConnectionTypeRawValues()
```

### NetworkInfoTests.swift (add to existing if present, else new)

```swift
// gatewayMACAddress parsing
testMACParsing_validLine_returnsMac()
testMACParsing_incompleteLine_returnsNil()
testMACParsing_emptyOutput_returnsNil()

// defaultGatewayInterface parsing
testRouteInfoParsing_extractsInterface()
testRouteInfoParsing_missingInterface_returnsNil()
```

Write these as pure unit tests against the parsing logic (inject mock output strings rather
than running real subprocesses, similar to existing test patterns in the project).

---

## Task 14 — Tests (final pass)

After all prior tasks are complete, run the full test suite one final time and confirm
all tests pass. No code changes in this task — this is a verification checkpoint only.
No separate commit needed if no code changed.

---

## Implementation Order

Work through tasks in this order to avoid circular dependencies.
**Each task ends with a test run, version bump, changelog entry, commit, and push** per the
rule at the top of this document.

1. **Task 1** — NetworkInfo additions (foundation; everything else builds on these)
2. **Task 2** — NetworkSessionKey (depends on no other task)
3. **Task 3** — SQLiteStore schema (depends on Task 2 for connectionType string)
4. **Task 5** — MonitoringEngine `"en0"` fix (depends on Task 1)
5. **Task 6** — WiFiMonitor comment (depends on nothing; trivial)
6. **Task 4** — AppEnvironment rewiring (depends on Tasks 1, 2, 3)
7. **Task 7** — MenuBuilder VPN branch (depends on Task 1)
8. **Task 11** — LogExporter (depends on Task 4 for the call site)
9. **Task 8** — CSVExporter (depends on Task 3 for sessionsInRange with new fields)
10. **Task 9** — JSONExporter (depends on Task 3)
11. **Task 10** — PDFExporter (depends on Task 3)
12. **Task 12** — NetworkAnalysisWindowController UI (depends on Task 3)
13. **Task 13** — Tests (depends on Tasks 1 and 2; extend/add tests, then commit)
14. **Task 14** — Final test-suite verification checkpoint (no commit if no code changed)

---

## Edge Cases and Gotchas

**CombineLatest fires on every gateway-IP tick:**
`metricStore.$latestGatewayIP` fires each poll tick. The `lastNonWifiGatewayIP` guard in
Task 4 ensures the ARP subprocess and detached task are only spawned when the gateway IP
actually changes, not on every tick.

**ARP cache miss at session open time:**
If the ARP cache doesn't yet have an entry for the gateway (e.g., immediately after booting),
`gatewayMACAddress()` returns nil and a weak-fingerprint session is created. If on the next
check the MAC becomes available and the fingerprint changes, a new session would open
incorrectly. To prevent this: if the current session is an Ethernet session with a weak
fingerprint AND the gateway IP hasn't changed, attempt to upgrade the fingerprint by retrying
the ARP lookup. If a MAC is found, call `sqliteStore.upgradeSessionFingerprint(id:newFingerprint:)`
(new function, simple UPDATE query). Add this retry in the `applySessionKey()` path: when
the new key is Ethernet+withMAC but the only difference from the current fingerprint is the
MAC suffix, upgrade instead of opening a new session.

This "fingerprint upgrade" is an optional polish step — implement only if time allows.
Without it, the user simply gets two sessions for the same network (one weak, one strong)
which is acceptable.

**WiFi → Ethernet transition:**
When the user disconnects WiFi and connects Ethernet, `latestWifi` goes nil and
`latestGatewayIP` fires next tick. The CombineLatest pipeline will see `(nil, gatewayIP)`
and enter the Ethernet path. This is correct.

**Ethernet → WiFi transition:**
When the user connects to WiFi while already on Ethernet, `latestWifi` becomes non-nil and
the WiFi path takes priority (it's the first branch in `updateNetworkSession`). Correct.

**VPN on top of WiFi:**
When the user activates a VPN while on WiFi, `defaultGatewayInterface()` will return the
VPN tunnel interface (e.g., `utun3`) since it carries the new default route. However,
`latestWifi` is still non-nil (WiFi is still connected at Layer 2). The `CombineLatest`
pipeline prefers WiFi when `wifi != nil`. This means a VPN session is NOT created — the
WiFi session continues. This is arguably correct behaviour: the underlying physical
connection hasn't changed, only routing. The Network Analysis session accurately reflects
the physical network environment. VPN latency changes will appear as degradation within
the WiFi session. **Do not change this behaviour** — creating a separate VPN session for
each VPN activation would fragment data unhelpfully.

**Interface name stability:**
`utun` interface numbers (e.g., `utun3`) are assigned by the kernel and can vary across VPN
reconnections. The fingerprint includes the interface name — this is intentional. Different
`utun` assignments mean different VPN tunnel instances; a new session is appropriate.

**`NetworkInfo.ethernetInfo(excluding:)` vs `defaultGatewayInterface()`:**
Both are used. `ethernetInfo(excluding:)` iterates all `en*` interfaces and picks the first
with a non-loopback IPv4. `defaultGatewayInterface()` asks the routing table directly and
is more reliable (it's the interface that actually carries traffic). For MAC lookup in the
menu (Task 7 Ethernet branch), `ethernetInfo()` is correct. For session fingerprinting and
interface error sampling (Tasks 4, 5), `defaultGatewayInterface()` is more reliable.

**`_runMigrations()` idempotency:**
SQLite returns `SQLITE_ERROR` when `ALTER TABLE ... ADD COLUMN` tries to add an already-
existing column. The `_exec()` helper silently discards all errors. This is the existing
pattern and is safe for this migration.

---

## Testing Checklist (Manual)

After implementation, verify on a real Mac:

- [ ] Connect via WiFi → check Network Details menu shows WiFi section with RSSI/channel
- [ ] Connect via Ethernet (disable WiFi) → check menu shows "Ethernet — enX" with IP/router/MAC
- [ ] Activate VPN (while WiFi is off, Ethernet is on) → menu unchanged (VPN on Ethernet = same physical network)
- [ ] Activate VPN (while only WiFi is on) → menu shows WiFi (not VPN — see edge case above)
- [ ] Connect via VPN only (no WiFi, no Ethernet) → check menu shows "VPN — utunX" with IP/router
- [ ] Switch between two WiFi networks → Network Analysis shows two sessions
- [ ] Unplug Ethernet, plug into different router (same IP/subnet) → Network Analysis shows two sessions IF MAC was different
- [ ] Open Network Analysis with Ethernet session → session list shows "cable.connector" icon; findings panel shows "Wi-Fi signal analysis not available" notice
- [ ] Export CSV, JSON, PDF on Ethernet session → sessions section present; Wi-Fi section shows "No Wi-Fi data" note
- [ ] Run `swift run MeOrThemTests` → 325+ passing
