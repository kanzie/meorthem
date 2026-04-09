#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"

echo "🔍 Running Privacy Guard..."

# 1. Check if .env is ignored
if git check-ignore -q "$ENV_FILE"; then
    echo "  ✅ .env is correctly ignored by git."
else
    echo "  ❌ ERROR: .env is NOT ignored by git! Add '.env' to your .gitignore immediately."
    exit 1
fi

# 2. Check for hardcoded secrets from .env
if [ -f "$ENV_FILE" ]; then
    echo "  Checking for leaked secrets..."
    
    # Extract values from .env (ignoring comments and keys)
    # We look for values longer than 4 chars to avoid false positives with short strings
    SECRETS=$(grep -v '^#' "$ENV_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//' | grep '....')

    while read -r SECRET; do
        if [ -z "$SECRET" ]; then continue; fi
        
        # Search all tracked files for this secret, excluding the .env file itself
        FOUND=$(git grep -lF "$SECRET" -- :/ | grep -Ev "\.env|env\.example" || true)
        
        if [ -n "$FOUND" ]; then
            echo "  ❌ LEAK DETECTED: A secret from your .env was found hardcoded in:"
            echo "$FOUND" | sed 's/^/     - /'
            exit 1
        fi
    done <<< "$SECRETS"
    echo "  ✅ No hardcoded secrets found in tracked files."
else
    echo "  ⚠️  No .env file found to check against. Skipping leak scan."
fi

echo "==> ✨ Privacy check passed. Safe to commit."