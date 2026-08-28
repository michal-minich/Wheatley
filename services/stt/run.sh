#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: services/stt/run.sh MODEL PORT" >&2
  exit 2
fi

service_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary="$service_root/runtime/bin/whisper-server"
model="$1"
port="$2"

[[ -x "$binary" ]] || { echo "Missing whisper-server: $binary" >&2; exit 1; }
[[ -f "$model" ]] || { echo "Missing Whisper model: $model" >&2; exit 1; }

exec "$binary" \
  --host 0.0.0.0 \
  --port "$port" \
  --model "$model" \
  --language auto
