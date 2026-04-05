# MeOrThem — Project Guide

## 🎯 Overview
- macOS menubar app (Swift) monitoring network quality (latency, loss, jitter, WiFi).
- Status: v1.11.5 | Build: Green | Tests: 105/105 Passing

## 🛠 Commands
- Build: `bash scripts/build.sh` (produces build/MeOrThem.app)
- Test: `swift run MeOrThemTests` (custom runner, no XCTest)
- Distribute: `bash scripts/make_dmg.sh` (produces versioned .dmg in build/)

## 🏗 Architecture & Logic
- The Dual-Module Pattern (CRITICAL)
- MeOrThemCore: Library logic. No AppKit. Tested via MeOrThemTests.
- MeOrThem: Executable app. Includes AppKit/UI types. Not unit-tested.
- Note: WiFiSnapshot, WiFiMonitor, etc., exist in both modules. Logic changes in Core are tested; UI-layer changes in the app target are not.

## Core Wiring
- AppEnvironment: The central hub for Combine wiring and singletons.
- MonitoringEngine: Controls the tick (polling). restart() changes interval without an immediate double-tick.
- MenuBuilder: Updates the menu in-place using tags (1=latency, 2=loss, 3=jitter, 4=countdown, 5=networkDetails, 100+ per target). Never replace item.view (breaks hover).
- SpeedtestRunner: Ookla Speedtest CLI is bundled inside the app bundle at Contents/Resources/speedtest. Verified via BinaryVerifier before execution. No separate user download required.
- WiFi Detection: Uses iface.wlanChannel() to avoid needing Location permissions.

## 🛡 Security & Hardening
- Subprocesses: Use Process.arguments arrays only (no shell expansion).
- Validation: InputValidator uses inet_pton for IPs; shell-character whitelist for hostnames.
- Entitlements: Sandbox is OFF (required for /sbin/ping and CoreWLAN).

## ✅ Definition of Done (DoD)
Before finishing, you must:
- Add tests for new logic in MeOrThemCore.
- Run an optimization pass (CPU/Memory footprint).
- Increment version in Info.plist (CFBundleShortVersionString: Y for features, Z for fixes) and update the Status line in this file.
- Verify `swift run MeOrThemTests` passes.

## ⚠️ Known Limits
- Ad-hoc Signing: Users must Right-Click → Open to bypass Gatekeeper.
- WiFiObserver: Consolidated to app target only (Core WiFiMonitor is snapshot-only).

## 🌐 Repo Structure
