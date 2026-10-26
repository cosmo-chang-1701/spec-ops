# Shared helpers for the tests. Everything happens in a throwaway mktemp dir that is
# deleted on exit; the user's global/system git config is not read.
# shellcheck shell=bash
set -uo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/spec-ops" && pwd)
SCRIPTS=$SKILL_DIR/scripts
WORK=$(mktemp -d "${TMPDIR:-/tmp}/so-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$WORK/gitconfig
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
git config --global advice.detachedHead false
REAL_GIT=$(command -v git)

PASSED=0 FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
check_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
section() { printf '%s\n' "$1"; }
finish() {
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  ((FAILED == 0))
}

# make_repo <name>: upstream with two commits + a clone at $WORK/<name> (origin/HEAD set).
make_repo() {
  local up=$WORK/$1.up repo=$WORK/$1
  git init -q "$up"
  printf '.env\n.env.*\n.venv/\n' >"$up/.gitignore"
  echo one >"$up/a.txt"
  git -C "$up" add -A && git -C "$up" commit -qm one
  echo two >>"$up/a.txt"
  git -C "$up" commit -qam two
  git clone -q "$up" "$repo"
  printf '%s' "$repo"
}

# Hash of a checkout's status + staged diff + worktree diff.
state_of() {
  {
    git -C "$1" status --porcelain=v1 -z --untracked-files=all
    git -C "$1" diff --cached --binary
    git -C "$1" diff HEAD --binary
  } | sha256sum | cut -d' ' -f1
}

# Hash of a directory's file names (git objects excluded) + .git/config, to prove "untouched".
tree_of() {
  (cd "$1" && find . -path ./.git/objects -prune -o -print | LC_ALL=C sort
   [[ -f .git/config ]] && cat .git/config) | sha256sum | cut -d' ' -f1
}

json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval("d" + sys.argv[1]))' "$1"; }
