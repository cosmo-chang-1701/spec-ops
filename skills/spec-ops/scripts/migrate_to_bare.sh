#!/usr/bin/env bash
# Converts a standard checkout into the bare-repo worktree layout, in place.
#
# Usage:
#   migrate_to_bare.sh            # dry run: print the plan (JSON), change nothing
#   migrate_to_bare.sh --apply    # convert; only after the user agreed to the plan
#
# Run it from anywhere inside the repository. The repository directory keeps its path:
#   before                       after
#   <repo>/.git/                 <repo>/.bare/       the former .git, core.bare = true
#   <repo>/<files>               <repo>/.git         file: "gitdir: ./.bare"
#                                <repo>/<branch>/    worktree on the default branch, holds <files>
#                                <repo>/.claude ...  symlinks to <branch>/ agent config (below)
#
# Agent config at the top level (AGENT_CONFIG) gets a relative symlink at <repo> pointing into
# <branch>/, so agent CLIs started at <repo> still load its skills and instructions.
# All moves are renames inside <repo>; nothing is copied and nothing is written outside it.
# History, branches, stash, hooks, remotes and uncommitted changes (including what is
# staged) are kept; the result is verified and any failure rolls everything back.
# Linked worktrees are reconnected with `git worktree repair`.
#
# Exit: 0 = convertible (dry run) / converted, 1 = blocked (plan lists why; nothing changed),
#       2 = error, rolled back, 3 = rollback incomplete (manual steps printed).
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0   # never let status refresh the index behind our back

readonly TMP_NAME=.so-migrate-tmp
readonly BRANCH_PREFIX=${SO_BRANCH_PREFIX:-so/}
readonly STAGE_PREFIX=${SO_STAGE_PREFIX:-so-stage/}
readonly MIN_GIT_MAJOR=2 MIN_GIT_MINOR=31
# Keep in sync with wt.sh.
readonly AGENT_CONFIG=(CLAUDE.md AGENTS.md GEMINI.md .claude .agents .codex .gemini)

