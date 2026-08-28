#!/usr/bin/env bash
set -euo pipefail

worker_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$worker_root/environment.sh" &&
      -x "$worker_root/wheatley-codexd" &&
      -f "$worker_root/run-profile.json" ]]; then
  # Installed LaunchAgent runtime, kept outside macOS protected Documents paths.
  # shellcheck source=/dev/null
  source "$worker_root/environment.sh"
  binary="$worker_root/wheatley-codexd"
  run_profile="$worker_root/run-profile.json"
else
  repo_root="$(cd "$worker_root/../.." && pwd)"
  # shellcheck source=../../scripts/env.sh
  source "$repo_root/scripts/env.sh"
  binary="$repo_root/server/wheatleyd/wheatley-codexd"
  run_profile="${WHEATLEY_RUN_PROFILE:-$repo_root/run-profiles/local.json}"
fi

export PATH="/Applications/ChatGPT.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

[[ -x "$binary" ]] || { echo "Codex worker binary is missing: $binary" >&2; exit 1; }
[[ -f "$run_profile" ]] || { echo "Run profile is missing: $run_profile" >&2; exit 1; }

exec "$binary" "$run_profile"
