#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/install/enable-image-tools.sh"
  echo "Adds the current image-generation presets and enables both image tools without changing other private config."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/install/enable-image-tools.sh" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[[ -f "$WHEATLEY_CONFIG_PATH" ]] || { echo "Private config is missing: $WHEATLEY_CONFIG_PATH" >&2; exit 1; }

config_dir="$(dirname "$WHEATLEY_CONFIG_PATH")"
staged="$(mktemp "$config_dir/.config.image-tools.XXXXXX")"
backup="$WHEATLEY_CONFIG_PATH.before-image-tools"
trap 'rm -f "$staged"' EXIT

jq --slurpfile defaults "$WHEATLEY_RESOURCES_ROOT/config.default.json" '
  .image_generation //= $defaults[0].image_generation
  | .tools.available.generate_image = true
  | .tools.available.image_search = true
' "$WHEATLEY_CONFIG_PATH" > "$staged"
jq empty "$staged"
if cmp -s "$staged" "$WHEATLEY_CONFIG_PATH"; then
  echo "[image-tools] private config is already current"
  exit 0
fi
if [[ ! -f "$backup" ]]; then
  cp "$WHEATLEY_CONFIG_PATH" "$backup"
  chmod 600 "$backup"
fi
chmod 600 "$staged"
mv "$staged" "$WHEATLEY_CONFIG_PATH"
echo "[image-tools] enabled image tools in $WHEATLEY_CONFIG_PATH"
echo "[image-tools] preserved original config at $backup"
