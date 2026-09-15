#!/usr/bin/env bash
# Sync a node: Google repo (default.xml) plus leftover git submodules (Sber).
#
# Usage:
#   ./sync.sh           pull this repo, repo sync (tracks main), checkout Sber pins
#   ./sync.sh --latest  also fast-forward leftover submodules (cadpac etc.)
#   ./sync.sh --push    CI: pin leftover submodules; nested ./sync.sh --push
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
NAME="$(basename "$ROOT")"
GITHUB_ORG="${GITHUB_ORG:-}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.ai.cloud.ru}"
GITHUB_PAT="${SUBMODULES_GITHUB_PAT:-${SUBMODULES_GITHUB_AXTONIO_PAT:-${GH_TOKEN:-}}}"
PATH="${HOME}/.local/bin:${PATH}"

LATEST=0
PUSH=0
for arg in "$@"; do
  case "$arg" in
    --latest) LATEST=1 ;;
    --push) PUSH=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$GITHUB_ORG" ]]; then
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" == *github.com* ]]; then
    GITHUB_ORG="$(printf '%s' "$origin" | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#')"
  fi
fi

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

remote_head() {
  local url="$1" branch="${2:-}" sha
  if [[ -n "$branch" ]]; then
    sha="$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | awk '{print $1; exit}')"
    printf '%s' "$sha"
    return 0
  fi
  sha="$(git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1; exit}')"
  if [[ -z "$sha" ]]; then
    sha="$(git ls-remote "$url" refs/heads/main refs/heads/master 2>/dev/null | awk '{print $1; exit}')"
  fi
  printf '%s' "$sha"
}

github_repo_slug() {
  printf '%s' "$1" | sed -E 's#^https://github.com/##; s#\.git$##; s#/$##'
}

github_has_gitmodules() {
  local slug code
  slug="$(github_repo_slug "$1")"
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${slug}/contents/.gitmodules")"
  [[ "$code" == "200" ]]
}

can_push() {
  local origin="$1"
  [[ "$origin" == *github.com* || "$origin" == *gitlab* ]]
}

pin_sha() {
  local repo="$1" path="$2" sha="$3"
  echo "pin $path -> ${sha:0:8}"
  git -C "$repo" update-index --add --cacheinfo "160000,$sha,$path"
}

ensure_clone() {
  local url="$1" dir="$2" branch="${3:-}"
  mkdir -p "$(dirname "$dir")"
  if [[ -e "$dir/.git" ]]; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      git -C "$dir" fetch --prune --depth 1 origin --quiet
      git -C "$dir" remote set-head origin -a >/dev/null 2>&1 || true
      if [[ -n "$branch" ]] && git -C "$dir" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        git -C "$dir" checkout -q -B "$branch" "origin/$branch"
      elif git -C "$dir" rev-parse --abbrev-ref origin/HEAD >/dev/null 2>&1; then
        git -C "$dir" checkout -q -B "$(git -C "$dir" rev-parse --abbrev-ref origin/HEAD | sed 's#^origin/##')" origin/HEAD
      fi
    else
      git -C "$dir" fetch --prune origin --quiet
    fi
    return 0
  fi
  if [[ -n "$branch" ]]; then
    git clone --depth 1 --no-tags --single-branch --branch "$branch" "$url" "$dir"
  else
    git clone --depth 1 --no-tags --single-branch "$url" "$dir"
  fi
}

run_nested_sync() {
  local dir="$1"
  if [[ -x "$dir/sync.sh" ]]; then
    echo "==> nested $dir/sync.sh --push"
    (cd "$dir" && ./sync.sh --push)
    return 0
  fi
  return 1
}

push_repo() {
  local repo="$1"
  local branch origin
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  origin="$(git -C "$repo" remote get-url origin)"
  local i
  for i in 1 2 3; do
    if git -C "$repo" push origin HEAD; then
      echo "pushed $origin @ $(git -C "$repo" rev-parse --short HEAD)"
      return 0
    fi
    echo "push rejected, rebase retry $i"
    git -C "$repo" fetch origin
    git -C "$repo" pull --rebase origin "$branch"
  done
  git -C "$repo" push origin HEAD
  echo "pushed $origin @ $(git -C "$repo" rev-parse --short HEAD)"
}

