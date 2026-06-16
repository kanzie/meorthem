#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"

echo "🔍 Running Privacy Guard..."

# 1. Check that .env and .envrc are gitignored
for SENSITIVE_FILE in "$ENV_FILE" "$ROOT_DIR/.envrc"; do
    BASENAME=$(basename "$SENSITIVE_FILE")
    if git -C "$ROOT_DIR" check-ignore -q "$SENSITIVE_FILE" 2>/dev/null; then
        echo "  ✅ $BASENAME is correctly ignored by git."
    else
        echo "  ❌ ERROR: $BASENAME is NOT ignored by git! Add '$BASENAME' to your .gitignore immediately."
        exit 1
    fi
done

# 2. Scan tracked files for common API key patterns (static, no .env required)
echo "  Scanning for common API key patterns..."

# Patterns: Anthropic/OpenAI sk-, AWS AKIA, GitHub tokens, Stripe sk_live/sk_test
API_KEY_PATTERNS=(
    'sk-[a-zA-Z0-9]{20,}'           # Anthropic / OpenAI secret keys (sk-ant-..., sk-proj-...)
    'AKIA[0-9A-Z]{16}'              # AWS access key ID
    '(ghp|gho|ghu|ghs|ghr)_[a-zA-Z0-9]{36,}' # GitHub personal / OAuth / app tokens
    'sk_(live|test)_[a-zA-Z0-9]{24,}' # Stripe secret keys
    'xoxb-[0-9]+-[a-zA-Z0-9]+'     # Slack bot tokens
)

COMBINED_PATTERN=$(IFS='|'; echo "${API_KEY_PATTERNS[*]}")

# git grep across all tracked files, excluding env.example and the script itself
FOUND=$(git -C "$ROOT_DIR" grep -E "$COMBINED_PATTERN" -- ':/' \
    | grep -Ev '(env\.example|verify_secrets\.sh)' || true)

if [ -n "$FOUND" ]; then
    echo "  ❌ API KEY PATTERN DETECTED in tracked files:"
    echo "$FOUND" | sed 's/^/     /'
    exit 1
fi
echo "  ✅ No common API key patterns found in tracked files."

# 3. Check for hardcoded secrets from .env (dynamic, matches actual values)
if [ -f "$ENV_FILE" ]; then
    echo "  Checking for leaked .env values..."

    # Extract values longer than 8 chars (avoids false positives on short strings)
    SECRETS=$(grep -v '^#' "$ENV_FILE" | cut -d'=' -f2- \
        | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//' \
        | grep '........')

    while read -r SECRET; do
        if [ -z "$SECRET" ]; then continue; fi

        FOUND=$(git -C "$ROOT_DIR" grep -lF "$SECRET" -- ':/' \
            | grep -Ev '(\.env$|env\.example)' || true)

        if [ -n "$FOUND" ]; then
            echo "  ❌ LEAK DETECTED: A secret from your .env was found hardcoded in:"
            echo "$FOUND" | sed 's/^/     - /'
            exit 1
        fi
    done <<< "$SECRETS"
    echo "  ✅ No hardcoded .env values found in tracked files."
else
    echo "  ⚠️  No .env file found. Skipping .env value scan."
fi

echo "==> ✨ Privacy check passed. Safe to commit."
