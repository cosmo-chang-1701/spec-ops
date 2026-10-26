#!/usr/bin/env bash
# Scope gate: verify every file the Worker touched is covered by the whitelist.
#
# Usage:
#   check_scope.sh <worktree> <whitelist-file> [--base <ref>]   gate (default mode)
#   check_scope.sh --list <dir> <whitelist-file>                 tracked files the whitelist covers
#   check_scope.sh --overlap <dir> <whitelist-file>...           files/patterns shared by 2+ whitelists
#
# Gate: changed set = committed since base  ∪  staged/unstaged vs HEAD  ∪  untracked.
# Renames count as delete + add, so both paths must be allowed.
# Base defaults to the fork point recorded by `worktree.sh create`.
#
# --list / --overlap are read-only spec-time checks against the tracked files of <dir>
# (e.g. source_worktree). --overlap prints OVERLAP for tracked files in 2+ whitelists and
# POSSIBLE for allow patterns of different whitelists that could match the same new file.
#
# Whitelist format (one pattern per line, paths relative to repo root):
#   src/auth/**          # ** spans directories
#   src/auth/*.ts        # *  stays within one directory
#   tests/auth/          # trailing / means the whole directory
#   !src/auth/secrets.ts # leading ! forbids, overriding positive matches
#   # comments and blank lines are ignored
#
# Exit: 0 = all in scope / no overlap, 1 = violations / OVERLAP found (listed on stdout),
#       2 = usage error.
set -euo pipefail

readonly REGEX_SPECIALS='.[]\^$+(){}|'

die() { printf 'check_scope: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,25p' "$0" >&2; exit 2; }

