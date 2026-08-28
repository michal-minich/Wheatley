#!/usr/bin/env bash

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$repo_root/wheatley.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$repo_root/wheatley.local.env"
fi

export WHEATLEY_APP_DATA_ROOT="${WHEATLEY_APP_DATA_ROOT:-$repo_root/app-data}"
export WHEATLEY_RESOURCES_ROOT="$WHEATLEY_APP_DATA_ROOT/resources"
export WHEATLEY_HOME="${WHEATLEY_HOME:-$WHEATLEY_APP_DATA_ROOT/user}"
export WHEATLEY_CONFIG_PATH="${WHEATLEY_CONFIG_PATH:-$WHEATLEY_HOME/config.json}"
export WHEATLEY_PROFILES_ROOT="${WHEATLEY_PROFILES_ROOT:-$WHEATLEY_HOME/Profiles}"
export WHEATLEY_IMAGE_TOKEN_PATH="${WHEATLEY_IMAGE_TOKEN_PATH:-$WHEATLEY_HOME/image-generation-token}"
if [[ -z "${WHEATLEY_IMAGE_API_TOKEN:-}" && -f "$WHEATLEY_IMAGE_TOKEN_PATH" ]]; then
  export WHEATLEY_IMAGE_API_TOKEN="$(tr -d '\r\n' < "$WHEATLEY_IMAGE_TOKEN_PATH")"
fi
export WHEATLEY_CODEX_WORKSPACE_ROOT="${WHEATLEY_CODEX_WORKSPACE_ROOT:-}"
export WHEATLEY_CODEX_SOCKET="${WHEATLEY_CODEX_SOCKET:-$WHEATLEY_APP_DATA_ROOT/wheatley-codexd.sock}"
export WHEATLEY_CONVERSATION_REMOTE_API_BASE="${WHEATLEY_CONVERSATION_REMOTE_API_BASE:-}"
export WHEATLEY_SYNC_UPSTREAM_API_BASE="${WHEATLEY_SYNC_UPSTREAM_API_BASE:-}"

case "$(uname -s)" in
  *_NT-*) default_d_compiler="dmd-2.112.0" ;;
  *) default_d_compiler="ldc-1.42.0" ;;
esac

export WHEATLEY_DLANG_ROOT="${WHEATLEY_DLANG_ROOT:-$WHEATLEY_APP_DATA_ROOT/toolchains/dlang}"
export WHEATLEY_D_COMPILER="${WHEATLEY_D_COMPILER:-$default_d_compiler}"

case "$WHEATLEY_D_COMPILER" in
  ldc-*) default_d_command="ldc2" ;;
  *) default_d_command="dmd" ;;
esac
export DC="${DC:-$default_d_command}"

managed_d_activation="$WHEATLEY_DLANG_ROOT/$WHEATLEY_D_COMPILER/activate"
if { ! command -v dub >/dev/null 2>&1 || ! command -v "$DC" >/dev/null 2>&1; } &&
   [[ -f "$managed_d_activation" ]]; then
  # shellcheck source=/dev/null
  source "$managed_d_activation"
fi

managed_dub="$(command -v dub 2>/dev/null || true)"
managed_windows_bin="$WHEATLEY_DLANG_ROOT/$WHEATLEY_D_COMPILER/windows/bin"
case "$(uname -s)" in
  *_NT-*)
    if [[ "$managed_dub" == "$WHEATLEY_DLANG_ROOT/"* &&
          -f "$managed_windows_bin/dub.exe" ]]; then
      export PATH="$managed_windows_bin:$PATH"
    fi
    ;;
esac
