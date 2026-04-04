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
    --message-callback '
import re
msg = re.sub(rb"[ \t]*Co-Authored-By: Claude[^\n]*\n?", b"", message)
return msg.strip() + b"\n"
' \
    --force

# ── Produce README.md from cleaned CLAUDE.md ───────────────────────────────────
# CLAUDE.md was stripped from history above; we generate README.md fresh
# from the current local copy and add it as a single new commit.
echo "==> Generating README.md..."
python3 - "$ROOT_DIR/CLAUDE.md" <<'PY'
import re, pathlib, sys

text = pathlib.Path(sys.argv[1]).read_text()

# Remove the AI workflow section entirely
text = re.sub(
    r"\n## 🤖 AI Workflow & Rules\n.*?(?=\n## |\Z)",
    "",
    text,
    flags=re.DOTALL
)

# Remove internal-only lines
drop_if_contains = [
    "Note: Info.plist CFBundleShortVersionString",
    "Context Check: /context",
    "git push github main",
    "publish_github.sh",
    "create a GitHub Release",
    "PROGRESS.md",
    "FIXES.md",
    "git.kanzie.com",
]
lines = [
    l for l in text.splitlines()
    if not any(d in l for d in drop_if_contains)
]

# Rename the title to reflect it's a README
out = "\n".join(lines).rstrip() + "\n"
pathlib.Path("README.md").write_text(out)
PY

git add README.md
git commit -m "docs: add README.md"

# ── Push to GitHub ─────────────────────────────────────────────────────────────
echo "==> Pushing to GitHub..."
git remote add github "$GITHUB_URL"
git push github main --force

# ── GitHub Release ─────────────────────────────────────────────────────────────
echo "==> Creating GitHub release v${VERSION}..."
cd "$ROOT_DIR"

RELEASE_NOTES="### Install
1. Download \`MeOrThem.dmg\` below
2. Open the DMG and drag **MeOrThem.app** to Applications
3. First launch: right-click → Open (Gatekeeper warning expected — app is ad-hoc signed, source is open for inspection)

**Requires macOS 13 Ventura or later · Apple Silicon & Intel**"

if gh release view "v${VERSION}" --repo kanzie/meorthem &>/dev/null 2>&1; then
    echo "    Release v${VERSION} exists — uploading DMG assets..."
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
