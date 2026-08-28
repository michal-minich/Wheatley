#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/server/hybrid.sh"
  echo "Requires WHEATLEY_SYNC_UPSTREAM_API_BASE and starts the synced_hybrid composition."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/server/hybrid.sh" >&2
  exit 2
fi
if [[ -z "$WHEATLEY_SYNC_UPSTREAM_API_BASE" ]]; then
  echo "WHEATLEY_SYNC_UPSTREAM_API_BASE is required for synced_hybrid." >&2
  exit 1
fi

exec "$script_dir/local.sh" "$repo_root/run-profiles/hybrid.json"
