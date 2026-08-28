#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../env.sh
source "$repo_root/scripts/env.sh"
remote_host="${WHEATLEY_IMAGE_REMOTE_HOST:-}"
remote_root="${WHEATLEY_IMAGE_REMOTE_ROOT:-}"
label="dev.wheatley.image-worker"
token_path="$WHEATLEY_IMAGE_TOKEN_PATH"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/image-worker/install-remote.sh"
  echo "Required: WHEATLEY_IMAGE_REMOTE_HOST and WHEATLEY_IMAGE_REMOTE_ROOT"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/image-worker/install-remote.sh" >&2
  exit 2
fi
[[ -n "$remote_host" ]] || { echo "Set WHEATLEY_IMAGE_REMOTE_HOST." >&2; exit 1; }
[[ -n "$remote_root" ]] || { echo "Set WHEATLEY_IMAGE_REMOTE_ROOT." >&2; exit 1; }
[[ -f "$token_path" ]] || { echo "Run scripts/install/setup.sh first: token is missing." >&2; exit 1; }

remote_service="$remote_root/services/image-worker"
remote_token="$remote_root/app-data/user/image-generation-token"
remote_home="$(ssh "$remote_host" 'printf %s "$HOME"')"
launch_agents="$remote_home/Library/LaunchAgents"
plist="$launch_agents/$label.plist"

ssh "$remote_host" "mkdir -p '$remote_service' '$remote_root/app-data/user' '$launch_agents'"
scp "$repo_root/services/image-worker/worker.py" \
  "$repo_root/services/image-worker/run.sh" \
  "$repo_root/services/image-worker/setup-runtime.sh" \
  "$remote_host:$remote_service/"
scp "$token_path" "$remote_host:$remote_token"
ssh "$remote_host" "chmod 700 '$remote_service/run.sh' '$remote_service/setup-runtime.sh'; chmod 600 '$remote_token'"
ssh "$remote_host" "DEVELOPER_DIR='$remote_root/app-data/toolchains/Xcode.app/Contents/Developer' '$remote_service/setup-runtime.sh'"

plist_file="$(mktemp)"
trap 'rm -f "$plist_file"' EXIT
sed \
  -e "s|__LABEL__|$label|g" \
  -e "s|__PROGRAM__|$remote_service/run.sh|g" \
  -e "s|__LOG_ROOT__|$remote_root/app-data/image-generation/bonsai-image-demo/logs|g" \
  "$repo_root/services/image-worker/launchd.plist.template" > "$plist_file"
scp "$plist_file" "$remote_host:$plist"
ssh "$remote_host" "mkdir -p '$remote_root/app-data/image-generation/bonsai-image-demo/logs'; launchctl bootout gui/\$(id -u) '$plist' >/dev/null 2>&1 || true; launchctl bootstrap gui/\$(id -u) '$plist'; launchctl kickstart -k gui/\$(id -u)/$label"

echo "[image-worker] installed $label on $remote_host"
