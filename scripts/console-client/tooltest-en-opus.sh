#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/run.sh" "$script_dir/../../run-profiles/tooltest-en-opus.json" "$@"
