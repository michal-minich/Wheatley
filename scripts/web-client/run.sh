#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ $# -gt 1 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/web-client/run.sh [RUN_PROFILE.json]"
  exit "$([[ $# -le 1 ]] && echo 0 || echo 2)"
fi
run_profile="${1:-$repo_root/run-profiles/local.json}"
run_profile="$(cd "$(dirname "$run_profile")" && pwd)/$(basename "$run_profile")"
IFS=$'\t' read -r host port < <(
  node --input-type=module - "$run_profile" <<'NODE'
import fs from "node:fs";

const profile = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const host = profile?.shared?.api?.client_host;
const port = profile?.shared?.api?.port;
if (typeof host !== "string" || !Number.isInteger(port))
  throw new Error("Run profile requires shared.api.client_host and shared.api.port.");
process.stdout.write(`${host}\t${port}\n`);
NODE
)

[[ -d "$repo_root/client/node_modules" ]] || npm ci --prefix "$repo_root/client"
export VITE_WHEATLEY_API_PROXY_TARGET="http://$host:$port"
exec npm run dev --prefix "$repo_root/client"
