#!/usr/bin/env bash
# Day-to-day worktree helper for the bare-repo worktree layout (for people; the Lead uses
# worktree.sh). Run it from the container root or from any worktree inside it.
#
# Usage:
#   wt.sh list                             # git worktree list
#   wt.sh status|st [-v] [-s] [--check]    # every worktree: clean / dirty / missing, changes, upstream
#                                          #   -v all changed files, -s one line each,
#                                          #   --check exit 1 if any worktree is dirty or missing
#   wt.sh add <branch> [<base>]            # worktree at <root>/<branch>
#   wt.sh remove <branch> [--force]        # remove that worktree; the branch is kept
#   wt.sh link-config                      # (re)create the agent-config symlinks at <root>
#
# add: an existing local branch is checked out as is; a branch that only exists on origin
# gets a tracking branch; otherwise a new branch (no upstream) starts from <base>, default
# origin/<default branch> (else <default branch>). Gitignored .env / .env.* files are copied
# and .venv dirs linked from the default-branch worktree, as for spec-ops worktrees.
# link-config: agent CLIs started at <root> load CLAUDE.md, AGENTS.md, GEMINI.md, .claude/,
# .agents/, .codex/ and .gemini/ through relative symlinks into the default-branch worktree
# (migrate_to_bare.sh creates them). This adds missing ones, re-points dangling ones, removes
# those whose target is gone, and leaves real files and symlinks pointing elsewhere alone.
# Branches under so/ and so-stage/ belong to spec-ops: use worktree.sh.
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0

readonly BRANCH_PREFIX=${SO_BRANCH_PREFIX:-so/}
readonly STAGE_PREFIX=${SO_STAGE_PREFIX:-so-stage/}
# Keep in sync with migrate_to_bare.sh.
readonly AGENT_CONFIG=(CLAUDE.md AGENTS.md GEMINI.md .claude .agents .codex .gemini)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

die() { printf 'wt: %s\n' "$*" >&2; exit 2; }
warn() { printf 'wt: %s\n' "$*" >&2; }

# Populates: COMMON_DIR ROOT DEFAULT_BRANCH
locate() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
  [[ $(git -C "$COMMON_DIR" config --bool core.bare 2>/dev/null || true) == true ]] ||
    die "not a bare-repo worktree layout; convert it with: bash $SCRIPT_DIR/migrate_to_bare.sh"
  ROOT=$(dirname "$COMMON_DIR")
  DEFAULT_BRANCH=$(git -C "$COMMON_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
}

# Prints "path<TAB>branch<TAB>prunable(0|1)" for every non-bare worktree.
worktree_entries() {
  git worktree list --porcelain | awk '
    function flush() { if (path != "" && !bare) print path "\t" branch "\t" prunable }
    /^worktree / { flush(); path = substr($0, 10); branch = "(detached)"; bare = 0; prunable = 0; next }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    /^bare$/     { bare = 1; next }
    /^prunable/  { prunable = 1; next }
    END          { flush() }'
}

reserved_branch() {
  case $1 in
    "$BRANCH_PREFIX"*|"$STAGE_PREFIX"*)
      die "branch '$1' belongs to spec-ops; use worktree.sh for it" ;;
  esac
}