die() { printf 'migrate_to_bare: %s\n' "$*" >&2; exit 2; }
warn() { printf 'migrate_to_bare: %s\n' "$*" >&2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
json_str() { printf '"%s"' "$(json_escape "$1")"; }
json_list() {
  local out="" item
  for item in "$@"; do out+="${out:+,}$(json_str "$item")"; done
  printf '[%s]' "$out"
}

require_git() {
  local version major minor
  version=$(git --version | awk '{print $3}')
  IFS=. read -r major minor _ <<<"$version"
  if ((major < MIN_GIT_MAJOR || (major == MIN_GIT_MAJOR && minor < MIN_GIT_MINOR))); then
    die "git >= ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR} required (found $version)"
  fi
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
}

# Hash of everything the conversion must preserve: status, staged diff, worktree diff.
snapshot() {
  {
    git -C "$1" status --porcelain=v1 -z --untracked-files=all
    printf '\0--staged--\0'
    git -C "$1" diff --cached --binary --no-color --no-ext-diff --no-textconv
    printf '\0--worktree--\0'
    git -C "$1" diff HEAD --binary --no-color --no-ext-diff --no-textconv
  } | sha256sum | cut -d' ' -f1
}

# Populates: REPO BRANCH DEFAULT_BRANCH WT BARE TMP DIRTY BLOCKERS WARNINGS LINKED_OLD LINKED_NEW
#            ROOT_LINKS
inspect() {
  local common git_dir path branch prunable rel entry f name
  BLOCKERS=() WARNINGS=() LINKED_OLD=() LINKED_NEW=() ROOT_LINKS=()
  BRANCH="" DEFAULT_BRANCH="" WT="" DIRTY=false
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  if [[ $(git -C "$common" config --bool core.bare 2>/dev/null || true) == true ]]; then
    REPO=$(dirname "$common") BARE=$common TMP=""
    BLOCKERS+=("already a bare-repo worktree layout")
    return 0
  fi
  REPO=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')
  git_dir="$REPO/.git" BARE="$REPO/.bare" TMP="$REPO/$TMP_NAME"

  if [[ $common != "$git_dir" || ! -d $git_dir || -L $git_dir ]]; then
    BLOCKERS+=("the git directory is not $git_dir (separate git dir or gitfile)")
    return 0
  fi
  [[ -z $(git -C "$REPO" config core.worktree || true) ]] ||
    BLOCKERS+=("core.worktree is set")
  [[ $(git -C "$REPO" config --bool core.sparseCheckout || true) != true ]] ||
    BLOCKERS+=("sparse checkout is enabled")
  [[ ! -e $REPO/.gitmodules && ! -d $git_dir/modules ]] ||
    BLOCKERS+=("the repository uses submodules (not supported)")
  [[ ! -e $git_dir/index.lock ]] ||
    BLOCKERS+=("$git_dir/index.lock exists (another git process is running, or remove the stale lock)")
  for f in MERGE_HEAD:merge CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect \
           rebase-merge:rebase rebase-apply:rebase/am sequencer:sequencer; do
    [[ ! -e $git_dir/${f%%:*} ]] || BLOCKERS+=("a ${f#*:} is in progress")
  done

  if ! BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD); then
    BRANCH="" BLOCKERS+=("HEAD is detached (check out the default branch first)")
  elif ! git -C "$REPO" rev-parse --verify --quiet HEAD >/dev/null; then
    BLOCKERS+=("branch '$BRANCH' has no commits yet")
  fi
  DEFAULT_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
  if [[ -z $DEFAULT_BRANCH ]]; then
    DEFAULT_BRANCH=$BRANCH
    [[ -z $BRANCH ]] || WARNINGS+=("origin/HEAD is not set; treating the current branch '$BRANCH' as the default branch (git remote set-head origin --auto fixes the detection)")
  elif [[ -n $BRANCH && $BRANCH != "$DEFAULT_BRANCH" ]]; then
    BLOCKERS+=("checked out on '$BRANCH', not the default branch '$DEFAULT_BRANCH' (run: git switch $DEFAULT_BRANCH)")
  fi
  if [[ -n $BRANCH ]]; then
    WT="$REPO/$BRANCH"
    case /$BRANCH/ in
      /.bare/*|/.git/*|/"$TMP_NAME"/*) BLOCKERS+=("branch name '$BRANCH' collides with the layout's own entries") ;;
    esac
  fi

  [[ -w $REPO ]] || BLOCKERS+=("$REPO is not writable")
  [[ ! -e $TMP ]] || BLOCKERS+=("$TMP already exists (left over from an earlier attempt?)")
  shopt -s dotglob nullglob
  for entry in "$REPO"/*; do
    name=${entry##*/}
    [[ $name == .git ]] && continue
    if mountpoint -q "$entry" 2>/dev/null; then
      BLOCKERS+=("$name is a mount point and cannot be moved")
    elif [[ -d $entry && ! -L $entry && ! -w $entry ]]; then
      BLOCKERS+=("$name is a directory you cannot write to (owner: $(stat -c %U "$entry")), so it cannot be moved")
    fi
  done
  shopt -u dotglob nullglob

  while IFS=$'\t' read -r path branch prunable; do
    if [[ $branch == "$BRANCH_PREFIX"* || $branch == "$STAGE_PREFIX"* ]]; then
      BLOCKERS+=("worktree of an earlier spec-ops run still exists: $path ($branch); finish or remove it first")
    elif ((prunable)); then
      WARNINGS+=("stale worktree entry $path (git worktree prune removes it)")
    else
      LINKED_OLD+=("$path")
      if [[ $path == "$REPO"/* && -n $WT ]]; then LINKED_NEW+=("$WT/${path#"$REPO"/}")
      else LINKED_NEW+=("$path")
      fi
    fi
  done < <(git -C "$REPO" worktree list --porcelain | awk '
    function flush() { if (n > 1 && path != "") print path "\t" branch "\t" prunable }
    /^worktree / { flush(); n++; path = substr($0, 10); branch = ""; prunable = 0; next }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    /^prunable/  { prunable = 1; next }
    END          { flush() }')

  ((${#BLOCKERS[@]})) && return 0
  [[ -z $(git -C "$REPO" status --porcelain=v1) ]] || DIRTY=true
  for f in "${AGENT_CONFIG[@]}"; do
    [[ -e $REPO/$f || -L $REPO/$f ]] && ROOT_LINKS+=("$f")
  done
  collect_warnings
}

collect_warnings() {
  local venv f line agent=""
  WARNINGS+=("close editors, terminals, dev servers and containers that use $REPO before converting")
  for f in "${ROOT_LINKS[@]}"; do agent+="${agent:+, }$f"; done
  [[ -z $agent ]] ||
    WARNINGS+=("agent config ($agent) moves into $BRANCH/ and gets symlinks at $REPO: agent sessions opened at $REPO load the $BRANCH branch's config, sessions in other worktrees their own")
  collect_skill_warnings
  while IFS= read -r venv; do
    venv=$(dirname "$venv")
    WARNINGS+=("virtualenv ${venv#"$REPO"/} contains absolute paths; recreate it after the move (e.g. uv sync)")
  done < <(find "$REPO" -maxdepth 3 \( -name .git -o -name node_modules \) -prune -o -name pyvenv.cfg -print 2>/dev/null)
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [[ -f $REPO/$f ]] || continue
    grep -qE '^name:' "$REPO/$f" && continue
    grep -qs '^COMPOSE_PROJECT_NAME=' "$REPO/.env" && continue
    WARNINGS+=("$f has no top-level name: its Compose project name changes from '$(basename "$REPO")' to '$(basename "$WT")' (existing containers/volumes keep the old name)")
  done
  while IFS= read -r line; do
    WARNINGS+=("git config value points into the old path and is not rewritten: $line")
  done < <(git config --file "$REPO/.git/config" --list | grep -F "$REPO/" || true)
  case $(git -C "$REPO" config core.fsmonitor || true) in
    ""|false) ;;
    *) WARNINGS+=("core.fsmonitor is enabled; its daemon is stopped before converting") ;;
  esac
  return 0
}

# Personal skills directories that load a skill from $REPO, which breaks once its files move
# to $WT: $REPO itself is a skill directory there (<dir>/<name>/SKILL.md), or a symlink there
# resolves into $REPO (e.g. a skill installed with `ln -s <repo> ~/.claude/skills/<name>`).
collect_skill_warnings() {
  local real dir link target
  real=$(realpath "$REPO")
  for dir in "$HOME"/.claude/skills "$HOME"/.agents/skills "$HOME"/.codex/skills \
             "$HOME"/.gemini/skills "$HOME"/.gemini/config/skills; do
    [[ -d $dir ]] || continue
    target=$(realpath "$dir")
    [[ -f $REPO/SKILL.md && $(dirname "$real") == "$target" ]] &&
      WARNINGS+=("$REPO is itself a skill in $dir; its SKILL.md moves to $WT/SKILL.md and agents no longer load it from $REPO (move the repo out of $dir, then: ln -s <new repo path>/$BRANCH $REPO)")
    [[ $target == "$real" || $target == "$real"/* ]] && continue   # moves along with the repo
    for link in "$dir"/*; do
      [[ -L $link ]] || continue
      target=$(realpath -m "$link")
      [[ $target == "$real" || $target == "$real"/* ]] || continue
      WARNINGS+=("skill symlink $link points into $REPO and breaks after converting; re-point it: ln -sfn $WT${target#"$real"} $link")
    done
  done
}

# root_links_json <name>...: [{"path": <repo>/<name>, "target": <branch>/<name>}, ...]
root_links_json() {
  local f out=""
  for f in "$@"; do
    out+="${out:+,}{\"path\":$(json_str "$REPO/$f"),\"target\":$(json_str "$BRANCH/$f")}"
  done
  printf '[%s]' "$out"
}

print_plan() {
  local i linked=""
  for i in "${!LINKED_OLD[@]}"; do
    linked+="${linked:+,}{\"path\":$(json_str "${LINKED_OLD[$i]}"),\"new_path\":$(json_str "${LINKED_NEW[$i]}")}"
  done
  printf '{"eligible":%s,"layout":"bare-repo worktree","repo":%s,"branch":%s,"default_branch":%s,' \
    "$( ((${#BLOCKERS[@]})) && echo false || echo true)" "$(json_str "$REPO")" \
    "$(json_str "$BRANCH")" "$(json_str "$DEFAULT_BRANCH")"
  printf '"after":{"bare_dir":%s,"git_file":%s,"source_worktree":%s,"root_links":%s},' \
    "$(json_str "$BARE")" "$(json_str "$REPO/.git")" "$(json_str "$WT")" "$(root_links_json "${ROOT_LINKS[@]}")"
  printf '"dirty":%s,"linked_worktrees":[%s],"blockers":%s,"warnings":%s}\n' \
    "$DIRTY" "$linked" "$(json_list "${BLOCKERS[@]}")" "$(json_list "${WARNINGS[@]}")"
}

# ---- apply -------------------------------------------------------------------------------
# STAGE records how far the conversion got; rollback undoes exactly that much.

run() { "$@" || fail "$*"; }

fail() {
  trap '' INT TERM
  warn "step failed: $1; rolling back"
  if rollback; then
    warn "conversion aborted; $REPO is back to its original state"
    exit 2
  fi
  manual_recovery
  exit 3
}

rollback() {
  local ok=0 f name dir
  set +e
  if ((STAGE >= 12)); then
    for f in "${LINKS_MADE[@]}"; do rm -f "$REPO/$f" || ok=1; done
  fi
  if ((STAGE >= 10)); then
    for f in "${STATE_MOVED[@]}"; do mv -f "$ADMIN/$f" "$BARE/$f" || ok=1; done
  fi
  ((STAGE >= 9)) && { mv "$WT" "$TMP" || ok=1; }
  ((STAGE >= 7)) && [[ -f $TMP/.git ]] && { rm -f "$TMP/.git" || ok=1; }
  if ((STAGE >= 6)); then
    [[ -f $WT/.git ]] && rm -f "$WT/.git"
    [[ $ADMIN == "$BARE"/worktrees/* ]] && { rm -rf "$ADMIN" || ok=1; }
    rmdir "$BARE/worktrees" 2>/dev/null   # only if this run created it (no linked worktrees)
  fi
  if ((STAGE >= 5)); then
    dir=$WT   # remove the (empty) worktree dir and any parents created for a/b branch names
    while [[ -n $dir && $dir == "$REPO"/* && -d $dir ]] && rmdir "$dir" 2>/dev/null; do dir=$(dirname "$dir"); done
    [[ -f $REPO/.git ]] && { rm -f "$REPO/.git" || ok=1; }
  fi
  ((STAGE >= 4)) && { git --git-dir="$BARE" config core.bare false || ok=1; }
  ((STAGE >= 3)) && { mv "$BARE" "$REPO/.git" || ok=1; }
  if ((STAGE >= 2)); then
    for name in "${MOVED[@]}"; do mv -- "$TMP/$name" "$REPO/$name" || ok=1; done
  fi
  ((STAGE >= 1)) && { rmdir "$TMP" || ok=1; }
  if ((STAGE >= 11 && ${#LINKED_OLD[@]})); then
    git -C "$REPO" worktree repair "${LINKED_OLD[@]}" >&2 || ok=1
  fi
  if ((ok == 0)) && [[ $(snapshot "$REPO" 2>/dev/null) != "$BEFORE" ]]; then
    warn "restored repository does not match its state before the conversion"
    ok=1
  fi
  set -e
  return $ok
}

manual_recovery() {
  local f links=""
  for f in "${LINKS_MADE[@]}"; do [[ -L $REPO/$f ]] && links+=" $REPO/$f"; done
  cat >&2 <<EOF
migrate_to_bare: ROLLBACK INCOMPLETE (stopped after stage $STAGE). Nothing has been deleted.
  Repository dir : $REPO
  Git dir        : $( [[ -d $BARE ]] && echo "$BARE" || echo "$REPO/.git")
  Checkout files : $( [[ -d $WT && $STAGE -ge 9 ]] && echo "$WT" || echo "$TMP")
  Worktree admin : ${ADMIN:-none}
Restore by hand, in this order, skipping steps whose source does not exist:$(
  [[ -z $links ]] || printf '\n  0. rm -f%s   (agent-config symlinks)' "$links")
  1. mv -f $ADMIN/{index,ORIG_HEAD,config.worktree,logs/HEAD} $BARE/...   (whichever exist)
  2. mv $WT $TMP ; rm -f $TMP/.git          (only if $TMP/.git is a file)
  3. rm -rf $ADMIN ; rm -f $REPO/.git      (only if $REPO/.git is a file)
  4. git --git-dir=$BARE config core.bare false ; mv $BARE $REPO/.git
  5. mv $TMP/* $TMP/.[!.]* $REPO/ ; rmdir $TMP
  6. git -C $REPO worktree repair ; git -C $REPO status
EOF
}

apply() {
  local entry name f p
  if ((${#BLOCKERS[@]})); then print_plan; exit 1; fi
  cd "$REPO"   # the repository dir itself never moves
  STAGE=0 ADMIN="" MOVED=() STATE_MOVED=() LINKS_MADE=()
  BEFORE=$(snapshot "$REPO")
  case $(git -C "$REPO" config core.fsmonitor || true) in
    ""|false) ;;
    *) git -C "$REPO" fsmonitor--daemon stop >/dev/null 2>&1 || true ;;
  esac
  trap 'fail interrupted' INT TERM

  run mkdir "$TMP"; STAGE=1
  STAGE=2
  shopt -s dotglob nullglob
  for entry in "$REPO"/*; do
    name=${entry##*/}
    [[ $name == .git || $name == "$TMP_NAME" ]] && continue
    run mv -- "$entry" "$TMP/$name"
    MOVED+=("$name")
  done
  shopt -u dotglob nullglob
  run mv "$REPO/.git" "$BARE"; STAGE=3
  run git --git-dir="$BARE" config core.bare true; STAGE=4
  printf 'gitdir: ./.bare\n' >"$REPO/.git" || fail "write $REPO/.git"; STAGE=5
  run mkdir -p "$(dirname "$WT")"
  run git --git-dir="$BARE" worktree add --quiet --no-checkout "$WT" "$BRANCH"
  ADMIN=$(sed -n 's/^gitdir: //p' "$WT/.git"); STAGE=6
  [[ $ADMIN == "$BARE"/worktrees/* ]] || fail "unexpected worktree admin dir '$ADMIN'"
  run mv "$WT/.git" "$TMP/.git"; STAGE=7
  run rmdir "$WT"; STAGE=8
  run mv "$TMP" "$WT"; STAGE=9
  STAGE=10   # per-worktree state that belonged to the old checkout
  for f in index ORIG_HEAD config.worktree logs/HEAD; do
    [[ -e $BARE/$f ]] || continue
    run mkdir -p "$(dirname "$ADMIN/$f")"
    run mv -f "$BARE/$f" "$ADMIN/$f"
    STATE_MOVED+=("$f")
  done
  STAGE=11
  if ((${#LINKED_NEW[@]})); then
    run git -C "$WT" worktree repair "${LINKED_NEW[@]}"
  fi
  git -C "$WT" update-index -q --refresh >/dev/null 2>&1 || true

  [[ $(git -C "$WT" symbolic-ref --quiet HEAD) == "refs/heads/$BRANCH" ]] || fail "verify: HEAD of $WT"
  [[ $(snapshot "$WT") == "$BEFORE" ]] || fail "verify: status/diff of $WT differ from before"
  [[ $(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir) == "$BARE" ]] ||
    fail "verify: $REPO/.git does not resolve to $BARE"
  for p in "${LINKED_NEW[@]}"; do
    [[ $(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) == "$BARE" ]] ||
      fail "verify: linked worktree $p is not connected"
  done
  STAGE=12   # agent config reachable from the container root
  for f in "${ROOT_LINKS[@]}"; do
    run ln -s "$BRANCH/$f" "$REPO/$f"
    LINKS_MADE+=("$f")
    [[ -e $REPO/$f ]] || fail "verify: symlink $REPO/$f does not resolve"
  done
  trap - INT TERM

  printf '{"migrated":true,"repo":%s,"bare_dir":%s,"source_worktree":%s,"branch":%s,"repaired_worktrees":%s,"root_links":%s}\n' \
    "$(json_str "$REPO")" "$(json_str "$BARE")" "$(json_str "$WT")" "$(json_str "$BRANCH")" \
    "$(json_list "${LINKED_NEW[@]}")" "$(root_links_json "${LINKS_MADE[@]}")"
}

main() {
  local mode=plan
  while (($#)); do
    case $1 in
      --apply) mode=apply; shift ;;
      -h|--help) awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_git
  inspect
  if [[ $mode == apply ]]; then apply; exit 0; fi
  print_plan
  ((${#BLOCKERS[@]} == 0)) || exit 1
}

main "$@"
