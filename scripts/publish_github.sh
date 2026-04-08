#!/usr/bin/env bash
# scripts/publish_github.sh
#
# Publishes a clean release to github.com/kanzie/meorthem.
# Your local repo and git.kanzie.com are NEVER touched.
#
# What this does:
#   1. Builds the app and DMG (if not already built for this version)
#   2. Clones the repo into a temp directory
#   3. Strips non-app files (website, .claude/, internal docs)
#   4. Strips "Co-Authored-By: Claude" from all commit messages
#   5. Produces README.md from a cleaned CLAUDE.md (AI section removed)
#   6. Force-pushes clean history to github main
#   7. Creates (or updates) a GitHub Release and uploads the DMG
#
# Commit history on GitHub:
#   The full commit history is preserved (minus stripped files/messages).
#   Each run rewrites + force-pushes, so GitHub SHAs will change — this is
#   expected and fine for a solo project. GitHub users should not rely on SHAs.
#
# Prerequisites:
#   brew install git-filter-repo gh
#   gh auth login
#   git remote add github git@github.com:kanzie/meorthem.git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Version ────────────────────────────────────────────────────────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$ROOT_DIR/Sources/MeOrThem/Resources/Info.plist" 2>/dev/null) || {
    echo "❌  Could not read version from Info.plist"
    exit 1
}

echo ""
echo "  MeOrThem v${VERSION} — GitHub publish"
echo "  ════════════════════════════════════"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────────
missing=0
for cmd in gh git-filter-repo python3; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            gh)              echo "❌  GitHub CLI not found.   Fix: brew install gh && gh auth login" ;;
            git-filter-repo) echo "❌  git-filter-repo not found. Fix: brew install git-filter-repo" ;;
            python3)         echo "❌  python3 not found." ;;
        esac
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

GITHUB_URL=$(git -C "$ROOT_DIR" remote get-url github 2>/dev/null) || {
    echo "❌  'github' remote not configured."
    echo "    Fix: git remote add github git@github.com:kanzie/meorthem.git"
    exit 1
}

# ── Uncommitted changes check ──────────────────────────────────────────────────
if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "❌  Uncommitted changes detected."
    echo "    Commit and push to origin before publishing."
    exit 1
fi

# ── Build app + DMG ────────────────────────────────────────────────────────────
VERSIONED_DMG="$ROOT_DIR/build/MeOrThem-${VERSION}.dmg"
GENERIC_DMG="$ROOT_DIR/build/MeOrThem.dmg"

if [ ! -f "$VERSIONED_DMG" ]; then
    echo "==> Building app..."
    bash "$SCRIPT_DIR/build.sh"
    echo "==> Creating DMG..."
    bash "$SCRIPT_DIR/make_dmg.sh"
else
    echo "==> DMG already built: MeOrThem-${VERSION}.dmg"
fi

[ -f "$VERSIONED_DMG" ] || { echo "❌  DMG not found after build: $VERSIONED_DMG"; exit 1; }

# MeOrThem.dmg is what the website download link points to:
# github.com/.../releases/latest/download/MeOrThem.dmg
cp "$VERSIONED_DMG" "$GENERIC_DMG"

# ── Clean clone ────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
CLEAN_REPO="$WORK_DIR/repo"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Cloning repo..."
git clone --no-local "$ROOT_DIR" "$CLEAN_REPO"
cd "$CLEAN_REPO"

# ── Filter history ─────────────────────────────────────────────────────────────
echo "==> Filtering history..."
git filter-repo \
    --invert-paths \
    --path .claude \
    --path CLAUDE.md \
    --path CLAUDE.md.old \
    --path PROGRESS.md \
    --path FIXES.md \
    --path index.html \
    --path images \
    --path scripts/deploy_website.sh \
    --message-callback '
import re
msg = re.sub(rb"[ \t]*Co-Authored-By: Claude[^\n]*\n?", b"", message)
return msg.strip() + b"\n"
' \
    --force

