#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/server/local.sh [RUN_PROFILE.json]"
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: scripts/server/local.sh [RUN_PROFILE.json]" >&2
  exit 2
fi

run_profile="${1:-$repo_root/run-profiles/local.json}"
run_profile="$(cd "$(dirname "$run_profile")" && pwd)/$(basename "$run_profile")"
[[ -f "$run_profile" ]] || { echo "Run profile not found: $run_profile" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
command -v dub >/dev/null 2>&1 || { echo "dub is required" >&2; exit 1; }

IFS=$'\t' read -r listen_host port < <(
  node --input-type=module - "$run_profile" <<'NODE'
import fs from "node:fs";

const profile = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const host = profile?.shared?.api?.listen_host;
const port = profile?.shared?.api?.port;
if (typeof host !== "string" || !Number.isInteger(port))
  throw new Error("Run profile requires shared.api.listen_host and shared.api.port.");
process.stdout.write(`${host}\t${port}\n`);
NODE
)
listen="$listen_host:$port"

listener_pids=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && listener_pids+=("$pid")
done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)

if ((${#listener_pids[@]})); then
  for pid in "${listener_pids[@]}"; do
    command_path="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$command_path" != *"/wheatleyd" && "$command_path" != "wheatleyd" ]]; then
      echo "Port $port is occupied by a non-Wheatley process." >&2
      exit 1
    fi
  done
  kill -TERM "${listener_pids[@]}" 2>/dev/null || true
  for _ in $(seq 1 40); do
    lingering=false
    for pid in "${listener_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        lingering=true
        break
      fi
    done
    $lingering || break
    sleep 0.25
  done
  for pid in "${listener_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for _ in $(seq 1 40); do
    lingering=false
    for pid in "${listener_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        lingering=true
        break
      fi
    done
    $lingering || break
    sleep 0.25
  done
  if $lingering; then
    echo "Previous Wheatley process did not exit." >&2
    exit 1
  fi
fi

echo "[wheatley-server] starting at http://$listen from $run_profile"
cd "$repo_root/server/wheatleyd"
exec dub run -- "$run_profile"
