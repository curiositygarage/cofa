#!/usr/bin/env bash
# checks/sanitise.sh — thin shim. The single pre-push gate lives at bin/scan-sanitisation.sh.
# Kept at this path so earlier references/records keep working; it holds no logic of its own.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "note: checks/sanitise.sh now delegates to bin/scan-sanitisation.sh (single gate)"
exec "$ROOT/bin/scan-sanitisation.sh" "$@"
