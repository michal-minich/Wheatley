#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/probes/offline-readiness.sh [API_BASE]"
  echo "Read-only preflight for a running standalone_local Wheatley daemon."
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: scripts/probes/offline-readiness.sh [API_BASE]" >&2
  exit 2
fi

api_base="${1:-http://127.0.0.1:8765/api}"
api_base="${api_base%/}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

"$repo_root/scripts/install/check.sh"

health="$(curl --fail --silent --show-error --max-time 10 "$api_base/health")"
jq -e '
  .ok == true
  and .deployment_composition == "standalone_local"
  and .pi.available == true
  and .pi.critical == true
' <<<"$health" >/dev/null

profiles="$(curl --fail --silent --show-error --max-time 10 "$api_base/profiles")"
jq -e '.profiles | type == "array" and length > 0' <<<"$profiles" >/dev/null

echo "Offline readiness preflight passed."
echo "  API:         $api_base"
echo "  composition: $(jq -r '.deployment_composition' <<<"$health")"
echo "  Pi:          $(jq -r '.pi.version' <<<"$health")"
echo "  profiles:    $(jq -r '.profiles | length' <<<"$profiles")"
echo "This is read-only preflight evidence, not the WAN-disabled voice-turn gate."
