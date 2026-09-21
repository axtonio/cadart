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

init_repo_client() {
  # Tempdir so `repo` does not walk into a parent client. Never `rm -rf .repo`.
  [[ -f .repo/manifest.xml ]] && return 0
  local tmp name
  tmp="$(mktemp -d)"
  # --no-clone-bundle: repo's urllib clone.bundle applies git insteadOf and
  # cannot parse https://user:token@host (InvalidURL nonnumeric port).
  (cd "$tmp" && repo init -u "$ROOT" -m default.xml -c --no-clone-bundle \
    --repo-url=https://github.com/GerritCodeReview/git-repo)
  mkdir -p .repo
  for name in repo manifests manifests.git manifest.xml; do
    rm -rf ".repo/$name"
    [[ -e "$tmp/.repo/$name" ]] && mv "$tmp/.repo/$name" ".repo/$name"
  done
  rm -rf "$tmp"
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
  repo forall -c '
    git symbolic-ref -q HEAD >/dev/null && exit 0
    git rev-parse --verify -q "$REPO_REMOTE/$REPO_RREV" >/dev/null || exit 0
    git checkout -q -B "$REPO_RREV" "$REPO_REMOTE/$REPO_RREV"
  '
  while IFS= read -r path; do
    [[ -f "$path/default.xml" && -x "$path/sync.sh" ]] || continue
    echo "==> nested $path/sync.sh"
    (cd "$path" && ./sync.sh)
  done < <(repo list --path-only)
fi

echo
echo "==> status"
git status -sb
