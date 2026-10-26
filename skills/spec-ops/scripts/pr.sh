#!/usr/bin/env bash
# Open and merge the PR of an approved task (needs `gh`; the Lead calls it per task).
#
# Usage:
#   pr.sh preflight [--into <branch>]
#       Can PRs be opened at all? gh installed and logged in, `origin` set, target fetched.
#   pr.sh open <worktree> --title <title> --body-file <file> [--into <branch>] [--base <ref>]
#       Push the worktree's branch and open a PR into <branch>. Reuses an open PR for the
#       same branch, so re-running after an interruption is safe. The worktree must be clean
#       and hold at least one commit since its base; the base (default: the fork point
#       recorded by `worktree.sh create`/`integrate`, or --base) must already be on
#       origin/<branch> — otherwise the PR would carry commits nobody pushed.
#   pr.sh merge <pr-url|number> --method squash|merge|rebase [--timeout <seconds>]
#       Wait for the PR's checks, merge it, then delete the remote head branch. Never uses
#       --admin and never bypasses branch protection. A PR without any checks is merged
#       after one retry.
#
# <branch> defaults to origin's default branch (refs/remotes/origin/HEAD, else asked from origin).
# stdout is one JSON line; gh/git chatter goes to stderr. Exit: 0 = done, 1 = not done (the
# JSON says why: "ok":false / "state":"checks-failed"|"checks-timeout"|"merge-refused"),
# 2 = usage error.
# Env: SO_PR_TIMEOUT (seconds to wait for checks, default 1800), SO_PR_CHECKS_DELAY
# (seconds before re-asking a PR that reports no checks yet, default 20).
set -euo pipefail

die() { printf 'pr: %s\n' "$*" >&2; exit 2; }
warn() { printf 'pr: %s\n' "$*" >&2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# not_done <json-key> <value> <reason> [<extra json fields>]: print the JSON line, exit 1.
not_done() {
  printf '{"%s":%s,"reason":"%s"%s}\n' "$1" "$2" "$(json_escape "$3")" "${4:-}"
  exit 1
}

# default_into [<dir>]: prints the branch PRs go into, origin's default branch: the local
# refs/remotes/origin/HEAD, else what the remote itself reports for HEAD (many clones lack
# the former).
default_into() {
  local dir=${1:-.} ref
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -z $ref ]]; then
    ref=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null |
      awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }' || true)
  fi
  printf '%s' "${ref#origin/}"
}