bump_tree() {
  local repo="$1"
  local origin path url branch sha parent_origin child
  if [[ ! -f "$repo/.gitmodules" ]]; then
    return 0
  fi
  parent_origin="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"

  while IFS=$'\t' read -r path url branch; do
    [[ -z "$path" || -z "$url" ]] && continue
    child="$repo/$path"

    if [[ "$url" != *github.com* && "$parent_origin" == *github.com* ]]; then
      echo "gitlab $path"
      ensure_clone "$url" "$child" "$branch"
      if run_nested_sync "$child"; then
        git -C "$repo" add -- "$path"
        continue
      fi
      sha="$(git -C "$child" rev-parse HEAD 2>/dev/null || remote_head "$url" "$branch")"
      if [[ -z "$sha" ]]; then
        echo "skip $path (no SHA)"
        continue
      fi
      pin_sha "$repo" "$path" "$sha"
      continue
    fi

    if [[ -x "$child/sync.sh" ]]; then
      run_nested_sync "$child"
      git -C "$repo" add -- "$path"
      continue
    fi

    if [[ "$url" == *github.com* ]] && { [[ -e "$child/.git" ]] || github_has_gitmodules "$url"; }; then
      echo "github $path"
      ensure_clone "$url" "$child" "$branch"
      bump_tree "$child"
      run_nested_sync "$child" || true
      git -C "$repo" add -- "$path"
    else
      sha="$(remote_head "$url" "$branch")"
      if [[ -z "$sha" ]]; then
        echo "skip $path (ls-remote failed for $url)"
        continue
      fi
      pin_sha "$repo" "$path" "$sha"
    fi
  done < <(
    git -C "$repo" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
      | while read -r key path; do
          name="${key#submodule.}"
          name="${name%.path}"
          url="$(git -C "$repo" config -f .gitmodules --get "submodule.$name.url")"
          branch="$(git -C "$repo" config -f .gitmodules --get "submodule.$name.branch" || true)"
          printf '%s\t%s\t%s\n' "$path" "$url" "$branch"
        done
  )

  origin="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if ! can_push "$origin"; then
    echo "skip commit $repo (not GitHub/GitLab)"
    return 0
  fi
  if git -C "$repo" diff --cached --quiet; then
    return 0
  fi
  git -C "$repo" commit -m "Bump nested submodule pins."
  push_repo "$repo"
}

sync_repo_manifest() {
  local origin
  [[ -f default.xml ]] || return 0
  ensure_repo
  origin="$(git remote get-url origin)"
  echo "==> repo sync ($NAME)"
  if [[ ! -d .repo ]]; then
    repo init -u "$origin" -m default.xml
  fi
  repo sync -c -j8 --no-tags --fail-fast || repo sync -c -j8 --no-tags
}

echo "==> $NAME"
if git symbolic-ref -q HEAD >/dev/null; then
  git pull --ff-only
else
  echo "detached HEAD; fetching and checking out origin default branch"
  git fetch origin --quiet || true
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    git checkout -q -B main origin/main
  elif git rev-parse --verify origin/master >/dev/null 2>&1; then
    git checkout -q -B master origin/master
  fi
  git pull --ff-only || true
fi

if [[ "$PUSH" -eq 1 ]]; then
  echo "==> bump leftover submodule pins; repo sync children first"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    git config --global user.name "github-actions[bot]"
    git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
  sync_repo_manifest
  bump_tree "$ROOT"
  if [[ -f default.xml ]]; then
    while IFS= read -r path; do
      [[ -x "$path/sync.sh" && -f "$path/.gitmodules" ]] || continue
      echo "==> nested $path/sync.sh --push"
      (cd "$path" && ./sync.sh --push)
    done < <(manifest_paths)
  fi
  echo
  echo "==> status"
  git status -sb
  exit 0
fi

sync_repo_manifest

if [[ -f .gitmodules ]]; then
  echo "==> sync leftover submodules"
  git submodule sync --recursive
  if ! git submodule update --init --recursive; then
    echo "WARN: some submodules failed to init; continuing"
  fi
fi

if [[ "$LATEST" -eq 1 && -f .gitmodules ]]; then
  echo "==> fast-forward leftover submodules (nested ./sync.sh --latest if present)"
  git submodule foreach --quiet '
    if [ -x ./sync.sh ]; then
      ./sync.sh --latest
      exit 0
    fi
    git fetch origin --quiet 2>/dev/null || { echo "skip $displaypath (fetch failed)"; exit 0; }
    branch=""
    if git rev-parse --abbrev-ref origin/HEAD >/dev/null 2>&1; then
      branch=$(git rev-parse --abbrev-ref origin/HEAD)
      branch=${branch#origin/}
    elif git rev-parse --verify origin/main >/dev/null 2>&1; then
      branch=main
    elif git rev-parse --verify origin/master >/dev/null 2>&1; then
      branch=master
    fi
    if [ -n "$branch" ]; then
      git checkout -q -B "$branch" "origin/$branch"
      echo "updated $displaypath -> $(git rev-parse --short HEAD) ($branch)"
    else
      echo "skip $displaypath (no origin/main or origin/master)"
    fi
  '
  echo
  echo "Working tree may be dirty: parents still pin old SHAs for leftover submodules."
fi

echo
echo "==> status"
git status -sb
