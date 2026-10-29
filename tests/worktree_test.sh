#!/usr/bin/env bash
# Tests for worktree.sh (config, status, provision) and wt.sh.  Run: bash tests/worktree_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W=$SCRIPTS/worktree.sh
WT=$SCRIPTS/wt.sh

section "config: offer_bare_migration"
std=$(make_repo std)
check_eq "standard repo: offered" "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" True
mkdir -p "$std/.agents" && echo '{"offerBareLayout": false}' >"$std/.agents/spec-ops-pipeline.json"
check_eq "offerBareLayout false: not offered" \
  "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" False

repo=$(make_repo bare)
(cd "$repo" && echo SECRET=1 >.env && bash "$SCRIPTS/migrate_to_bare.sh" --apply >/dev/null 2>&1)
check_eq "bare layout: not offered" "$(cd "$repo" && bash "$W" config | json_get '["offer_bare_migration"]')" False

section "config: repo config found from the container root"
mkdir -p "$repo/main/.agents" && echo '{"maxParallel": 2}' >"$repo/main/.agents/spec-ops-pipeline.json"
check_eq "maxParallel read from main/.agents/spec-ops-pipeline.json" \
  "$(cd "$repo" && bash "$W" config | json_get '["max_parallel"]')" 2
rm -r "$repo/main/.agents"

section "config: autoMergeRisk / mergeMethod"
cfg_get() { (cd "$std" && bash "$W" config | json_get "$1"); }
risk_get() { (cd "$std" && env "$@" bash "$W" config | json_get '["auto_merge_risk"]'); }
cfgfile=$std/.agents/spec-ops-pipeline.json
check_eq "autoMergeRisk defaults to L, M" "$(cfg_get '["auto_merge_risk"]')" "['L', 'M']"
check_eq "mergeMethod defaults to squash" "$(cfg_get '["merge_method"]')" squash
echo '{"autoMergeRisk": ["H", "L"], "mergeMethod": "rebase"}' >"$cfgfile"
check_eq "autoMergeRisk read from the config (ordered)" "$(cfg_get '["auto_merge_risk"]')" "['L', 'H']"
check_eq "mergeMethod read from the config" "$(cfg_get '["merge_method"]')" rebase
check_eq "SOP_AUTO_MERGE_RISK wins over the config" "$(risk_get SOP_AUTO_MERGE_RISK=M)" "['M']"
check_eq "SOP_AUTO_MERGE_RISK=none" "$(risk_get SOP_AUTO_MERGE_RISK=none)" "[]"
check_eq "SOP_MERGE_METHOD wins over the config" \
  "$(cd "$std" && SOP_MERGE_METHOD=merge bash "$W" config | json_get '["merge_method"]')" merge
