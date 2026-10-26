#!/usr/bin/env bash
# Tests for scripts/migrate_to_bare.sh.  Run: bash tests/migrate_bare_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
M=$SCRIPTS/migrate_to_bare.sh

# Puts a `git` shim first on PATH that fails once on the given argument sequence.
shim_fail_once() {
  mkdir -p "$WORK/shim"
  rm -f "$WORK/shim/fired"
  cat >"$WORK/shim/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" $1 "* && ! -e $WORK/shim/fired ]]; then
  touch $WORK/shim/fired; echo "shim: forced failure of '$1'" >&2; exit 1
fi
exec $REAL_GIT "\$@"
EOF
  chmod +x "$WORK/shim/git"
}

section "dry run"
repo=$(make_repo dry)
before=$(tree_of "$repo")
plan=$(cd "$repo" && bash "$M"); rc=$?
check_eq "dry run exits 0" "$rc" 0
check_eq "dry run is eligible" "$(json_get '["eligible"]' <<<"$plan")" True
check_eq "dry run targets <repo>/main" "$(json_get '["after"]["source_worktree"]' <<<"$plan")" "$repo/main"
check_eq "dry run changes nothing" "$(tree_of "$repo")" "$before"

section "dry run warns about personal skill symlinks into the repo"
repo=$(make_repo skill)
home=$WORK/skill-home
mkdir -p "$home/.claude/skills" "$home/.gemini/config/skills" "$home/.codex/skills" "$WORK/other"
ln -s "$repo" "$home/.claude/skills/whole"
ln -s "$repo/sub" "$home/.gemini/config/skills/nested"
ln -s "$WORK/other" "$home/.codex/skills/unrelated"
warnings=$(cd "$repo" && HOME=$home bash "$M" | json_get '["warnings"]')
check "link to the repo root reported with its new target" \
  grep -qF "ln -sfn $repo/main $home/.claude/skills/whole" <<<"$warnings"
check "link into a subdirectory reported with its new target" \
  grep -qF "ln -sfn $repo/main/sub $home/.gemini/config/skills/nested" <<<"$warnings"
check "unrelated link not reported" bash -c "! grep -qF unrelated <<<\"\$1\"" _ "$warnings"
git clone -q "$WORK/skill.up" "$home/.agents/skills/inplace" && touch "$home/.agents/skills/inplace/SKILL.md"
warnings=$(cd "$home/.agents/skills/inplace" && HOME=$home bash "$M" | json_get '["warnings"]')
check "repo that is itself a skill directory reported" \
  grep -qF "$home/.agents/skills/inplace is itself a skill in $home/.agents/skills" <<<"$warnings"
check_eq "plain repo outside the skills directories: no skill warning" \
  "$(cd "$repo" && touch SKILL.md && HOME=$home bash "$M" | json_get '["warnings"]' | grep -c 'is itself a skill')" 0

section "convert a dirty checkout (staged, unstaged, untracked, ignored, top-level main/)"
repo=$(make_repo dirty)
(cd "$repo"
 echo stashed >>a.txt && git stash -q
 echo staged >>a.txt && git add a.txt && echo unstaged >>a.txt
 echo new >new.txt && echo SECRET=1 >.env && mkdir -p main && echo x >main/x.txt)
state=$(state_of "$repo")
reflog=$(git -C "$repo" reflog | wc -l)
stash=$(git -C "$repo" stash list | wc -l)
out=$(cd "$repo/main" && bash "$M" --apply); rc=$?
check_eq "apply exits 0 (run from a subdirectory)" "$rc" 0
check_eq "result reports migrated" "$(json_get '["migrated"]' <<<"$out")" True
check ".bare is a bare repo" test "$(git --git-dir="$repo/.bare" config --bool core.bare)" = true
check_eq ".git is a gitfile" "$(cat "$repo/.git")" "gitdir: ./.bare"
check_eq "only .bare, .git and main/ at the root" "$(ls -A "$repo" | tr '\n' ' ')" ".bare .git main "
check_eq "status, staged and unstaged changes preserved" "$(state_of "$repo/main")" "$state"
check "ignored .env moved along" test -f "$repo/main/.env"
check "top-level main/ dir of the project kept" test -f "$repo/main/main/x.txt"
check_eq "HEAD reflog preserved" "$(git -C "$repo/main" reflog | wc -l)" "$reflog"
check_eq "stash preserved" "$(git -C "$repo/main" stash list | wc -l)" "$stash"
check "git works from the container root" git -C "$repo" rev-parse --git-common-dir
check_eq "worktree.sh sees the bare layout" \
  "$(cd "$repo" && bash "$SCRIPTS/worktree.sh" config | json_get '["layout"]')" bare
check_eq "worktree.sh source_worktree = main/" \
  "$(cd "$repo" && bash "$SCRIPTS/worktree.sh" config | json_get '["source_worktree"]')" "$repo/main"

section "blockers (nothing changes, exit 1)"
plan=$(cd "$repo" && bash "$M"); rc=$?
check_eq "already bare: exit 1" "$rc" 1
check "already bare: reason given" grep -q 'already a bare-repo' <<<"$plan"

