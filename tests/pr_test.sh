#!/usr/bin/env bash
# Tests for pr.sh (preflight, open, merge) with a fake `gh`.  Run: bash tests/pr_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=$SCRIPTS/pr.sh
W=$SCRIPTS/worktree.sh

# Fake gh: logs its arguments to $GH_LOG; behaviour comes from GH_* variables.
mkdir -p "$WORK/ghshim"
cat >"$WORK/ghshim/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "auth status") [[ ${GH_AUTH:-ok} == fail ]] && exit 1; exit 0 ;;
  "pr view")
    case "$*" in
      *headRefName*) printf '%s\n' "${GH_HEAD:-}"; exit 0 ;;
      *) [[ -n ${GH_EXISTING_PR:-} ]] && { printf '%s\n' "$GH_EXISTING_PR"; exit 0; }; exit 1 ;;
    esac ;;
  "pr create") echo "https://example.test/pull/7"; exit 0 ;;
  "pr checks")
    case ${GH_CHECKS:-pass} in
      pass) exit 0 ;;
      fail) echo "build  fail"; exit 1 ;;
      none) echo "no checks reported on the 'sop/task' branch"; exit 1 ;;
      none-then-pass)
        n=$(cat "$GH_LOG.n" 2>/dev/null || echo 0); echo $((n + 1)) >"$GH_LOG.n"
        if ((n == 0)); then echo "no checks reported on the 'sop/task' branch"; exit 1; fi
        exit 0 ;;
    esac ;;
  "pr merge") [[ ${GH_MERGE:-ok} == refuse ]] && { echo "Pull request is not mergeable"; exit 1; }; exit 0 ;;
esac
exit 0
SH
chmod +x "$WORK/ghshim/gh"
export GH_LOG=$WORK/gh.log
: >"$GH_LOG"
# pr <dir> [VAR=value...] -- <pr.sh args>: run pr.sh from <dir> with the fake gh first in PATH.
pr() {
  local dir=$1; shift
  local -a vars=()
  while [[ $1 != -- ]]; do vars+=("$1"); shift; done
  shift
  (cd "$dir" && env PATH="$WORK/ghshim:$PATH" SOP_PR_CHECKS_DELAY=0 "${vars[@]}" bash "$P" "$@")
}

std=$(make_repo std)
up=$WORK/std.up
body=$WORK/body.md
echo "pr body" >"$body"

section "preflight"
out=$(pr "$std" -- preflight); rc=$?
check_eq "ok: exit 0" "$rc" 0
check_eq "ok: into is origin's default branch" "$(json_get '["into"]' <<<"$out")" main
out=$(pr "$std" GH_AUTH=fail -- preflight); rc=$?
check_eq "gh not logged in: exit 1" "$rc" 1
check_eq "gh not logged in: reason" "$(json_get '["reason"]' <<<"$out")" "gh is not logged in"
mkdir -p "$WORK/nogh" && ln -sf "$REAL_GIT" "$WORK/nogh/git"   # a PATH without gh
out=$(cd "$std" && env PATH="$WORK/nogh" "$BASH" "$P" preflight); rc=$?
check_eq "no gh: exit 1" "$rc" 1
check_eq "no gh: ok is false" "$(json_get '["ok"]' <<<"$out")" False
git -C "$std" remote set-head origin -d >/dev/null   # a clone without refs/remotes/origin/HEAD
out=$(pr "$std" -- preflight); rc=$?
check_eq "no origin/HEAD: asks the remote" "$(json_get '["into"]' <<<"$out")" main
git -C "$std" remote set-head origin -a >/dev/null
git clone -q "$up" "$WORK/noorigin" && git -C "$WORK/noorigin" remote remove origin
out=$(pr "$WORK/noorigin" -- preflight); rc=$?
check_eq "no origin: exit 1" "$rc" 1

