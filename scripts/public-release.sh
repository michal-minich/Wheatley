#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

push=false
replace_history=false
message="Public snapshot $(date +%Y-%m)"

usage() {
  echo "Usage: scripts/public-release.sh [--push] [--replace-history] [--message TEXT]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      push=true
      shift
      ;;
    --replace-history)
      replace_history=true
      shift
      ;;
    --message)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      message="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -z "$(git status --porcelain)" ]] || {
  echo "Public release requires a clean working tree." >&2
  exit 1
}

git remote get-url private >/dev/null
git remote get-url public >/dev/null
git fetch --quiet --no-tags private main
git fetch --quiet --no-tags public main

source_commit="$(git rev-parse private/main^{commit})"
head_commit="$(git rev-parse HEAD^{commit})"
[[ "$head_commit" == "$source_commit" ]] || {
  echo "HEAD must exactly match private/main before publishing." >&2
  echo "HEAD:         $head_commit" >&2
  echo "private/main: $source_commit" >&2
  exit 1
}

public_tip="$(git rev-parse public/main^{commit})"
source_tree="$(git rev-parse "$source_commit^{tree}")"

if [[ "$replace_history" == false ]]; then
  if git merge-base --is-ancestor "$source_commit" "$public_tip"; then
    echo "Refusing to publish: public history already contains private history." >&2
    exit 1
  fi
  if [[ "$(git rev-parse "$public_tip^{tree}")" == "$source_tree" ]]; then
    echo "The public repository already contains this exact tree." >&2
    exit 1
  fi
fi

git diff --check

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find scripts -name '*.sh' -type f -print0)

node - <<'NODE'
const fs = require("fs");
const path = require("path");
const roots = ["app-data/resources", "run-profiles", "examples"];
const files = [];
function collect(root) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.name === "node_modules") continue;
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) collect(target);
    else if (entry.name.endsWith(".json")) files.push(target);
  }
}
for (const root of roots) collect(root);
for (const file of files) JSON.parse(fs.readFileSync(file, "utf8"));
console.log(`[public-release] parsed ${files.length} JSON files`);
NODE

if git grep -n -I -E \
  '(/Users/|Jankas-Mac-mini|janka-mac|WHEATLEY_ATOM_|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
  "$source_commit" -- . ':!scripts/public-release.sh'; then
  echo "Public release blocked by a private-path or credential-shaped value." >&2
  exit 1
fi

npm --prefix client run check
(
  cd server/wheatleyd
  dub test
  dub build --config=console
)

if [[ "$replace_history" == true ]]; then
  snapshot_commit="$(git commit-tree "$source_tree" -m "$message")"
else
  snapshot_commit="$(git commit-tree "$source_tree" -p "$public_tip" -m "$message")"
fi
git branch -f public-snapshot "$snapshot_commit" >/dev/null

echo "[public-release] source:   $source_commit"
echo "[public-release] snapshot: $snapshot_commit"
git diff --stat "$public_tip" "$snapshot_commit"

if [[ "$push" == false ]]; then
  echo "[public-release] dry run complete; add --push after reviewing branch 'public-snapshot'."
  exit 0
fi

if [[ "$replace_history" == true ]]; then
  git push public refs/heads/public-snapshot:refs/heads/main \
    --force-with-lease="refs/heads/main:$public_tip"
else
  git push public refs/heads/public-snapshot:refs/heads/main
fi

echo "[public-release] public/main updated."