# Glob -> anchored ERE. `**/` = zero or more dirs, `**` = anything, `*` / `?` stay in one segment.
glob_to_regex() {
  local glob=$1 out="" i c next
  [[ $glob == */ ]] && glob+="**"
  for ((i = 0; i < ${#glob}; i++)); do
    c=${glob:i:1} next=${glob:i+1:1}
    if [[ $c == "*" && $next == "*" ]]; then
      if [[ ${glob:i+2:1} == "/" ]]; then out+="(.*/)?"; ((i += 2)); else out+=".*"; ((i += 1)); fi
    elif [[ $c == "*" ]]; then out+="[^/]*"
    elif [[ $c == "?" ]]; then out+="[^/]"
    elif [[ $REGEX_SPECIALS == *"$c"* ]]; then out+="\\$c"
    else out+=$c
    fi
  done
  printf '^%s$' "$out"
}

# load_whitelist <file>: sets allow/deny (regexes) and allow_globs (raw allow patterns).
load_whitelist() {
  local line
  [[ -r $1 ]] || die "whitelist not readable: $1"
  allow=() deny=() allow_globs=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    [[ -z $line ]] && continue
    if [[ $line == !* ]]; then
      deny+=("$(glob_to_regex "${line#!}")")
    else
      allow+=("$(glob_to_regex "$line")"); allow_globs+=("$line")
    fi
  done <"$1"
  ((${#allow[@]})) || die "whitelist has no allow patterns: $1"
}

# Tracked files of <dir> matched by the loaded whitelist.
tracked_in_scope() {
  git -C "$1" -c core.quotePath=false ls-files |
    { grep -E -f <(printf '%s\n' "${allow[@]}") || true; } |
    if ((${#deny[@]})); then { grep -v -E -f <(printf '%s\n' "${deny[@]}") || true; }; else cat; fi
}

# Could two allow patterns match the same path? Literal paths are tested against the other
# pattern; two wildcard patterns overlap when one literal prefix extends the other.
may_overlap() {
  local a=$1 b=$2 pa pb
  pa=${a%%[*?]*} pb=${b%%[*?]*}
  if [[ $pa == "$a" && $a != */ ]]; then [[ $a =~ $(glob_to_regex "$b") ]]; return; fi
  if [[ $pb == "$b" && $b != */ ]]; then [[ $b =~ $(glob_to_regex "$a") ]]; return; fi
  [[ $pa == "$pb"* || $pb == "$pa"* ]]
}

require_worktree() {
  [[ -d $1 ]] || die "directory not found: $1"
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git work tree: $1"
}

list_mode() {
  (($# == 2)) || usage
  require_worktree "$1"
  load_whitelist "$2"
  local n=0 file
  while IFS= read -r file; do printf '%s\n' "$file"; ((n += 1)); done < <(tracked_in_scope "$1")
  printf '%d tracked file(s) in scope\n' "$n" >&2
}

overlap_mode() {
  (($# >= 2)) || usage
  local dir=$1; shift
  require_worktree "$dir"
  local -A owners=() count=()
  local -a globs=() globs_wl=()
  local wl file g i j overlaps=0 possible=0
  for wl in "$@"; do
    load_whitelist "$wl"
    while IFS= read -r file; do
      owners[$file]+="${owners[$file]:+, }$wl"; count[$file]=$((${count[$file]:-0} + 1))
    done < <(tracked_in_scope "$dir")
    for g in "${allow_globs[@]}"; do globs+=("$g"); globs_wl+=("$wl"); done
  done
  local -a shared=()
  for file in "${!count[@]}"; do
    if [[ ${count[$file]} -gt 1 ]]; then shared+=("OVERLAP   $file  (${owners[$file]})"); fi
  done
  overlaps=${#shared[@]}
  ((overlaps == 0)) || printf '%s\n' "${shared[@]}" | LC_ALL=C sort
  for ((i = 0; i < ${#globs[@]}; i++)); do
    for ((j = i + 1; j < ${#globs[@]}; j++)); do
      [[ ${globs_wl[i]} == "${globs_wl[j]}" ]] && continue
      if may_overlap "${globs[i]}" "${globs[j]}"; then
        printf 'POSSIBLE  %s (%s) ~ %s (%s)\n' "${globs[i]}" "${globs_wl[i]}" "${globs[j]}" "${globs_wl[j]}"
        ((possible += 1))
      fi
    done
  done
  printf '\n%d tracked file(s) in 2+ whitelists, %d possible pattern overlap(s)\n' "$overlaps" "$possible"
  ((overlaps == 0))
}

(($# >= 1)) || usage
case $1 in
  --list) shift; list_mode "$@"; exit ;;
  --overlap) shift; overlap_mode "$@"; exit ;;
esac

(($# >= 2)) || usage
worktree=$1 whitelist=$2; shift 2
base=""
while (($#)); do
  case $1 in
    --base) [[ $# -ge 2 ]] || die "--base needs a value"; base=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -d $worktree ]] || die "worktree not found: $worktree"
[[ -r $whitelist ]] || die "whitelist not readable: $whitelist"
git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || die "not a git worktree: $worktree"

if [[ -z $base ]]; then
  base_file="$(git -C "$worktree" rev-parse --absolute-git-dir)/so-base"
  [[ -r $base_file ]] || die "no recorded base; pass --base <ref>"
  base=$(<"$base_file")
fi
git -C "$worktree" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base '$base' not found"

load_whitelist "$whitelist"

mapfile -t changed < <(
  {
    git -C "$worktree" diff --name-only --no-renames "$base" HEAD
    git -C "$worktree" diff --name-only --no-renames HEAD
    git -C "$worktree" ls-files --others --exclude-standard
  } | sort -u
)

violations=0
for file in "${changed[@]}"; do
  [[ -z $file ]] && continue
  ok=0
  for re in "${allow[@]}"; do [[ $file =~ $re ]] && { ok=1; break; }; done
  for re in "${deny[@]}"; do [[ $file =~ $re ]] && { ok=0; break; }; done
  if ((ok)); then printf 'IN-SCOPE   %s\n' "$file"; else printf 'VIOLATION  %s\n' "$file"; ((violations += 1)); fi
done

printf '\n%d changed file(s), %d violation(s) (base %s)\n' "${#changed[@]}" "$violations" "${base:0:12}"
((violations == 0))
