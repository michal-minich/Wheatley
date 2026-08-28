#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$script_dir/../env.sh"

if command -v dub >/dev/null 2>&1 && command -v "${DC:-dmd}" >/dev/null 2>&1; then
  echo "[d-toolchain] using dub: $(command -v dub)"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[d-toolchain] curl is required to download the official D installer" >&2
  exit 1
fi

case "$(uname -s)" in
  *_NT-*)
    if ! command -v 7z >/dev/null 2>&1 && ! command -v unzip >/dev/null 2>&1; then
      echo "[d-toolchain] Git Bash needs either unzip or 7-Zip to install DMD" >&2
      echo "[d-toolchain] install 7-Zip and make 7z.exe available on PATH" >&2
      exit 1
    fi
    ;;
esac

mkdir -p "$WHEATLEY_DLANG_ROOT"
installer_gnupg_home="$WHEATLEY_DLANG_ROOT/gnupg"
mkdir -p "$installer_gnupg_home"
chmod 700 "$installer_gnupg_home"

installer="$WHEATLEY_DLANG_ROOT/install.sh"
installer_download="$installer.download"

echo "[d-toolchain] downloading the official D installer"
curl -fsSL https://dlang.org/install.sh -o "$installer_download"
mv "$installer_download" "$installer"
chmod +x "$installer"

echo "[d-toolchain] installing $WHEATLEY_D_COMPILER under $WHEATLEY_DLANG_ROOT"
GNUPGHOME="$installer_gnupg_home" \
  bash "$installer" --path "$WHEATLEY_DLANG_ROOT" install "$WHEATLEY_D_COMPILER"

compiler_root="$WHEATLEY_DLANG_ROOT/$WHEATLEY_D_COMPILER"
case "$(uname -s)" in
  *_NT-*)
    nested_compiler_root="$compiler_root/dmd2"
    if [[ ! -f "$compiler_root/windows/bin/dmd.exe" &&
          -f "$nested_compiler_root/windows/bin/dmd.exe" ]]; then
      echo "[d-toolchain] normalizing the Windows DMD archive layout"
      mv "$nested_compiler_root"/* "$compiler_root/"
      rmdir "$nested_compiler_root"
    fi
    ;;
esac

activation="$compiler_root/activate"
if [[ ! -f "$activation" ]]; then
  echo "[d-toolchain] installer did not create the expected activation file: $activation" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$activation"
echo "[d-toolchain] ready: $(dub --version)"
