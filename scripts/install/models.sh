#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

mode="${1:-english}"
case "$mode" in
  english|slovak|german|all) ;;
  *)
    echo "Usage: scripts/install/models.sh [english|slovak|german|all]" >&2
    exit 2
    ;;
esac

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

download() {
  local url="$1"
  local target="$2"
  local expected="$3"
  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" && "$(sha256 "$target")" == "$expected" ]]; then
    echo "[models] verified $(basename "$target")"
    return
  fi
  echo "[models] downloading $(basename "$target")"
  curl -fL --continue-at - --output "$target" "$url"
  local actual
  actual="$(sha256 "$target")"
  if [[ "$actual" != "$expected" ]]; then
    echo "[models] checksum mismatch for $target" >&2
    echo "[models] expected $expected" >&2
    echo "[models] actual   $actual" >&2
    exit 1
  fi
}

download \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin" \
  "$WHEATLEY_APP_DATA_ROOT/models/whisper/ggml-small.bin" \
  "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
download \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin" \
  "$WHEATLEY_APP_DATA_ROOT/models/whisper/ggml-large-v3.bin" \
  "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|*_NT-*)
    tts_python="$WHEATLEY_APP_DATA_ROOT/environments/tts/Scripts/python.exe"
    ;;
  *)
    tts_python="$WHEATLEY_APP_DATA_ROOT/environments/tts/bin/python"
    ;;
esac
if [[ ! -x "$tts_python" ]]; then
  echo "[models] run scripts/install/audio.sh first" >&2
  exit 1
fi

if [[ "$mode" == "english" || "$mode" == "all" ]]; then
  "$tts_python" -m piper.download_voices \
    --data-dir "$WHEATLEY_APP_DATA_ROOT/models/piper" \
    en_GB-alan-medium
  [[ "$(sha256 "$WHEATLEY_APP_DATA_ROOT/models/piper/en_GB-alan-medium.onnx")" == \
    "0a309668932205e762801f1efc2736cd4b0120329622adf62be09e56339d3330" ]]
  [[ "$(sha256 "$WHEATLEY_APP_DATA_ROOT/models/piper/en_GB-alan-medium.onnx.json")" == \
    "c0f0d124e5895c00e7c03b35dcc8287f319a6998a365b182deb5c8e752ee8c1e" ]]
fi

if [[ "$mode" == "slovak" || "$mode" == "german" || "$mode" == "all" ]]; then
  "$tts_python" -c "from supertonic import TTS; TTS()"
fi

echo "[models] requested model set is ready"
