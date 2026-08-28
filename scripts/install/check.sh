#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

failures=0

check_command() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    echo "[ok] $name: $(command -v "$name")"
  else
    echo "[missing] $name"
    failures=$((failures + 1))
  fi
}

check_path() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    echo "[ok] $label: $path"
  else
    echo "[missing] $label: $path"
    failures=$((failures + 1))
  fi
}

platform_name() {
  local os
  local arch
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*|*_NT-*) os="windows" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *) return 1 ;;
  esac
  echo "$os-$arch"
}

echo "Wheatley doctor"
echo "  resources: $WHEATLEY_RESOURCES_ROOT"
echo "  app data:  $WHEATLEY_APP_DATA_ROOT"
echo "  config:    $WHEATLEY_CONFIG_PATH"
echo "  profiles:  $WHEATLEY_PROFILES_ROOT"
echo "  managed D fallback: ${WHEATLEY_D_COMPILER} (${WHEATLEY_DLANG_ROOT})"
if [[ -n "$WHEATLEY_CODEX_WORKSPACE_ROOT" ]]; then
  echo "  Codex workspace: $WHEATLEY_CODEX_WORKSPACE_ROOT"
  echo "  Codex socket:    $WHEATLEY_CODEX_SOCKET"
else
  echo "  Codex tasks: disabled"
fi

check_command node
check_command npm
check_command dub
check_command "${DC:-dmd}"
check_command pi
check_path "resources" "$WHEATLEY_RESOURCES_ROOT"
check_path "private config" "$WHEATLEY_CONFIG_PATH"
check_path "profiles" "$WHEATLEY_PROFILES_ROOT"
check_path "Pi extension dependencies" "$WHEATLEY_RESOURCES_ROOT/pi/node_modules/pi-web-access/index.ts"

platform="$(platform_name || true)"
tool_bin="$WHEATLEY_APP_DATA_ROOT/tools/$platform/bin"
if [[ -n "$platform" && -d "$tool_bin" ]]; then
  case "$platform" in
    windows-*)
      check_path "FFmpeg" "$tool_bin/ffmpeg.exe"
      check_path "FFplay" "$tool_bin/ffplay.exe"
      check_path "whisper.cpp" "$tool_bin/whisper-cli.exe"
      check_path "whisper.cpp server" "$tool_bin/whisper-server.exe"
      check_path "Piper" "$tool_bin/piper.cmd"
      check_path "TTS Python" "$WHEATLEY_APP_DATA_ROOT/environments/tts/Scripts/python.exe"
      ;;
    *)
      check_path "FFmpeg" "$tool_bin/ffmpeg"
      check_path "FFplay" "$tool_bin/ffplay"
      check_path "whisper.cpp" "$tool_bin/whisper-cli"
      check_path "whisper.cpp server" "$tool_bin/whisper-server"
      check_path "Piper" "$tool_bin/piper"
      check_path "audio player" "$tool_bin/wheatley-audio-player"
      check_path "TTS Python" "$WHEATLEY_APP_DATA_ROOT/environments/tts/bin/python"
      ;;
  esac
fi

if [[ -d "$WHEATLEY_APP_DATA_ROOT/models" ]]; then
  check_path "Whisper small model" "$WHEATLEY_APP_DATA_ROOT/models/whisper/ggml-small.bin"
  check_path "Whisper large-v3 model" "$WHEATLEY_APP_DATA_ROOT/models/whisper/ggml-large-v3.bin"
  check_path "Piper English model" "$WHEATLEY_APP_DATA_ROOT/models/piper/en_GB-alan-medium.onnx"
fi

if ((failures)); then
  echo "Wheatley doctor found $failures missing requirement(s)." >&2
  exit 1
fi
echo "Wheatley doctor passed."
