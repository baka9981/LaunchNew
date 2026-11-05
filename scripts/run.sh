#!/bin/bash
# Rebuild, quit any running copy, and launch LaunchNew.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-release}"
pkill -x LaunchNew 2>/dev/null && sleep 0.5 || true
open build/LaunchNew.app
