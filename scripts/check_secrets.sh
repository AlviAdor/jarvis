#!/bin/sh
# Fails if anything that looks like a credential is about to be committed or is in the repo.
# Usage: scripts/check_secrets.sh            scan every tracked file
#        scripts/check_secrets.sh --staged   scan only what's staged (used by the pre-commit hook)
#        scripts/check_secrets.sh --history  scan every commit ever made
set -e
cd "$(dirname "$0")/.."

PATTERN='AIza[0-9A-Za-z_-]{35}|sk-ant-[0-9A-Za-z_-]{20,}|sk-(proj-)?[0-9A-Za-z]{32,}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{40,}|xox[baprs]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
BLOCKED='\.(p12|pfx|pem|key|keychain|keychain-db|mobileprovision|env)$'

fail=0
case "$1" in
    --staged)
        files=$(git diff --cached --name-only --diff-filter=ACM)
        if echo "$files" | grep -Eq "$BLOCKED"; then
            echo "Refusing to commit a key or certificate file:"; echo "$files" | grep -E "$BLOCKED"; fail=1
        fi
        if git diff --cached -U0 | grep -E '^\+' | grep -Eq "$PATTERN"; then
            echo "A staged change contains what looks like an API key or private key."; fail=1
        fi
        ;;
    --history)
        if git log -p --all | grep -Eq "$PATTERN"; then
            echo "Something that looks like a credential exists in the git history."; fail=1
        fi
        ;;
    *)
        if git ls-files | grep -Eq "$BLOCKED"; then
            echo "Key or certificate files are tracked:"; git ls-files | grep -E "$BLOCKED"; fail=1
        fi
        if git grep -I -E -l "$PATTERN" -- ':!scripts/check_secrets.sh' >/dev/null 2>&1; then
            echo "These files contain what looks like a credential:"; git grep -I -E -l "$PATTERN" -- ':!scripts/check_secrets.sh'; fail=1
        fi
        ;;
esac

[ "$fail" -eq 0 ] && echo "No secrets found." || exit 1
