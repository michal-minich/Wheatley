#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ $# -ne 1 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/console-client/run.sh RUN_PROFILE.json"
  exit "$([[ $# -eq 1 ]] && echo 0 || echo 2)"
fi

run_profile="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$run_profile" ]] || { echo "Run profile not found: $run_profile" >&2; exit 1; }
command -v dub >/dev/null 2>&1 || { echo "dub is required" >&2; exit 1; }

case "$(uname -s)" in
  Darwin|Linux) "$repo_root/scripts/install/audio-player.sh" ;;
esac
cd "$repo_root/server/wheatleyd"
exec dub run --config=console -- "$run_profile"
