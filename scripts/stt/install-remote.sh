#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../env.sh
source "$repo_root/scripts/env.sh"

role="${1:-final}"
remote_host="${WHEATLEY_STT_REMOTE_HOST:-}"
remote_root="${WHEATLEY_STT_REMOTE_ROOT:-}"

[[ -n "$remote_host" ]] || { echo "Set WHEATLEY_STT_REMOTE_HOST." >&2; exit 1; }
[[ -n "$remote_root" ]] || { echo "Set WHEATLEY_STT_REMOTE_ROOT." >&2; exit 1; }

case "$role" in
  final)
    model_name="ggml-large-v3.bin"
    model_sha="64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
    port="8791"
    ;;
  preview)
    model_name="ggml-small.bin"
    model_sha="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    port="8792"
    ;;
  *)
    echo "Usage: scripts/stt/install-remote.sh [final|preview]" >&2
    exit 2
    ;;
esac

label="dev.wheatley.stt-$role"
local_model="$WHEATLEY_APP_DATA_ROOT/models/whisper/$model_name"
remote_service="$remote_root/services/stt"
remote_model="$remote_root/app-data/models/whisper/$model_name"
remote_log="$remote_root/app-data/stt/$role.log"
remote_home="$(ssh "$remote_host" 'printf %s "$HOME"')"
launch_agents="$remote_home/Library/LaunchAgents"
plist="$launch_agents/$label.plist"

[[ -f "$local_model" ]] || { echo "Missing local model: $local_model" >&2; exit 1; }
[[ "$(shasum -a 256 "$local_model" | awk '{print $1}')" == "$model_sha" ]] || {
  echo "Local model checksum mismatch: $local_model" >&2
  exit 1
}

ssh "$remote_host" "mkdir -p '$remote_service' '$remote_root/app-data/models/whisper' '$remote_root/app-data/stt' '$launch_agents'"
scp \
  "$repo_root/services/stt/run.sh" \
  "$repo_root/services/stt/setup-runtime.sh" \
  "$remote_host:$remote_service/"
ssh "$remote_host" "chmod 700 '$remote_service/run.sh' '$remote_service/setup-runtime.sh'; '$remote_service/setup-runtime.sh'"

remote_model_sha="$(ssh "$remote_host" "if [[ -f '$remote_model' ]]; then shasum -a 256 '$remote_model' | awk '{print \$1}'; fi")"
if [[ "$remote_model_sha" != "$model_sha" ]]; then
  rsync --append-verify --partial --progress "$local_model" "$remote_host:$remote_model.part"
  ssh "$remote_host" "[[ \"\$(shasum -a 256 '$remote_model.part' | awk '{print \$1}')\" == '$model_sha' ]]; mv '$remote_model.part' '$remote_model'"
fi

plist_file="$(mktemp)"
trap 'rm -f "$plist_file"' EXIT
sed \
  -e "s|__LABEL__|$label|g" \
  -e "s|__PROGRAM__|$remote_service/run.sh|g" \
  -e "s|__MODEL__|$remote_model|g" \
  -e "s|__PORT__|$port|g" \
  -e "s|__LOG__|$remote_log|g" \
  "$repo_root/services/stt/launchd.plist.template" > "$plist_file"
scp "$plist_file" "$remote_host:$plist"
ssh "$remote_host" "launchctl bootout gui/\$(id -u) '$plist' >/dev/null 2>&1 || true; launchctl bootstrap gui/\$(id -u) '$plist'; launchctl kickstart -k gui/\$(id -u)/$label"

echo "[stt] installed $label at http://$remote_host:$port"
