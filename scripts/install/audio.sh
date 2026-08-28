#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

platform_name() {
  local os
  local arch
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*|*_NT-*) os="windows" ;;
    *) echo "[tools] unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac

  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *) echo "[tools] unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  echo "$os-$arch"
}

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
    echo "[tools] verified $(basename "$target")"
    return
  fi
  echo "[tools] downloading $(basename "$target")"
  curl -fL --continue-at - --output "$target" "$url"
  local actual
  actual="$(sha256 "$target")"
  if [[ "$actual" != "$expected" ]]; then
    echo "[tools] checksum mismatch for $target" >&2
    echo "[tools] expected $expected" >&2
    echo "[tools] actual   $actual" >&2
    exit 1
  fi
}

extract_zip() {
  local archive="$1"
  local target="$2"
  rm -rf "$target"
  mkdir -p "$target"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$archive" -d "$target"
  elif command -v 7z.exe >/dev/null 2>&1; then
    local windows_archive
    local windows_target
    windows_archive="$(cygpath -w "$archive")"
    windows_target="$(cygpath -w "$target")"
    MSYS2_ARG_CONV_EXCL='*' 7z.exe x -y "-o$windows_target" "$windows_archive" >/dev/null
  else
    echo "[tools] unzip or 7z.exe is required to extract Windows audio tools" >&2
    exit 1
  fi
}

find_archive_file() {
  local root="$1"
  local name="$2"
  local path
  path="$(find "$root" -type f -iname "$name" -print -quit)"
  if [[ -z "$path" ]]; then
    echo "[tools] $name was not found in the downloaded archive" >&2
    exit 1
  fi
  echo "$path"
}

install_with_brew() {
  local formula="$1"
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  command -v brew >/dev/null 2>&1 || return 1
  brew install "$formula"
}

resolve_command() {
  local name="$1"
  local formula="$2"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return
  fi
  install_with_brew "$formula" >/dev/null || true
  command -v "$name"
}

link_tool() {
  local name="$1"
  local source_path="$2"
  mkdir -p "$tool_bin"
  ln -sfn "$source_path" "$tool_bin/$name"
  echo "[tools] $name -> $source_path"
}

setup_command() {
  local name="$1"
  local formula="$2"
  local source_path
  if ! source_path="$(resolve_command "$name" "$formula")"; then
    echo "[tools] missing $name; install $formula and rerun this script" >&2
    exit 1
  fi
  link_tool "$name" "$source_path"
}

setup_tts_environment() {
  local environment_root="$WHEATLEY_APP_DATA_ROOT/environments/tts"
  if [[ ! -x "$environment_root/bin/python" ]]; then
    python3 -m venv "$environment_root"
  fi
  "$environment_root/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "$repo_root/requirements-tts.txt"

  mkdir -p "$tool_bin"
  local wrapper="$tool_bin/piper"
  {
    echo '#!/usr/bin/env bash'
    printf 'exec %q -m piper "$@"\n' "$environment_root/bin/python"
  } >"$wrapper"
  chmod +x "$wrapper"
  echo "[tools] piper -> $environment_root/bin/python -m piper"
}

setup_windows_ffmpeg() {
  local archive="$download_root/ffmpeg-8.1.2-essentials_build.zip"
  local extracted="$extract_root/ffmpeg"
  download \
    "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip" \
    "$archive" \
    "db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec"
  extract_zip "$archive" "$extracted"
  mkdir -p "$tool_bin"
  local name
  for name in ffmpeg.exe ffplay.exe ffprobe.exe; do
    cp "$(find_archive_file "$extracted" "$name")" "$tool_bin/$name"
    echo "[tools] installed $name"
  done
}

setup_windows_whisper() {
  local archive="$download_root/whisper-bin-x64-v1.9.1.zip"
  local extracted="$extract_root/whisper"
  download \
    "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip" \
    "$archive" \
    "7d8be46ecd31828e1eb7a2ecdd0d6b314feafd82163038ab6092594b0a063539"
  extract_zip "$archive" "$extracted"
  mkdir -p "$tool_bin"
  local whisper_cli whisper_server
  whisper_cli="$(find_archive_file "$extracted" "whisper-cli.exe")"
  whisper_server="$(find_archive_file "$extracted" "whisper-server.exe")"
  cp "$whisper_cli" "$tool_bin/whisper-cli.exe"
  cp "$whisper_server" "$tool_bin/whisper-server.exe"
  local runtime_file
  for runtime_file in "$(dirname "$whisper_cli")"/*.dll; do
    [[ -f "$runtime_file" ]] || continue
    cp "$runtime_file" "$tool_bin/"
  done
  echo "[tools] installed whisper-cli.exe, whisper-server.exe, and their runtime libraries"
}

setup_windows_tts_environment() {
  local archive="$download_root/uv-x86_64-pc-windows-msvc-0.11.29.zip"
  local extracted="$extract_root/uv"
  local uv_root="$WHEATLEY_APP_DATA_ROOT/toolchains/uv"
  local uv="$uv_root/uv.exe"
  local environment_root="$WHEATLEY_APP_DATA_ROOT/environments/tts"
  local python="$environment_root/Scripts/python.exe"
  download \
    "https://github.com/astral-sh/uv/releases/download/0.11.29/uv-x86_64-pc-windows-msvc.zip" \
    "$archive" \
    "a047d55651bc3e0ca24595b25ec4cfcb10f9dca9fb56514e661269b37d4fae68"
  extract_zip "$archive" "$extracted"
  mkdir -p "$uv_root"
  cp "$(find_archive_file "$extracted" "uv.exe")" "$uv"

  export UV_CACHE_DIR="$(cygpath -w "$WHEATLEY_APP_DATA_ROOT/cache/uv")"
  export UV_PYTHON_INSTALL_DIR="$(cygpath -w "$WHEATLEY_APP_DATA_ROOT/toolchains/python")"
  export UV_PYTHON_NO_REGISTRY=1
  if [[ ! -x "$python" ]]; then
    "$uv" venv --managed-python --python 3.11 "$environment_root"
  fi
  "$uv" pip install \
    --python "$python" \
    --requirement "$repo_root/requirements-tts.txt"

  mkdir -p "$tool_bin"
  local python_windows
  python_windows="$(cygpath -w "$python")"
  {
    printf '@echo off\r\n'
    printf '"%s" -m piper %%*\r\n' "$python_windows"
  } >"$tool_bin/piper.cmd"
  echo "[tools] piper.cmd -> $python -m piper"
}

platform="$(platform_name)"
tool_bin="$WHEATLEY_APP_DATA_ROOT/tools/$platform/bin"

if [[ "$platform" == "windows-x86_64" ]]; then
  download_root="$WHEATLEY_APP_DATA_ROOT/downloads/windows-audio"
  extract_root="$WHEATLEY_APP_DATA_ROOT/cache/windows-audio-extract"
  setup_windows_ffmpeg
  setup_windows_whisper
  setup_windows_tts_environment
  rm -rf "$extract_root"
else
  setup_command ffmpeg ffmpeg
  setup_command ffplay ffmpeg
  setup_command whisper-cli whisper-cpp
  setup_command whisper-server whisper-cpp
  setup_tts_environment
  "$script_dir/audio-player.sh"
fi

echo "[tools] local audio tools are ready in $tool_bin"
