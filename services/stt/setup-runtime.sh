#!/usr/bin/env bash
set -euo pipefail

service_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_root="$service_root/runtime"
source_root="$runtime_root/whisper.cpp-1.8.6"
build_root="$runtime_root/build"
binary="$runtime_root/bin/whisper-server"
archive="$runtime_root/whisper.cpp-v1.8.6.tar.gz"
archive_sha="f8e632016ceae556f3132a16c7f704be1e7715595041f474fa81a2b64c1abf7c"
cmake="$runtime_root/cmake/bin/cmake"
export PYTHONPATH="$runtime_root/cmake${PYTHONPATH:+:$PYTHONPATH}"

if [[ -x "$binary" ]]; then
  echo "[stt] whisper-server runtime already exists"
  exit 0
fi

mkdir -p "$runtime_root/bin" "$runtime_root/cmake"
if [[ ! -x "$cmake" ]]; then
  python3 -m pip install \
    --disable-pip-version-check \
    --no-warn-script-location \
    --target "$runtime_root/cmake" \
    "cmake==4.3.1"
fi

if [[ ! -f "$archive" || "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$archive_sha" ]]; then
  curl -fL \
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.6.tar.gz" \
    --output "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$archive_sha" ]]

if [[ ! -f "$source_root/CMakeLists.txt" ]]; then
  tar -xzf "$archive" -C "$runtime_root"
fi

"$cmake" \
  -S "$source_root" \
  -B "$build_root" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=Apple
"$cmake" --build "$build_root" --config Release --target whisper-server -j 8
cp "$build_root/bin/whisper-server" "$binary"
chmod 755 "$binary"

echo "[stt] built $binary"