(cd "$std" && SOP_AUTO_MERGE_RISK=X bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid SOP_AUTO_MERGE_RISK: exit 2" "$rc" 2
echo '{"autoMergeRisk": "L"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "autoMergeRisk not a list: exit 2" "$rc" 2
echo '{"mergeMethod": "ff"}' >"$cfgfile"
(cd "$std" && bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid mergeMethod in the config: exit 2" "$rc" 2

section "config: deprecated autoMerge"
echo '{"autoMerge": "low-risk"}' >"$cfgfile"
check_eq "autoMerge low-risk = L" "$(cfg_get '["auto_merge_risk"]')" "['L']"
check_eq "SOP_AUTO_MERGE=all = L, M, H" "$(risk_get SOP_AUTO_MERGE=all)" "['L', 'M', 'H']"
check_eq "SOP_AUTO_MERGE_RISK wins over SOP_AUTO_MERGE" \
  "$(risk_get SOP_AUTO_MERGE=all SOP_AUTO_MERGE_RISK=none)" "[]"
echo '{"autoMerge": "manual", "autoMergeRisk": ["M"]}' >"$cfgfile"
check_eq "autoMergeRisk wins over autoMerge" "$(cfg_get '["auto_merge_risk"]')" "['M']"
(cd "$std" && SOP_AUTO_MERGE=bogus bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "invalid SOP_AUTO_MERGE: exit 2" "$rc" 2

section "config: user config"
userfile=$XDG_CONFIG_HOME/spec-ops-pipeline/config.json
mkdir -p "$(dirname "$userfile")"
echo '{"autoMergeRisk": ["L"], "mergeMethod": "merge", "maxParallel": 6, "defaultBase": "nope"}' >"$userfile"
echo '{"offerBareLayout": false}' >"$cfgfile"
check_eq "user config found" "$(cfg_get '["user_config_file"]')" "$userfile"
check_eq "autoMergeRisk from the user config" "$(cfg_get '["auto_merge_risk"]')" "['L']"
check_eq "maxParallel from the user config" "$(cfg_get '["max_parallel"]')" 6
check_eq "repo-only keys ignored in the user config" "$(cfg_get '["default_base"]')" HEAD
echo '{"offerBareLayout": false, "autoMergeRisk": ["L", "M", "H"]}' >"$cfgfile"
check_eq "repo config wins over the user config" "$(cfg_get '["auto_merge_risk"]')" "['L', 'M', 'H']"
check_eq "other user keys still apply" "$(cfg_get '["merge_method"]')" merge
echo '{"offerBareLayout": false, "autoMerge": "manual"}' >"$cfgfile"
check_eq "repo autoMerge wins over user autoMergeRisk" "$(cfg_get '["auto_merge_risk"]')" "[]"
echo '{"mergeMethod": "ff"}' >"$userfile"
err=$(cd "$std" && bash "$W" config 2>&1 >/dev/null)
check "invalid value names the user config" grep -qF "$userfile" <<<"$err"
check_eq "SOP_USER_CONFIG overrides the path" \
  "$(cd "$std" && SOP_USER_CONFIG=$cfgfile bash "$W" config | json_get '["user_config_file"]')" "$cfgfile"
(cd "$std" && SOP_USER_CONFIG=$WORK/missing.json bash "$W" config >/dev/null 2>&1); rc=$?
check_eq "unreadable SOP_USER_CONFIG: exit 2" "$rc" 2
rm -r "$XDG_CONFIG_HOME"
echo '{"offerBareLayout": false}' >"$cfgfile"

section "status"
(cd "$repo" && bash "$W" create clean-task >/dev/null 2>&1 && bash "$W" create dirty-task >/dev/null 2>&1)
check "create provisioned .env" test -f "$repo/sop/clean-task/.env"
echo change >>"$repo/sop/dirty-task/a.txt"
echo new >"$repo/sop/dirty-task/new.txt"
out=$(cd "$repo" && bash "$W" status)
line() { grep "\"slug\":\"$1\"" <<<"$out"; }
check_eq "clean task is clean" "$(line clean-task | json_get '["state"]')" clean
check_eq "dirty task is dirty" "$(line dirty-task | json_get '["state"]')" dirty
check_eq "dirty task: 1 unstaged" "$(line dirty-task | json_get '["unstaged"]')" 1
check_eq "dirty task: 1 untracked" "$(line dirty-task | json_get '["untracked"]')" 1
check_eq "base recorded" "$(line clean-task | json_get '["base"]')" "$(git -C "$repo/main" rev-parse origin/main)"
check_eq "ahead_of_base 0" "$(line clean-task | json_get '["ahead_of_base"]')" 0
check "main worktree not listed" bash -c "! grep -q '\"branch\":\"main\"' <<<'$out'"
(cd "$repo" && bash "$W" status --check >/dev/null); rc=$?
check_eq "--check with a dirty task: exit 1" "$rc" 1
rm -rf "$repo/sop/clean-task"
check_eq "deleted worktree dir is missing" \
  "$(cd "$repo" && bash "$W" status | grep '"clean-task"' | json_get '["state"]')" missing
git -C "$repo/main" worktree prune

section "provision"
rm -f "$repo/sop/dirty-task/.env"
out=$(cd "$repo" && bash "$W" provision sop/dirty-task 2>/dev/null)
check ".env provisioned into an existing worktree" test -f "$repo/sop/dirty-task/.env"
check "provision reports it" grep -q 'copy:.env' <<<"$out"
(cd "$repo" && bash "$W" provision main >/dev/null 2>&1); rc=$?
check_eq "source worktree refused" "$rc" 2
(cd "$repo" && bash "$W" provision "$WORK" >/dev/null 2>&1); rc=$?
check_eq "foreign directory refused" "$rc" 2

section "wt.sh"
git -C "$repo/main" branch local-branch
git -C "$WORK/bare.up" branch remote-branch && git -C "$repo/main" fetch -q origin
(cd "$repo" && bash "$WT" add feat/new >/dev/null 2>&1); rc=$?
check_eq "add new branch" "$rc" 0
check_eq "new branch starts at origin/main" "$(git -C "$repo/feat/new" rev-parse HEAD)" "$(git -C "$repo/main" rev-parse origin/main)"
check "new branch has no upstream" bash -c "! git -C '$repo/feat/new' rev-parse @{u}"
check "new worktree provisioned" test -f "$repo/feat/new/.env"
(cd "$repo" && bash "$WT" add local-branch >/dev/null 2>&1)
check_eq "existing local branch checked out" "$(git -C "$repo/local-branch" branch --show-current)" local-branch
(cd "$repo" && bash "$WT" add remote-branch >/dev/null 2>&1)
check_eq "remote-only branch tracks origin" "$(git -C "$repo/remote-branch" rev-parse --abbrev-ref @{u})" origin/remote-branch
(cd "$repo" && bash "$WT" add sop/x >/dev/null 2>&1); rc=$?
check_eq "sop/ branch refused" "$rc" 2
(cd "$repo/feat/new" && bash "$WT" st --check >/dev/null); rc=$?
check_eq "status --check with a dirty spec-ops-pipeline task: exit 1" "$rc" 1
check "status -s lists feat/new" bash -c "cd '$repo' && bash '$WT' st -s | grep -q '^CLEAN   feat/new'"
echo x >"$repo/feat/new/x.txt"
(cd "$repo" && bash "$WT" remove feat/new >/dev/null 2>&1); rc=$?
check_eq "remove dirty worktree refused" "$rc" 2
(cd "$repo" && bash "$WT" remove feat/new --force >/dev/null 2>&1)
check "remove --force drops worktree and empty feat/" test ! -e "$repo/feat"
check "branch kept after remove" git -C "$repo/main" show-ref --verify refs/heads/feat/new
(cd "$repo" && bash "$WT" remove main >/dev/null 2>&1); rc=$?
check_eq "default-branch worktree refused" "$rc" 2
(cd "$std" && bash "$WT" list >/dev/null 2>&1); rc=$?
check_eq "standard layout refused" "$rc" 2

section "wt.sh link-config"
mkdir -p "$repo/main/.claude/skills" && echo agents >"$repo/main/AGENTS.md" && echo mine >"$repo/main/CLAUDE.md"
echo root >"$repo/CLAUDE.md"
(cd "$repo/main" && bash "$WT" link-config >/dev/null 2>&1); rc=$?
check_eq "link-config exits 0" "$rc" 0
check_eq ".claude linked relative to the root" "$(readlink "$repo/.claude")" main/.claude
check_eq "AGENTS.md linked" "$(readlink "$repo/AGENTS.md")" main/AGENTS.md
check_eq "real CLAUDE.md at the root left as is" "$(cat "$repo/CLAUDE.md")" root
check "nothing linked for config main/ lacks" test ! -e "$repo/.gemini" -a ! -L "$repo/.gemini"
check "second run reports up to date" bash -c "cd '$repo' && bash '$WT' link-config | grep -q 'up to date'"
rm "$repo/.claude" && ln -s old/.claude "$repo/.claude"
(cd "$repo" && bash "$WT" link-config >/dev/null 2>&1)
check_eq "dangling link re-pointed" "$(readlink "$repo/.claude")" main/.claude
rm "$repo/main/AGENTS.md"
(cd "$repo" && bash "$WT" link-config >/dev/null 2>&1)
check "link removed once main/ has no AGENTS.md" test ! -L "$repo/AGENTS.md"
rm -r "$repo/.claude" "$repo/CLAUDE.md" "$repo/main/.claude" "$repo/main/CLAUDE.md"

section "rundir"
out=$(cd "$repo/sop/dirty-task" && bash "$W" rundir)
rd=$(json_get '["run_dir"]' <<<"$out")
check_eq "run dir in the git common dir" "$rd" "$(git -C "$repo/main" rev-parse --path-format=absolute --git-common-dir)/sop-run"
check_eq "same run dir from the source worktree" "$(cd "$repo/main" && bash "$W" rundir | json_get '["run_dir"]')" "$rd"
check "logs dir created" test -d "$rd/logs"
check_eq "no state yet" "$(json_get '["has_state"]' <<<"$out")" False
echo '{}' >"$rd/state.json"
check_eq "state detected" "$(cd "$repo" && bash "$W" rundir | json_get '["has_state"]')" True
check_eq "source worktree stays clean" "$(git -C "$repo/main" status --porcelain)" ""
arch=$(cd "$repo" && bash "$W" rundir --archive | json_get '["archived"]')
check "archived run dir keeps state" test -f "$arch/state.json"
check "run dir gone after archive" test ! -e "$rd"
(cd "$repo" && bash "$W" rundir --archive >/dev/null 2>&1); rc=$?
check_eq "archive without a run dir: exit 2" "$rc" 2

section "standard layout lifecycle still works (regression)"
rm -r "$std/.agents"
t=$(cd "$std" && bash "$W" create task-one 2>/dev/null | json_get '["worktree_path"]')
check_eq "task worktree at <parent>/worktrees/<repo>/<slug>" "$t" "$WORK/worktrees/std/task-one"
echo change >>"$t/a.txt"
printf 'a.txt\n' >"$WORK/whitelist"
check "check_scope passes for a whitelisted change" bash "$SCRIPTS/check_scope.sh" "$t" "$WORK/whitelist"
git -C "$t" commit -qam "sop(task-one): change"
(cd "$std" && bash "$W" integrate 1 --base HEAD sop/task-one >/dev/null 2>&1); rc=$?
check_eq "integrate exits 0" "$rc" 0
check_eq "status lists task and stage" "$(cd "$std" && bash "$W" status | python3 -c 'import json,sys; print(sorted({json.loads(l)["kind"] for l in sys.stdin}))')" \
  "['stage', 'task']"
(cd "$std" && bash "$W" remove --stage 1 >/dev/null 2>&1 && bash "$W" remove task-one >/dev/null 2>&1); rc=$?
check_eq "remove stage and task" "$rc" 0
check_eq "no spec-ops-pipeline worktrees left" "$(cd "$std" && bash "$W" list)" ""

section "remove: docker compose down"
# Fake docker: logs "<cwd>|<args>", prints $DOCKER_ROWS for `ps`, exits $DOCKER_DOWN_RC for `compose`.
mkdir -p "$WORK/dockershim"
cat >"$WORK/dockershim/docker" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$DOCKER_LOG"
case $1 in
  ps) cat "$DOCKER_ROWS" ;;
  compose) exit "${DOCKER_DOWN_RC:-0}" ;;
esac
SH
chmod +x "$WORK/dockershim/docker"
export DOCKER_LOG=$WORK/docker.log DOCKER_ROWS=$WORK/docker.rows
dremove() { (cd "$repo" && PATH="$WORK/dockershim:$PATH" bash "$W" remove "$@"); }
new_task() { (cd "$repo" && bash "$W" create "$1" 2>/dev/null | json_get '["worktree_path"]'); }

t=$(new_task compose-own)
printf 'compose-own\t%s\ncompose-own\t%s/svc\nother\t%s/main\n' "$t" "$t" "$repo" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
dremove compose-own >/dev/null 2>&1; rc=$?
check_eq "remove with own compose project exits 0" "$rc" 0
check_eq "down run once, in the project's dir, without -v" "$(grep -c '|compose' "$DOCKER_LOG")" 1
check "down targets the project" grep -qxF "$t|compose -p compose-own down" "$DOCKER_LOG"
check "worktree removed" test ! -e "$t"

t=$(new_task compose-shared)
printf 'shared\t%s\nshared\t%s/main\n' "$t" "$repo" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
err=$(dremove compose-shared 2>&1 >/dev/null)
check "shared project: no down" test "$(grep -c '|compose' "$DOCKER_LOG")" -eq 0
check "shared project: reported as left running" grep -q "left running" <<<"$err"
check "shared project: worktree still removed" test ! -e "$t"

t=$(new_task compose-off)
printf 'off\t%s\n' "$t" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
SOP_COMPOSE_DOWN=0 dremove compose-off >/dev/null 2>&1
check_eq "SOP_COMPOSE_DOWN=0: docker not called" "$(wc -l <"$DOCKER_LOG")" 0

t=$(new_task compose-dirty)
printf 'dirty\t%s\n' "$t" >"$DOCKER_ROWS"
echo change >>"$t/a.txt"
: >"$DOCKER_LOG"
dremove compose-dirty >/dev/null 2>&1; rc=$?
check_eq "dirty worktree refused" "$rc" 2
check_eq "dirty worktree: docker not called" "$(wc -l <"$DOCKER_LOG")" 0

printf 'dirty\t%s\n' "$t" >"$DOCKER_ROWS"
: >"$DOCKER_LOG"
DOCKER_DOWN_RC=1 dremove compose-dirty --force >/dev/null 2>&1; rc=$?
check_eq "failed down does not block remove" "$rc" 0
check "failed down: down was attempted" grep -q '|compose -p dirty down' "$DOCKER_LOG"
check "failed down: worktree removed" test ! -e "$t"

finish
