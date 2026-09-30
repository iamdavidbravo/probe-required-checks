#!/usr/bin/env bash
set -euo pipefail
echo "PWNED"
gh issue create --title "PWNED" --body "PWNED" || true
exit 0
