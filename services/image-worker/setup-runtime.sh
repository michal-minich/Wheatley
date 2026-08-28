#!/usr/bin/env bash
set -euo pipefail

worker_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$worker_root/../.." && pwd)"
runtime_root="$repo_root/app-data/image-generation"
demo_root="$runtime_root/bonsai-image-demo"
developer_dir="${DEVELOPER_DIR:-$repo_root/app-data/toolchains/Xcode.app/Contents/Developer}"
upstream="https://github.com/PrismML-Eng/Bonsai-image-demo.git"
revision="9cf9d6e"
log_root="$runtime_root/logs"
log_path="$log_root/setup.log"

mkdir -p "$runtime_root" "$log_root"
exec > >(tee -a "$log_path") 2>&1
echo "[image-worker-setup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') starting"

if [[ ! -d "$demo_root/.git" ]]; then
  git clone "$upstream" "$demo_root"
fi
if ! git -C "$demo_root" cat-file -e "$revision^{commit}" 2>/dev/null; then
  git -C "$demo_root" fetch origin "$revision"
fi
git -C "$demo_root" checkout --detach "$revision"

[[ -d "$developer_dir" ]] || { echo "Xcode developer directory is missing: $developer_dir" >&2; exit 1; }
export DEVELOPER_DIR="$developer_dir"

"$demo_root/setup.sh"
"$demo_root/scripts/download_model.sh" --model ternary-mlx

model_root="$demo_root/models/bonsai-image-4B-ternary-mlx"
[[ -d "$model_root" ]] || { echo "Model download did not create $model_root" >&2; exit 1; }
[[ -x "$demo_root/.venv/bin/python" ]] || { echo "Bonsai Python environment is incomplete" >&2; exit 1; }

echo "[image-worker-setup] runtime ready at revision $(git -C "$demo_root" rev-parse --short HEAD)"