# ── Produce README.md ─────────────────────────────────────────────────────────
echo "==> Generating README.md..."
cat > README.md <<README
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
- Optional daily log rotation to \`~/Library/Logs/MeOrThem/\`

## Install

1. Download **MeOrThem.dmg** from the [latest release](https://github.com/kanzie/meorthem/releases/latest)
2. Open the DMG and drag **MeOrThem.app** to Applications
3. First launch: macOS will inform you that this Application is downloaded from the Internet, 
and then might ask if you want this added to your startup - it is recommended that you accept this. 
MeOrThem has been built with resource efficiency in its core and you will not notice it running on your machine.

**Requires macOS 14 Sonoma or later · Apple Silicon & Intel**

## Build from source

**Requirements:** macOS 14+, Swift 5.9+, Xcode Command Line Tools

\`\`\`bash
git clone https://github.com/kanzie/meorthem.git
cd meorthem
bash scripts/build.sh        # → build/MeOrThem.app
bash scripts/make_dmg.sh     # → build/MeOrThem-x.y.z.dmg
\`\`\`

**Run tests:**
\`\`\`bash
swift run MeOrThemTests
\`\`\`

115 unit tests covering core monitoring logic, metric status, fault isolation, CSV export, jitter calculation, and more. Uses a custom test runner — no XCTest dependency. 
This is why the application uses Dual Module Pattern for its architecture.

## Architecture

Two Swift modules:

| Module | Role |
|--------|------|
| \`MeOrThemCore\` | Pure logic library — no AppKit, fully unit-tested |
| \`MeOrThem\` | Executable app — AppKit/UI layer, wires everything together |

Key components: \`AppEnvironment\` (Combine wiring), \`MonitoringEngine\` (poll loop), \`MenuBuilder\` (in-place NSMenu updates), \`MetricStore\` (hysteresis + fault type), \`SpeedtestRunner\` (process lifecycle), \`StatusBarIconRenderer\` (cached NSImage drawing).

## Security

- **No shell injection** — all subprocesses use argument arrays, never string interpolation
- **Input validation** — IPs validated with \`inet_pton\`; hostnames pass a strict character whitelist
- **Binary integrity** — the bundled speedtest CLI is SHA-256 verified before execution
- **No Location permission** — WiFi details obtained via CoreWLAN/SCDynamicStore APIs
- **Hardened pointer handling** — every network interface pointer is nil-guarded before dereference
- **No telemetry** — no analytics, no network calls you didn't initiate, no cloud anything

## License

MIT — see [LICENSE](LICENSE) for details.
README

git add README.md
git commit -m "docs: add README.md"

# ── Push to GitHub ─────────────────────────────────────────────────────────────
echo "==> Pushing to GitHub..."
git remote add github "$GITHUB_URL"
git push github main --force

# ── GitHub Release ─────────────────────────────────────────────────────────────
echo "==> Creating GitHub release v${VERSION}..."
cd "$ROOT_DIR"

INSTALL_NOTES="### Install
1. Download \`MeOrThem.dmg\` below
2. Open the DMG and drag **MeOrThem.app** to Applications
3. First launch: macOS will inform you that this Application is downloaded from the Internet, 
and then might ask if you want this added to your startup - it is recommended that you accept this. 
MeOrThem has been built with resource efficiency in its core and you will not notice it running on your machine.


**Requires macOS 14 Sonoma or later · Apple Silicon & Intel**"

# Extract this version's changelog section from CHANGELOG.md (everything under ## vX.Y.Z
# down to the next ## heading or end of file, excluding the heading line itself).
CHANGELOG_SECTION=""
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"
if [ -f "$CHANGELOG_FILE" ]; then
    CHANGELOG_SECTION=$(python3 - "$VERSION" "$CHANGELOG_FILE" <<'PYEOF'
import sys, re
version, path = sys.argv[1], sys.argv[2]
text = open(path).read()
# Match from the version heading through to (but not including) the next heading or EOF.
# Drop the heading line itself and keep only the body.
pattern = r'## v' + re.escape(version) + r'[^\n]*\n(.*?)(?=\n## v|\Z)'
m = re.search(pattern, text, re.DOTALL)
print(m.group(1).strip() if m else '')
PYEOF
)
fi

if [ -n "$CHANGELOG_SECTION" ]; then
    RELEASE_NOTES="${CHANGELOG_SECTION}

---

${INSTALL_NOTES}"
else
    echo "  ⚠️  No CHANGELOG.md entry found for v${VERSION} — using install instructions only."
    RELEASE_NOTES="$INSTALL_NOTES"
fi

if gh release view "v${VERSION}" --repo kanzie/meorthem &>/dev/null 2>&1; then
    echo "    Release v${VERSION} exists — updating notes and uploading DMG assets..."
    gh release edit "v${VERSION}" \
        --notes "$RELEASE_NOTES" \
        --repo kanzie/meorthem
    gh release upload "v${VERSION}" \
        "$VERSIONED_DMG" \
        "$GENERIC_DMG" \
        --clobber \
        --repo kanzie/meorthem
else
    gh release create "v${VERSION}" \
        "$VERSIONED_DMG" \
        "$GENERIC_DMG" \
        --title "v${VERSION}" \
        --notes "$RELEASE_NOTES" \
        --repo kanzie/meorthem
fi

echo ""
echo "  ✅  Published v${VERSION}"
echo ""
echo "  Source:   https://github.com/kanzie/meorthem"
echo "  Release:  https://github.com/kanzie/meorthem/releases/tag/v${VERSION}"
echo "  Download: https://github.com/kanzie/meorthem/releases/latest/download/MeOrThem.dmg"
echo ""

# ── Deploy website ─────────────────────────────────────────────────────────────
bash "$SCRIPT_DIR/deploy_website.sh"