cmd_add() {
  local branch=${1:-} base=${2:-} target json items item
  [[ -n $branch && $# -le 2 ]] || die "usage: wt.sh add <branch> [<base>]"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name: $branch"
  reserved_branch "$branch"
  case /$branch/ in */.bare/*|*/.git/*) die "branch name '$branch' collides with the layout" ;; esac
  target="$ROOT/$branch"
  [[ ! -e $target ]] || die "target path already exists: $target"

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    [[ -z $base ]] || warn "branch '$branch' already exists; <base> ignored"
    printf 'adding %s (existing branch %s)\n' "$target" "$branch"
    git worktree add --quiet "$target" "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    [[ -z $base ]] || warn "origin/$branch exists; tracking it, <base> ignored"
    printf 'adding %s (tracking origin/%s)\n' "$target" "$branch"
    git worktree add --quiet --track -b "$branch" "$target" "origin/$branch"
  else
    if [[ -z $base ]]; then
      [[ -n $DEFAULT_BRANCH ]] || die "cannot tell the default branch; pass <base>"
      base=$DEFAULT_BRANCH
      git show-ref --verify --quiet "refs/remotes/origin/$base" && base="origin/$base"
    fi
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base ref '$base' not found"
    printf 'adding %s (new branch %s from %s)\n' "$target" "$branch" "$base"
    git worktree add --quiet --no-track -b "$branch" "$target" "$base"
  fi

  if json=$(cd "$target" && bash "$SCRIPT_DIR/worktree.sh" provision "$target"); then
    IFS=, read -ra items <<<"$(sed -n 's/.*"provisioned":\[\(.*\)\]}$/\1/p' <<<"$json")"
    for item in "${items[@]}"; do item=${item//\"/}; printf '  provisioned %s\n' "$item"; done
  else
    warn "provisioning failed; copy local files such as .env by hand"
  fi
  printf 'done: cd %s\n' "$target"
}

cmd_remove() {
  local branch="" force=0 path dirty dir
  while (($#)); do
    case $1 in
      --force) force=1; shift ;;
      -*) die "unknown argument: $1" ;;
      *) [[ -z $branch ]] || die "unexpected argument: $1"; branch=$1; shift ;;
    esac
  done
  [[ -n $branch ]] || die "usage: wt.sh remove <branch> [--force]"
  reserved_branch "$branch"
  [[ $branch != "$DEFAULT_BRANCH" ]] || die "refusing to remove the default-branch worktree ($branch)"
  path=$(worktree_entries | awk -F'\t' -v b="$branch" '$2 == b { print $1; exit }')
  [[ -n $path ]] || die "no worktree on branch '$branch'"

  if [[ ! -d $path ]]; then
    git worktree prune
    printf 'worktree %s was already gone; pruned its entry\n' "$path"
    return 0
  fi
  dirty=$(git -C "$path" status --porcelain)
  if [[ -n $dirty && $force -eq 0 ]]; then
    printf '%s\n' "$dirty" >&2
    die "worktree has uncommitted changes: $path (re-run with --force to discard)"
  fi
  if ((force)); then git worktree remove --force "$path"; else git worktree remove "$path"; fi
  dir=$(dirname "$path")   # drop dirs left empty by a/b branch names
  while [[ $dir == "$ROOT"/* ]] && rmdir "$dir" 2>/dev/null; do dir=$(dirname "$dir"); done
  git worktree prune
  printf 'removed %s (branch %s kept; delete it with: git branch -d %s)\n' "$path" "$branch" "$branch"
}

cmd_link_config() {
  local wt base name dest want cur changed=0
  (($# == 0)) || die "usage: wt.sh link-config"
  [[ -n $DEFAULT_BRANCH ]] || die "cannot tell the default branch"
  wt=$(worktree_entries | awk -F'\t' -v b="$DEFAULT_BRANCH" '$2 == b { print $1; exit }')
  [[ -n $wt && -d $wt ]] || die "no worktree on the default branch '$DEFAULT_BRANCH'"
  if [[ $wt == "$ROOT"/* ]]; then base=${wt#"$ROOT"/}; else base=$wt; fi
  for name in "${AGENT_CONFIG[@]}"; do
    dest=$ROOT/$name want=$base/$name cur=""
    [[ -L $dest ]] && cur=$(readlink "$dest")
    if [[ -e $wt/$name || -L $wt/$name ]]; then
      if [[ -L $dest && $cur == "$want" ]]; then
        continue
      elif [[ -L $dest && -e $dest ]]; then
        warn "$name points to $cur, not $want; left as is"
      elif [[ -L $dest ]]; then
        ln -sfn "$want" "$dest"; printf 're-pointed %s -> %s (was %s)\n' "$name" "$want" "$cur"; changed=1
      elif [[ -e $dest ]]; then
        warn "$dest exists and is not a symlink; left as is"
      else
        ln -s "$want" "$dest"; printf 'linked %s -> %s\n' "$name" "$want"; changed=1
      fi
    elif [[ -L $dest && ( $cur == "$want" || ! -e $dest ) ]]; then
      rm -f "$dest"; printf 'removed %s (%s has none)\n' "$name" "$DEFAULT_BRANCH"; changed=1
    fi
  done
  ((changed)) || printf 'agent-config symlinks at %s are up to date\n' "$ROOT"
}

cmd_status() {
  local verbose=0 short=0 check=0 total=0 clean=0 dirty=0 missing=0
  local path branch prunable rel head upstream counts ahead behind summary limit=10 i
  local C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
  while (($#)); do
    case $1 in
      -v|--verbose) verbose=1 ;;
      -s|--short) short=1 ;;
      --check) check=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see wt.sh --help)" ;;
    esac
    shift
  done
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
  fi

  while IFS=$'\t' read -r path branch prunable; do
    total=$((total + 1))
    rel=${path#"$ROOT"/}
    if ((prunable)) || [[ ! -d $path ]]; then
      missing=$((missing + 1))
      if ((short)); then printf '%sMISSING%s %s [%s%s%s]\n' "$C_RED" "$C_RESET" "$rel" "$C_CYAN" "$branch" "$C_RESET"
      else printf '%s%s%s [%s%s%s]\n   %sMISSING (directory does not exist; git worktree prune drops it)%s\n\n' \
        "$C_BOLD" "$rel" "$C_RESET" "$C_CYAN" "$branch" "$C_RESET" "$C_RED" "$C_RESET"
      fi
      continue
    fi

    head=$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)
    if counts=$(git -C "$path" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null); then
      read -r ahead behind <<<"$counts"
      if ((ahead == 0 && behind == 0)); then upstream="${C_GREEN}in sync with upstream${C_RESET}"
      elif ((ahead && behind)); then upstream="${C_YELLOW}ahead $ahead, behind $behind${C_RESET}"
      elif ((ahead)); then upstream="${C_BLUE}ahead $ahead${C_RESET}"
      else upstream="${C_YELLOW}behind $behind${C_RESET}"
      fi
    else
      upstream="${C_DIM}no upstream${C_RESET}"
    fi

    local -a changes=()
    local staged=0 unstaged=0 untracked=0 conflicts=0 line xy file
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      xy=${line:0:2} file=${line:3}
      case $xy in
        DD|AU|UD|UA|DU|AA|UU) conflicts=$((conflicts + 1)); changes+=("${C_RED}[conflict]  $file${C_RESET}") ;;
        '??') untracked=$((untracked + 1)); changes+=("${C_DIM}[untracked] $file${C_RESET}") ;;
        *)
          [[ ${xy:0:1} != " " ]] && staged=$((staged + 1))
          [[ ${xy:1:1} != " " ]] && unstaged=$((unstaged + 1))
          if [[ ${xy:0:1} != " " && ${xy:1:1} != " " ]]; then changes+=("${C_YELLOW}[staged+unstaged] $file${C_RESET}")
          elif [[ ${xy:0:1} != " " ]]; then changes+=("${C_GREEN}[staged]    $file${C_RESET}")
          else changes+=("${C_RED}[unstaged]  $file${C_RESET}")
          fi ;;
      esac
    done < <(git -C "$path" status --porcelain=v1)

    if ((${#changes[@]} == 0)); then
      clean=$((clean + 1))
      if ((short)); then printf '%sCLEAN%s   %s [%s%s%s] (%s) | %s\n' "$C_GREEN" "$C_RESET" "$rel" "$C_CYAN" "$branch" "$C_RESET" "$head" "$upstream"
      else printf '%s%s%s [%s%s%s] (%s%s%s)\n   %sCLEAN%s | %s\n\n' "$C_BOLD" "$rel" "$C_RESET" "$C_CYAN" "$branch" "$C_RESET" \
        "$C_DIM" "$head" "$C_RESET" "$C_GREEN" "$C_RESET" "$upstream"
      fi
      continue
    fi

    dirty=$((dirty + 1))
    summary=""
    ((staged)) && summary+="${summary:+, }staged $staged"
    ((unstaged)) && summary+="${summary:+, }unstaged $unstaged"
    ((untracked)) && summary+="${summary:+, }untracked $untracked"
    ((conflicts)) && summary+="${summary:+, }conflicts $conflicts"
    if ((short)); then
      printf '%sDIRTY%s   %s [%s%s%s] (%s) (%s) | %s\n' "$C_YELLOW" "$C_RESET" "$rel" "$C_CYAN" "$branch" "$C_RESET" "$head" "$summary" "$upstream"
      continue
    fi
    printf '%s%s%s [%s%s%s] (%s%s%s)\n   %sDIRTY (%s)%s | %s\n' "$C_BOLD" "$rel" "$C_RESET" "$C_CYAN" "$branch" "$C_RESET" \
      "$C_DIM" "$head" "$C_RESET" "$C_YELLOW" "$summary" "$C_RESET" "$upstream"
    for i in "${!changes[@]}"; do
      if ((!verbose && i >= limit)); then
        printf '     %s... %d more (-v shows all)%s\n' "$C_DIM" $((${#changes[@]} - limit)) "$C_RESET"
        break
      fi
      printf '     %s\n' "${changes[$i]}"
    done
    printf '\n'
  done < <(worktree_entries)

  printf '%s%s: %d worktree(s) | clean %d | dirty %d | missing %d%s\n' \
    "$C_BOLD" "$ROOT" "$total" "$clean" "$dirty" "$missing" "$C_RESET"
  ((check == 0 || dirty + missing == 0)) || exit 1
}

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

main() {
  local cmd=${1:-}
  shift || true
  case $cmd in
    ""|-h|--help|help) usage; [[ -n $cmd ]] || exit 2; exit 0 ;;
  esac
  locate
  case $cmd in
    list) git worktree list ;;
    status|st) cmd_status "$@" ;;
    add) cmd_add "$@" ;;
    remove|rm) cmd_remove "$@" ;;
    link-config) cmd_link_config "$@" ;;
    *) die "unknown command: $cmd (see wt.sh --help)" ;;
  esac
}

main "$@"
