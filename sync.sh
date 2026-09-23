#!/usr/bin/env bash
# Synchronize existing checkouts without rebasing or resetting local work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
PATH="${HOME}/.local/bin:${PATH}"
LOCAL_ONLY=false
case "${1:-}" in
  "") ;;
  --local) LOCAL_ONLY=true ;;
  *) echo "Usage: $0 [--local]" >&2; exit 2 ;;
esac

echo "==> $(basename "$ROOT")"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Local changes present; skipping this node and its children."
  exit 0
fi
if git symbolic-ref -q HEAD >/dev/null; then
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    if ! $LOCAL_ONLY; then
      branch="$(git symbolic-ref --short HEAD)"
      remote="$(git config --get "branch.${branch}.remote")"
      git fetch --no-tags "$remote"
    fi
    git merge --ff-only "$upstream"
  else
    echo "No upstream configured; keeping the current branch."
  fi
else
  echo "Detached HEAD; keeping the current commit."
fi

[[ -f default.xml ]] || exit 0
if ! command -v repo >/dev/null 2>&1; then
  if $LOCAL_ONLY; then
    echo "Google repo is required; run without --local to install it." >&2
    exit 1
  fi
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "${HOME}/.local/bin/repo"
  chmod a+rx "${HOME}/.local/bin/repo"
fi
if [[ ! -f .repo/manifest.xml ]]; then
  if $LOCAL_ONLY; then
    echo "No local repo client; run online once to initialize it." >&2
    exit 1
  fi
  temporary_client="$(mktemp -d)"
  (cd "$temporary_client" && repo init -u "$ROOT" -m default.xml -c --no-clone-bundle \
    --repo-url=https://github.com/GerritCodeReview/git-repo)
  mkdir -p .repo
  for name in repo manifests manifests.git manifest.xml; do
    if [[ -e ".repo/$name" || -L ".repo/$name" ]]; then
      echo "Existing .repo/$name needs inspection; nothing overwritten. Temp client: $temporary_client" >&2
      exit 1
    fi
  done
  for name in repo manifests manifests.git manifest.xml; do
    [[ ! -e "$temporary_client/.repo/$name" && ! -L "$temporary_client/.repo/$name" ]] || mv "$temporary_client/.repo/$name" ".repo/$name"
  done
fi
# This remote is the local aggregator checkout, so this works offline as well.
manifest_source="$(git -C .repo/manifests config --get remote.origin.url)"
if [[ "$manifest_source" != "$ROOT" ]]; then
  echo "Manifest source must be this local checkout: $ROOT (run repo init -u here)." >&2
  exit 1
fi
git -C .repo/manifests fetch --quiet origin
git -C .repo/manifests merge --ff-only --quiet '@{u}'
if ! $LOCAL_ONLY; then
  # Fetch only: repo's default local sync may rebase or discard unpublished commits.
  repo sync --network-only --no-manifest-update -c -j8 --no-tags --fail-fast
fi
paths="$(repo list --path-only)"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ ! -e "$path/.git" ]] || ! git -C "$path" rev-parse --verify HEAD >/dev/null 2>&1; then
    # Only initial checkouts use repo's local checkout machinery.
    repo sync --local-only --no-manifest-update --fail-fast "$path"
  fi
done <<< "$paths"
repo forall -c '
  if test -n "$(git status --porcelain)"; then
    echo "$REPO_PATH: local changes; skipped"
    exit 0
  fi
  target="$REPO_REMOTE/$REPO_RREV"
  git rev-parse --verify "$target^{commit}" >/dev/null || exit 1
  if git symbolic-ref -q HEAD >/dev/null; then
    git merge --ff-only "$target" || exit 1
  elif test "$(git rev-parse HEAD)" = "$(git rev-parse "$target")"; then
    if git show-ref --verify --quiet "refs/heads/$REPO_RREV"; then
      echo "$REPO_PATH: existing branch retained; HEAD stays detached"
    else
      git switch -c "$REPO_RREV" --track "$target" || exit 1
    fi
  else
    echo "$REPO_PATH: detached local commit; skipped"
  fi
'
while IFS= read -r path; do
  [[ -f "$path/default.xml" && -x "$path/sync.sh" ]] || continue
  (cd "$path" && ./sync.sh "$@")
done <<< "$paths"
git status -sb
