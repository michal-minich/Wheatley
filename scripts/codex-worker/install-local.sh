#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../env.sh
source "$repo_root/scripts/env.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The Codex worker LaunchAgent installer is macOS-only." >&2
  exit 1
fi
[[ -n "$WHEATLEY_CODEX_WORKSPACE_ROOT" ]] || {
  echo "Set WHEATLEY_CODEX_WORKSPACE_ROOT in wheatley.local.env first." >&2
  exit 1
}

(
  cd "$repo_root/server/wheatleyd"
  dub build --config=codex-worker
)
chmod 700 "$repo_root/services/codex-worker/run.sh"

label="dev.wheatley.codexd"
launch_agents="$HOME/Library/LaunchAgents"
log_root="$WHEATLEY_APP_DATA_ROOT/logs"
install_root="$HOME/Library/Application Support/Wheatley/codex-worker"
plist="$launch_agents/$label.plist"
mkdir -p "$launch_agents" "$log_root" "$install_root"

install -m 700 \
  "$repo_root/server/wheatleyd/wheatley-codexd" \
  "$install_root/wheatley-codexd"
install -m 700 \
  "$repo_root/services/codex-worker/run.sh" \
  "$install_root/run.sh"
install -m 600 \
  "$repo_root/services/codex-worker/run-profile.json" \
  "$install_root/run-profile.json"
{
  printf 'export WHEATLEY_PROFILES_ROOT=%q\n' "$WHEATLEY_PROFILES_ROOT"
  printf 'export WHEATLEY_CODEX_WORKSPACE_ROOT=%q\n' "$WHEATLEY_CODEX_WORKSPACE_ROOT"
  printf 'export WHEATLEY_CODEX_SOCKET=%q\n' "$WHEATLEY_CODEX_SOCKET"
} > "$install_root/environment.sh"
chmod 600 "$install_root/environment.sh"

sed \
  -e "s|__LABEL__|$label|g" \
  -e "s|__PROGRAM__|$install_root/run.sh|g" \
  -e "s|__LOG_ROOT__|$log_root|g" \
  "$repo_root/services/codex-worker/launchd.plist.template" > "$plist"

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl kickstart -k "gui/$(id -u)/$label"
echo "[codex-worker] installed $label; socket: $WHEATLEY_CODEX_SOCKET"
