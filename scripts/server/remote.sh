#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/server/remote.sh"
  echo "Requires matching sync and Conversation upstream API bases."
  echo "Starts synced_hybrid with remote Conversation placement."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/server/remote.sh" >&2
  exit 2
fi
if [[ -z "$WHEATLEY_SYNC_UPSTREAM_API_BASE" ]]; then
  echo "WHEATLEY_SYNC_UPSTREAM_API_BASE is required for remote Conversation." >&2
  exit 1
fi
if [[ -z "$WHEATLEY_CONVERSATION_REMOTE_API_BASE" ]]; then
  echo "WHEATLEY_CONVERSATION_REMOTE_API_BASE is required for remote Conversation." >&2
  exit 1
fi

exec "$script_dir/local.sh" "$repo_root/run-profiles/remote.json"
