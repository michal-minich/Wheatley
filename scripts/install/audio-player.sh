#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"
app_data_root="$WHEATLEY_APP_DATA_ROOT"
source_file="$repo_root/server/wheatleyd/native/audio_player.c"
miniaudio_file="$repo_root/server/wheatleyd/vendor/miniaudio/miniaudio.c"
miniaudio_header="$repo_root/server/wheatleyd/vendor/miniaudio/miniaudio.h"

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  *) echo "[audio-player] unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64) arch="x86_64" ;;
  *) echo "[audio-player] unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if ! command -v cc >/dev/null 2>&1; then
  echo "[audio-player] a C compiler is required to build the local playback helper" >&2
  exit 1
fi

target_dir="$app_data_root/tools/$os-$arch/bin"
target="$target_dir/wheatley-audio-player"
mkdir -p "$target_dir"

if [[
  -x "$target"
  && "$target" -nt "$source_file"
  && "$target" -nt "$miniaudio_file"
  && "$target" -nt "$miniaudio_header"
]]; then
  exit 0
fi

common_flags=(
  -std=c11
  -O2
  -DNDEBUG
  -Wall
  -Wextra
  -Werror
  -DMA_NO_FLAC
  -DMA_NO_RESOURCE_MANAGER
  -DMA_NO_NODE_GRAPH
  -DMA_NO_ENGINE
  -DMA_NO_GENERATION
)

temporary="$target.tmp.$$"
trap 'rm -f "$temporary"' EXIT

if [[ "$os" == "macos" ]]; then
  cc "${common_flags[@]}" \
    "$source_file" "$miniaudio_file" \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AudioUnit \
    -framework CoreFoundation \
    -o "$temporary"
else
  cc "${common_flags[@]}" \
    "$source_file" "$miniaudio_file" \
    -ldl -lpthread -lm \
    -o "$temporary"
fi

mv "$temporary" "$target"
trap - EXIT
echo "[audio-player] built $target"