section "open"
t=$(cd "$std" && bash "$W" create task 2>/dev/null | json_get '["worktree_path"]')
branch=sop/task
out=$(pr "$std" -- open "$t" --title "sop(task): x" --body-file "$body"); rc=$?
check_eq "no commit yet: exit 1" "$rc" 1
check_eq "no commit yet: reason" "$(json_get '["reason"]' <<<"$out")" nothing-to-pr
echo change >>"$t/a.txt"
out=$(pr "$std" -- open "$t" --title "sop(task): x" --body-file "$body"); rc=$?
check_eq "dirty worktree: exit 1" "$rc" 1
check_eq "dirty worktree: reason" "$(json_get '["reason"]' <<<"$out")" dirty
git -C "$t" commit -qam "sop(task): change"
: >"$GH_LOG"
out=$(pr "$std" -- open "$t" --title "sop(task): x" --body-file "$body"); rc=$?
check_eq "open: exit 0" "$rc" 0
check_eq "open: PR url" "$(json_get '["pr"]' <<<"$out")" https://example.test/pull/7
check_eq "open: not reused" "$(json_get '["reused"]' <<<"$out")" False
check "open: branch pushed to origin" git -C "$up" rev-parse --verify -q "refs/heads/$branch"
check "open: gh pr create --base main" grep -q -- "pr create --base main --head $branch" "$GH_LOG"
: >"$GH_LOG"
out=$(pr "$std" GH_EXISTING_PR=https://example.test/pull/3 -- open "$t" --title x --body-file "$body"); rc=$?
check_eq "existing PR: exit 0" "$rc" 0
check_eq "existing PR: reused" "$(json_get '["reused"]' <<<"$out")" True
check_eq "existing PR: url" "$(json_get '["pr"]' <<<"$out")" https://example.test/pull/3
check "existing PR: no gh pr create" bash -c "! grep -q 'pr create' '$GH_LOG'"

# A task whose base is a local commit nobody pushed.
echo local >>"$std/a.txt" && git -C "$std" commit -qam "local only"
t2=$(cd "$std" && bash "$W" create task-two 2>/dev/null | json_get '["worktree_path"]')
echo two >"$t2/two.txt" && git -C "$t2" add -A && git -C "$t2" commit -qm "sop(task-two): two"
out=$(pr "$std" -- open "$t2" --title x --body-file "$body"); rc=$?
check_eq "base not on origin: exit 1" "$rc" 1
check_eq "base not on origin: reason" "$(json_get '["reason"]' <<<"$out")" base-not-on-main
check "base not on origin: nothing pushed" bash -c "! git -C '$up' rev-parse --verify -q refs/heads/sop/task-two"
out=$(pr "$std" -- open "$t2" --title x --body-file "$body" --base origin/main); rc=$?
check_eq "--base override: exit 0" "$rc" 0
git -C "$std" reset -q --hard origin/main

section "merge"
mergebr() { git -C "$up" rev-parse --verify -q "refs/heads/$branch" >/dev/null; }
: >"$GH_LOG"
out=$(pr "$std" GH_HEAD=$branch -- merge https://example.test/pull/7 --method squash); rc=$?
check_eq "checks pass: exit 0" "$rc" 0
check_eq "checks pass: merged" "$(json_get '["state"]' <<<"$out")" merged
check "checks pass: gh pr merge --squash" grep -q -- "pr merge https://example.test/pull/7 --squash" "$GH_LOG"
check "checks pass: no --admin / --delete-branch" bash -c "! grep -qE -- '--admin|--delete-branch' '$GH_LOG'"
check "checks pass: remote branch deleted" bash -c "! git -C '$up' rev-parse --verify -q refs/heads/$branch"

git -C "$t" push -q -u origin "$branch"
: >"$GH_LOG"
out=$(pr "$std" GH_CHECKS=fail GH_HEAD=$branch -- merge 7 --method squash); rc=$?
check_eq "checks fail: exit 1" "$rc" 1
check_eq "checks fail: state" "$(json_get '["state"]' <<<"$out")" checks-failed
check "checks fail: no gh pr merge" bash -c "! grep -q 'pr merge' '$GH_LOG'"
check "checks fail: remote branch kept" mergebr

: >"$GH_LOG"; rm -f "$GH_LOG.n"
out=$(pr "$std" GH_CHECKS=none-then-pass GH_HEAD=$branch -- merge 7 --method rebase --timeout 60); rc=$?
check_eq "checks appear late: exit 0" "$rc" 0
check "checks appear late: asked twice" bash -c "[[ \$(grep -c 'pr checks' '$GH_LOG') -eq 2 ]]"
check "rebase method passed as --rebase" grep -q -- "pr merge 7 --rebase" "$GH_LOG"

git -C "$t" push -q -u origin "$branch"
: >"$GH_LOG"
out=$(pr "$std" GH_CHECKS=none GH_HEAD=$branch -- merge 7 --method merge); rc=$?
check_eq "no checks at all: merged anyway" "$rc" 0
check "no checks at all: gh pr merge --merge" grep -q -- "pr merge 7 --merge" "$GH_LOG"

git -C "$t" push -q -u origin "$branch"
out=$(pr "$std" GH_MERGE=refuse GH_HEAD=$branch -- merge 7 --method squash); rc=$?
check_eq "merge refused: exit 1" "$rc" 1
check_eq "merge refused: state" "$(json_get '["state"]' <<<"$out")" merge-refused
check_eq "merge refused: gh's reason" "$(json_get '["reason"]' <<<"$out")" "Pull request is not mergeable"
check "merge refused: remote branch kept" mergebr

pr "$std" -- merge 7 --method ff >/dev/null 2>&1; rc=$?
check_eq "invalid --method: exit 2" "$rc" 2
pr "$std" -- merge >/dev/null 2>&1; rc=$?
check_eq "merge without a PR: exit 2" "$rc" 2
pr "$std" -- bogus >/dev/null 2>&1; rc=$?
check_eq "unknown command: exit 2" "$rc" 2

finish