cmd_preflight() {
  local into=""
  while (($#)); do
    case $1 in
      --into) [[ $# -ge 2 ]] || die "--into needs a value"; into=$2; shift 2 ;;
      *) die "preflight: unknown argument: $1" ;;
    esac
  done
  [[ -n $into ]] || into=$(default_into)
  fail() { not_done ok false "$1" ",\"into\":\"$(json_escape "$into")\""; }
  command -v gh >/dev/null || fail "gh is not installed"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
  git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote"
  [[ -n $into ]] || fail "cannot tell origin's default branch (pass --into)"
  git fetch --quiet origin "$into" >&2 2>&1 || fail "cannot fetch origin/$into"
  printf '{"ok":true,"into":"%s","reason":""}\n' "$(json_escape "$into")"
}

cmd_open() {
  local worktree=${1:-} title="" body_file="" into="" base="" branch git_dir count existing url
  [[ -n $worktree && $worktree != --* ]] || die "open: usage: pr.sh open <worktree> --title <t> --body-file <f>"
  shift
  while (($#)); do
    case $1 in
      --title) [[ $# -ge 2 ]] || die "--title needs a value"; title=$2; shift 2 ;;
      --body-file) [[ $# -ge 2 ]] || die "--body-file needs a value"; body_file=$2; shift 2 ;;
      --into) [[ $# -ge 2 ]] || die "--into needs a value"; into=$2; shift 2 ;;
      --base) [[ $# -ge 2 ]] || die "--base needs a value"; base=$2; shift 2 ;;
      *) die "open: unknown argument: $1" ;;
    esac
  done
  [[ -d $worktree ]] || die "open: not a directory: $worktree"
  [[ -n $title ]] || die "open: --title is required"
  [[ -r $body_file ]] || die "open: --body-file is not readable: ${body_file:-<unset>}"

  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir) || die "open: not a git worktree: $worktree"
  if [[ -z $base ]]; then
    [[ -r $git_dir/so-base ]] || die "open: no recorded base in $git_dir (pass --base)"
    base=$(<"$git_dir/so-base")
  fi
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD) || die "open: $worktree is on a detached HEAD"
  [[ -n $into ]] || into=$(default_into "$worktree")
  [[ -n $into ]] || die "open: cannot tell origin's default branch (pass --into)"

  fail() { not_done ok false "$1" ",\"branch\":\"$(json_escape "$branch")\",\"into\":\"$(json_escape "$into")\""; }
  [[ -z $(git -C "$worktree" status --porcelain) ]] || fail "dirty"
  count=$(git -C "$worktree" rev-list --count "$base..HEAD")
  ((count > 0)) || fail "nothing-to-pr"
  git -C "$worktree" fetch --quiet origin "$into" >&2 2>&1 || fail "cannot fetch origin/$into"
  git -C "$worktree" merge-base --is-ancestor "$base" "origin/$into" || fail "base-not-on-$into"
  git -C "$worktree" push --quiet -u origin "$branch" >&2 2>&1 || fail "push failed"

  existing=$(cd "$worktree" && gh pr view "$branch" --json url,state \
    --jq 'select(.state == "OPEN") | .url' 2>/dev/null || true)
  if [[ -n $existing ]]; then
    printf '{"ok":true,"pr":"%s","branch":"%s","into":"%s","reused":true}\n' \
      "$(json_escape "$existing")" "$(json_escape "$branch")" "$(json_escape "$into")"
    return
  fi
  url=$(cd "$worktree" && gh pr create --base "$into" --head "$branch" --title "$title" \
    --body-file "$body_file" | tail -n 1) || fail "gh pr create failed"
  [[ -n $url ]] || fail "gh pr create printed no URL"
  printf '{"ok":true,"pr":"%s","branch":"%s","into":"%s","reused":false}\n' \
    "$(json_escape "$url")" "$(json_escape "$branch")" "$(json_escape "$into")"
}

# wait_for_checks <pr> <timeout>: 0 = checks passed or none exist, 1 = failed, 124 = timed out.
wait_for_checks() {
  local pr=$1 timeout_s=$2 out rc attempt
  local -a runner=()
  command -v timeout >/dev/null && runner=(timeout "$timeout_s")
  out=$(mktemp)
  for attempt in 1 2; do
    rc=0
    ${runner[@]+"${runner[@]}"} gh pr checks "$pr" --watch --fail-fast --interval 15 >"$out" 2>&1 || rc=$?
    cat "$out" >&2
    if ((rc != 0)) && grep -qi 'no checks reported' "$out"; then
      # Checks register a moment after the push; ask again once, then treat it as "no CI".
      if ((attempt == 1)); then sleep "${SO_PR_CHECKS_DELAY:-20}"; continue; fi
      rc=0
    fi
    break
  done
  rm -f "$out"
  return "$rc"
}

cmd_merge() {
  local pr=${1:-} method="" timeout_s=${SO_PR_TIMEOUT:-1800} rc=0 head merge_out
  [[ -n $pr && $pr != --* ]] || die "merge: usage: pr.sh merge <pr-url|number> --method squash|merge|rebase"
  shift
  while (($#)); do
    case $1 in
      --method) [[ $# -ge 2 ]] || die "--method needs a value"; method=$2; shift 2 ;;
      --timeout) [[ $# -ge 2 ]] || die "--timeout needs a value"; timeout_s=$2; shift 2 ;;
      *) die "merge: unknown argument: $1" ;;
    esac
  done
  case $method in squash|merge|rebase) ;; *) die "merge: --method must be squash, merge or rebase" ;; esac
  [[ $timeout_s =~ ^[0-9]+$ ]] || die "merge: timeout must be a number of seconds"

  fail() { not_done state "\"$1\"" "$2" ",\"pr\":\"$(json_escape "$pr")\""; }
  wait_for_checks "$pr" "$timeout_s" || rc=$?
  ((rc != 124)) || fail checks-timeout "checks did not finish within ${timeout_s}s"
  ((rc == 0)) || fail checks-failed "a check failed"

  head=$(gh pr view "$pr" --json headRefName --jq .headRefName 2>/dev/null || true)
  merge_out=$(gh pr merge "$pr" "--$method" 2>&1) || fail merge-refused "$(tail -n 1 <<<"$merge_out")"
  if [[ -n $head ]]; then
    git push --quiet origin --delete "$head" >&2 2>&1 || warn "could not delete remote branch $head"
  fi
  printf '{"state":"merged","pr":"%s","method":"%s"}\n' "$(json_escape "$pr")" "$method"
}

case ${1:-} in
  preflight) shift; cmd_preflight "$@" ;;
  open) shift; cmd_open "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "usage: pr.sh preflight|open|merge ... (see --help)" ;;
esac
