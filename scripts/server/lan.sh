#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

print_help() {
  cat <<EOF
Usage: scripts/server/lan.sh

Starts wheatleyd for explicitly trusted LAN use on 0.0.0.0:8765.

Examples:
  WHEATLEY_TRUSTED_LAN=yes scripts/server/lan.sh
  WHEATLEY_NATIVE_ORIGIN=tauri://localhost scripts/server/lan.sh

Health check from another computer:
  curl http://<server-hostname>.local:8765/api/status

Connect a console client:
  WHEATLEY_API_BASE=http://<server-hostname>.local:8765/api \\
    scripts/console-client/run.sh run-profiles/local.json

This mode has no authentication. Anyone who can reach the server can access
profile history and invoke whatever tools are enabled in the private config.
The default CORS origin permits a production Apple Tauri client.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

if [[ "${WHEATLEY_TRUSTED_LAN:-no}" != "yes" ]]; then
  echo "[wheatley-server] LAN mode has no authentication." >&2
  echo "[wheatley-server] It exposes profile history and enabled agent tools to the network." >&2
  echo "[wheatley-server] Set WHEATLEY_TRUSTED_LAN=yes only on a network you trust." >&2
  exit 1
fi

if [[ $# -ne 0 ]]; then
  print_help >&2
  exit 2
fi
export WHEATLEY_NATIVE_ORIGIN="${WHEATLEY_NATIVE_ORIGIN:-tauri://localhost}"
exec "$script_dir/local.sh" "$repo_root/run-profiles/lan.json"