blocked() {  # blocked <name> <pattern> <setup command...>
  local name=$1 pattern=$2 r before out rc
  shift 2
  r=$(make_repo "blk-$name")
  (cd "$r" && "$@") >/dev/null 2>&1
  before=$(tree_of "$r")
  out=$(cd "$r" && bash "$M" --apply 2>&1); rc=$?
  check_eq "$name: exit 1" "$rc" 1
  if grep -q -- "$pattern" <<<"$out"; then pass "$name: reason given"; else fail "$name: reason given ($out)"; fi
  check_eq "$name: untouched" "$(tree_of "$r")" "$before"
}
blocked submodule "submodules" touch .gitmodules
blocked detached "detached" git checkout -q --detach
blocked non-default "not the default branch" git switch -qc feature
blocked merge "merge is in progress" bash -c 'git switch -qc other HEAD~1 && echo x >a.txt && git commit -qam x &&
  git switch -q main && git merge -q other'
blocked index-lock "index.lock" touch .git/index.lock
blocked tmp-exists "already exists" mkdir .so-migrate-tmp
blocked so-leftover "earlier spec-ops run" git worktree add -q -b so/old ../so-old

section "agent config is reachable from the container root"
repo=$(make_repo agent)
(cd "$repo" && mkdir -p .claude/skills/demo && echo skill >.claude/skills/demo/SKILL.md &&
 echo rules >AGENTS.md && git add -A && git commit -qm agent && echo local >CLAUDE.md)
plan=$(cd "$repo" && bash "$M")
check_eq "plan lists the root links" \
  "$(json_get '["after"]["root_links"]' <<<"$plan" | python3 -c 'import ast,sys; print(sorted(l["path"].rsplit("/",1)[1] for l in ast.literal_eval(sys.stdin.read())))')" \
  "['.claude', 'AGENTS.md', 'CLAUDE.md']"
out=$(cd "$repo" && bash "$M" --apply); rc=$?
check_eq "apply exits 0" "$rc" 0
check "result lists the root links" grep -qF '"target":"main/.claude"' <<<"$out"
check_eq "root holds .bare, .git, main/ and the links" "$(ls -A "$repo" | tr '\n' ' ')" ".bare .claude .git AGENTS.md CLAUDE.md main "
check_eq "links are relative" "$(readlink "$repo/.claude")" main/.claude
check_eq "skill readable from the root" "$(cat "$repo/.claude/skills/demo/SKILL.md")" skill
check_eq "untracked CLAUDE.md reachable from the root" "$(cat "$repo/CLAUDE.md")" local
check_eq "main/ status unchanged by the links" "$(git -C "$repo/main" status --porcelain)" "?? CLAUDE.md"

repo=$(make_repo agent-rb)
(cd "$repo" && mkdir .claude && echo x >.claude/settings.json && git add -A && git commit -qm agent)
state=$(state_of "$repo") before=$(tree_of "$repo")
mkdir -p "$WORK/lnshim" && printf '#!/usr/bin/env bash\necho "shim: ln fails" >&2; exit 1\n' >"$WORK/lnshim/ln"
chmod +x "$WORK/lnshim/ln"
out=$(cd "$repo" && PATH="$WORK/lnshim:$PATH" bash "$M" --apply 2>&1); rc=$?
check_eq "failing link: exit 2" "$rc" 2
check_eq "failing link: files and .git restored" "$(tree_of "$repo")" "$before"
check_eq "failing link: changes restored" "$(state_of "$repo")" "$state"

section "linked worktrees inside and outside the repo are reconnected"
repo=$(make_repo linked)
git -C "$repo" worktree add -q -b in "$repo/.claude/worktrees/in"
git -C "$repo" worktree add -q -b out "$WORK/linked-out"
(cd "$repo" && bash "$M" --apply >/dev/null 2>&1); rc=$?
check_eq "apply exits 0" "$rc" 0
check_eq "nested worktree works at its new path" \
  "$(git -C "$repo/main/.claude/worktrees/in" rev-parse --path-format=absolute --git-common-dir)" "$repo/.bare"
check_eq "outside worktree works" \
  "$(git -C "$WORK/linked-out" rev-parse --path-format=absolute --git-common-dir)" "$repo/.bare"
check "no prunable worktree entries" bash -c "! git -C '$repo/main' worktree list --porcelain | grep -q '^prunable'"

section "rollback restores the original repository"
for step in "worktree add" "worktree repair"; do
  repo=$(make_repo "rb-${step// /-}")
  git -C "$repo" worktree add -q -b out "$WORK/rb-${step// /-}-out"
  (cd "$repo" && echo dirty >>a.txt && git add a.txt && echo more >>a.txt && echo u >u.txt)
  state=$(state_of "$repo") before=$(tree_of "$repo")
  shim_fail_once "$step"
  out=$(cd "$repo" && PATH="$WORK/shim:$PATH" bash "$M" --apply 2>&1); rc=$?
  check_eq "failing '$step': exit 2" "$rc" 2
  check "failing '$step': reports restore" grep -q 'back to its original state' <<<"$out"
  check_eq "failing '$step': files and .git restored" "$(tree_of "$repo")" "$before"
  check_eq "failing '$step': changes restored" "$(state_of "$repo")" "$state"
  check "failing '$step': linked worktree still works" git -C "$WORK/rb-${step// /-}-out" status
done

section "skill files mention no specific project"
project=nex; project+=us   # split so this file does not match itself
if grep -rqi "$project" "$SKILL_DIR"; then fail "no project name in skill files"; else pass "no project name in skill files"; fi

finish
