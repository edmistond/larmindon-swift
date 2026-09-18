#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3.9+ is required for local checks (no Python packages needed)." >&2
  exit 1
fi
exec python3 -B scripts/check.py "$@"
