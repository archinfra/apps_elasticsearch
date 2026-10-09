#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/install.sh}"
cat "$ROOT"/scripts/install/modules/*.sh > "$OUTPUT"
chmod +x "$OUTPUT"
