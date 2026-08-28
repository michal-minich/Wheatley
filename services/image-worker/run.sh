#!/usr/bin/env bash
set -euo pipefail

worker_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$worker_root/../.." && pwd)"
demo_root="${BONSAI_DEMO_ROOT:-$repo_root/app-data/image-generation/bonsai-image-demo}"
developer_dir="${DEVELOPER_DIR:-$repo_root/app-data/toolchains/Xcode.app/Contents/Developer}"
token_path="${WHEATLEY_IMAGE_TOKEN_PATH:-$repo_root/app-data/user/image-generation-token}"

[[ -d "$demo_root" ]] || { echo "Bonsai demo is missing: $demo_root" >&2; exit 1; }
[[ -x "$demo_root/.venv/bin/python" ]] || { echo "Bonsai environment is missing: $demo_root/.venv" >&2; exit 1; }
[[ -d "$developer_dir" ]] || { echo "Xcode developer directory is missing: $developer_dir" >&2; exit 1; }
[[ -f "$token_path" ]] || { echo "Image worker token is missing: $token_path" >&2; exit 1; }

export BONSAI_DEMO_ROOT="$demo_root"
export DEVELOPER_DIR="$developer_dir"
export WHEATLEY_IMAGE_API_TOKEN="$(tr -d '\r\n' < "$token_path")"

cd "$demo_root"
exec "$demo_root/.venv/bin/python" "$worker_root/worker.py"
