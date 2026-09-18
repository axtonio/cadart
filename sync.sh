#!/usr/bin/env bash
# Aggregator node: Google repo (default.xml), then nested aggregators.
#
#   ./sync.sh    pull + repo sync + nested aggregators
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
NAME="$(basename "$ROOT")"
PATH="${HOME}/.local/bin:${PATH}"

ensure_repo() {
  if command -v repo >/dev/null 2>&1; then
    return 0
  fi
  echo "==> installing Google repo into ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > "${HOME}/.local/bin/repo"
  chmod a+rx "${HOME}/.local/bin/repo"
  command -v repo >/dev/null 2>&1 || {
    echo "repo is not on PATH after install" >&2
    exit 1
  }
}

manifest_paths() {
  python3 - <<'PY'
import xml.etree.ElementTree as ET
from pathlib import Path
p = Path("default.xml")
if not p.exists():
    raise SystemExit(0)
root = ET.parse(p).getroot()
for el in root.findall("project"):
    path = el.get("path") or el.get("name")
    if path:
        print(path)
PY
}

ancestor_repo_client() {
  local d="$ROOT"
  while [[ "$d" != "/" ]]; do
    d="$(dirname "$d")"
    if [[ -f "$d/.repo/repo/main.py" ]]; then
      return 0
    fi
  done
  return 1
}

manifest_remote() {
  local url
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    url="$(git config --get remote.github.url 2>/dev/null || true)"
  fi
  url="$(printf '%s' "$url" | sed -E 's#https://[^/@]+@#https://#')"
  if [[ -n "$url" ]]; then
    printf '%s\n' "$url"
  else
    printf '%s\n' "$ROOT"
  fi
}

init_repo_client() {
  # Nested aggregators sit under a parent .repo; init in a tempdir so `repo`
  # does not walk up and rewrite the umbrella client.
  if [[ -f .repo/manifest.xml ]]; then
    return 0
  fi
  local u
  u="$(manifest_remote)"
  if ancestor_repo_client; then
    local tmp
    tmp="$(mktemp -d)"
    (cd "$tmp" && repo init -u "$u" -m default.xml -c \
      --repo-url=https://github.com/GerritCodeReview/git-repo)
    rm -rf "$ROOT/.repo"
    mv "$tmp/.repo" "$ROOT/.repo"
    rm -rf "$tmp"
  else
    repo init -u "$u" -m default.xml -c \
      --repo-url=https://github.com/GerritCodeReview/git-repo
  fi
}

echo "==> $NAME"
if git remote get-url origin >/dev/null 2>&1; then
  if git symbolic-ref -q HEAD >/dev/null; then
    git pull --ff-only
  else
    echo "detached HEAD; fetching origin default branch"
    git fetch origin --quiet || true
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
      git checkout -q -B main origin/main
    elif git rev-parse --verify origin/master >/dev/null 2>&1; then
      git checkout -q -B master origin/master
    fi
    git pull --ff-only || true
  fi
else
  echo "no origin (repo-managed checkout); skip git pull"
fi

if [[ -f default.xml ]]; then
  ensure_repo
  echo "==> repo sync ($NAME)"
  init_repo_client
  repo sync -c -j8 --no-tags --fail-fast || repo sync -c -j8 --no-tags
fi

if [[ -f default.xml ]]; then
  while IFS= read -r path; do
    [[ -f "$path/default.xml" && -x "$path/sync.sh" ]] || continue
    echo "==> nested $path/sync.sh"
    (cd "$path" && ./sync.sh)
  done < <(manifest_paths)
fi

echo
echo "==> status"
git status -sb
