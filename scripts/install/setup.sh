#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

install_voice=false
if [[ "${1:-}" == "--voice" ]]; then
  install_voice=true
  shift
fi
if (($#)); then
  echo "Usage: scripts/install/setup.sh [--voice]" >&2
  exit 2
fi

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "[bootstrap] missing $command_name" >&2
    echo "[bootstrap] $install_hint" >&2
    exit 1
  fi
}

require_command node "Install a current Node.js release."
require_command npm "Install npm with Node.js."
require_command curl "Install curl or run bootstrap from Git Bash."
require_command openssl "Install OpenSSL so Wheatley can create its private image-worker token."

mkdir -p "$WHEATLEY_APP_DATA_ROOT" "$WHEATLEY_HOME" "$WHEATLEY_PROFILES_ROOT"
image_token_path="$WHEATLEY_HOME/image-generation-token"
if [[ ! -f "$image_token_path" ]]; then
  umask 077
  openssl rand -hex 32 > "$image_token_path"
  echo "[bootstrap] created private image-worker token: $image_token_path"
fi
if [[ ! -f "$WHEATLEY_CONFIG_PATH" ]]; then
  cp "$WHEATLEY_RESOURCES_ROOT/config.default.json" "$WHEATLEY_CONFIG_PATH"
  echo "[bootstrap] created private config: $WHEATLEY_CONFIG_PATH"
fi
mkdir -p "$WHEATLEY_HOME/prompts"
for prompt_name in session-auto-memory.md; do
  if [[ ! -f "$WHEATLEY_HOME/prompts/$prompt_name" ]]; then
    cp "$WHEATLEY_RESOURCES_ROOT/prompts/$prompt_name" "$WHEATLEY_HOME/prompts/$prompt_name"
    echo "[bootstrap] created private prompt: $WHEATLEY_HOME/prompts/$prompt_name"
  fi
done
if [[ -f "$WHEATLEY_HOME/prompts/pi-turn-context.md" ]]; then
  for profile_root in "$WHEATLEY_PROFILES_ROOT"/*; do
    [[ -d "$profile_root" ]] || continue
    cp "$repo_root/examples/profiles/wheatley/system.md" "$profile_root/system.md"
  done
  rm "$WHEATLEY_HOME/prompts/pi-turn-context.md"
  echo "[bootstrap] merged the retired Agent instructions into every profile System"
fi
rm -f "$WHEATLEY_HOME/prompts/pi-turn-request.md"
if [[ ! -d "$WHEATLEY_PROFILES_ROOT/wheatley" ]]; then
  cp -R "$repo_root/examples/profiles/wheatley" "$WHEATLEY_PROFILES_ROOT/wheatley"
  echo "[bootstrap] created example profile: $WHEATLEY_PROFILES_ROOT/wheatley"
fi
for profile_root in "$WHEATLEY_PROFILES_ROOT"/*; do
  [[ -d "$profile_root" ]] || continue
  mkdir -p "$profile_root/files"
  profile_config="$profile_root/config.json"
  node --input-type=module - "$profile_config" <<'NODE'
import fs from "node:fs";

const path = process.argv[2];
const config = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, "utf8")) : {};
if (!("workspace" in config)) {
  config.workspace = { path: "files" };
  fs.writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`);
  console.log(`[bootstrap] added profile workspace setting: ${path}`);
} else if (typeof config.workspace !== "object" || config.workspace === null
    || typeof config.workspace.path !== "string" || config.workspace.path.trim() === "") {
  throw new Error(`Invalid profile workspace setting: ${path}`);
}
NODE
done

if ! command -v dub >/dev/null 2>&1 || ! command -v "${DC:-dmd}" >/dev/null 2>&1; then
  echo "[bootstrap] D toolchain is missing or incomplete; installing Wheatley's local toolchain"
  "$script_dir/d.sh"
  # shellcheck source=../env.sh
  source "$script_dir/../env.sh"
fi
require_command dub "Run scripts/install/d.sh and inspect its error."
require_command "${DC:-dmd}" "Run scripts/install/d.sh and inspect its error."

if ! command -v pi >/dev/null 2>&1; then
  pi_npm_spec="${WHEATLEY_PI_NPM_SPEC:-@earendil-works/pi-coding-agent@0.83.0}"
  echo "[bootstrap] Pi is missing; installing $pi_npm_spec with npm"
  npm install --global "$pi_npm_spec"
  hash -r
fi
require_command pi "Install Pi with: npm install --global @earendil-works/pi-coding-agent@0.83.0"

npm ci --prefix "$repo_root/client"
npm ci --prefix "$WHEATLEY_RESOURCES_ROOT/pi" --legacy-peer-deps --ignore-scripts

(
  cd "$repo_root/server/wheatleyd"
  dub build
  dub build --config=console
  dub build --config=codex-worker
)
npm run build --prefix "$repo_root/client"

if $install_voice; then
  "$script_dir/audio.sh"
  "$script_dir/models.sh" english
fi

"$script_dir/check.sh"
