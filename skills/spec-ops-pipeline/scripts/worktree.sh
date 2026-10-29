#!/usr/bin/env bash
# Worktree lifecycle for Lead-Worker tasks. Adapts to the repo's layout.
#
# Usage:
#   worktree.sh config                        # effective repo config + resolved layout (JSON)
#   worktree.sh path   <slug>                 # resolve target path (JSON), no side effects
#   worktree.sh create <slug> [--base <ref>]  # add worktree on branch ${SOP_BRANCH_PREFIX:-sop/}<slug>
#   worktree.sh integrate <id> --base <ref> <branch>...
#                                             # stage integration worktree on ${SOP_STAGE_PREFIX:-sop-stage/}<id>:
#                                             # merges each branch (--no-ff) onto base; exit 1 on conflict
#   worktree.sh remove <slug> [--force]       # remove worktree; delete branch only if merged
#   worktree.sh remove --stage <id> [--force] # same, for a stage integration worktree
#   worktree.sh list                          # list task + stage worktrees (JSON lines, "kind")
#   worktree.sh status [--check]              # list + state, base, ahead, change counts (JSON lines);
#                                             # --check exits 1 if any is dirty or missing
#   worktree.sh provision <worktree>          # provision an existing worktree (see below)
#   worktree.sh rundir [--archive]            # persistent run dir <git common dir>/sop-run (JSON);
#                                             # --archive renames it to sop-run.<UTC timestamp>
#
# Built-in defaults per layout (no config needed):
#   Bare container (<root>/.bare + <root>/<branch>/ worktrees, e.g. <root>/main):
#     worktree dir = branch name: <root>/sop/<slug>, stages <root>/sop-stage/<id>
#     source worktree = the one on the default branch (bare HEAD, e.g. main/)
#     default base    = origin/<default branch> if it exists, else <default branch>
#   Standard repo (.git inside the main checkout):
#     <parent>/worktrees/<repo>/<slug>, stages .../_stage-<id>; source = main checkout;
#     default base = HEAD
#   Both: every new task/stage worktree is provisioned from the source worktree with its
#     gitignored, untracked `.env` / `.env.*` files (copied, mode kept) and `.venv` dirs
#     (symlinked). Disable with SOP_PROVISION=0. Paths not gitignored in the new
#     worktree are skipped, so they never show up as changes or get committed.
#
# Optional overrides — .agents/spec-ops-pipeline.json, first readable file wins:
#   SOP_CONFIG env  →  <toplevel>/.agents/spec-ops-pipeline.json  →  (bare layout only)
#   <default-branch worktree>/.agents/spec-ops-pipeline.json  →  <bare repo's parent>/.agents/spec-ops-pipeline.json
# Keys: worktreeRoot (env SOP_WORKTREE_ROOT wins; relative to the layout anchor),
#   pathStyle ("slug" | "branch"), defaultBase, sourceWorktree (relative to the anchor),
#   provision ({"copy": [...], "link": [...], "copyMode": "644"} replaces auto-discovery),
#   maxParallel (Worker cap read by the Lead, default 4), workerNotes (extra Worker rules),
#   offerBareLayout (false = never offer migrate_to_bare.sh on a standard repo),
#   autoMergeRisk (risk levels whose PRs the Lead merges once open and APPROVEd, a subset of
#   ["L", "M", "H"], default ["L", "M"]; env SOP_AUTO_MERGE_RISK="L,M" or "none"),
#   mergeMethod ("squash" | "merge" | "rebase", default "squash"; env SOP_MERGE_METHOD).
#   Deprecated: autoMerge / SOP_AUTO_MERGE ("manual" = none, "low-risk" = L, "all" = L,M,H),
#   used only where autoMergeRisk / SOP_AUTO_MERGE_RISK is not set.
#
# User config — defaults for every repo, overridden key by key by the repo config:
#   SOP_USER_CONFIG env, else ${XDG_CONFIG_HOME:-~/.config}/spec-ops-pipeline/config.json.
#   Only the repo-independent keys are read from it: maxParallel, workerNotes,
#   offerBareLayout, autoMergeRisk (or autoMerge), mergeMethod.
#
# Target root resolution (first hit wins):
#   1. SOP_WORKTREE_ROOT env, or "worktreeRoot" in the repo config
#   2. Bare layout: $(dirname COMMON_DIR)
#   3. Existing linked worktrees: if all share one root, reuse it ("branch" style strips
#      the branch name from each path, "slug" style takes the parent dir).
#      Tool-managed ones (nested inside the main checkout, e.g. .claude/worktrees,
#      or under a dot-dir in $HOME, e.g. ~/.gemini/...) are ignored.
#   4. Standard layout: $(dirname MAIN_WORKTREE)/worktrees/<repo>
#
# The fork-point commit is saved to <worktree git dir>/sop-base so check_scope.sh
# can diff against it later.
#
# Before removing a worktree, `remove` runs `docker compose down` (volumes kept) for each
# Compose project whose containers were all started from inside it, e.g. the dependency
# services `docker compose run` leaves behind. A project that also has containers started
# elsewhere (a name shared with the main checkout) is left running. Disable with
# SOP_COMPOSE_DOWN=0; without docker or a reachable daemon this step is skipped.
set -euo pipefail

readonly BRANCH_PREFIX=${SOP_BRANCH_PREFIX:-sop/}
readonly STAGE_PREFIX=${SOP_STAGE_PREFIX:-sop-stage/}
readonly CONFIG_REL=.agents/spec-ops-pipeline.json
readonly MIN_GIT_MAJOR=2 MIN_GIT_MINOR=31   # --path-format=absolute

die() { printf 'worktree: %s\n' "$*" >&2; exit 2; }
warn() { printf 'worktree: %s\n' "$*" >&2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
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

validate_slug() {
  [[ ${1:-} =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid slug '${1:-}' (use lowercase kebab-case)"
}

# Resolves a config path value: ~ expansion, relative → anchor.
anchor_path() {
  local p=${1/#\~/$HOME}
  [[ $p == /* ]] || p="$ANCHOR_DIR/$p"
  realpath -m "$p"
}

# Populates: CONFIG_FILE
find_config() {
  local toplevel candidate
  local -a candidates=()
  CONFIG_FILE=""
  if [[ -n ${SOP_CONFIG:-} ]]; then
    [[ -r $SOP_CONFIG ]] || die "SOP_CONFIG is not readable: $SOP_CONFIG"
    CONFIG_FILE=$SOP_CONFIG
    return
  fi
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n $toplevel ]] && candidates+=("$toplevel/$CONFIG_REL")
  if [[ $LAYOUT == bare ]]; then
    # From the container root there is no toplevel; the repo's own copy lives in the
    # default-branch worktree. Only a bare layout owns its parent dir (a standard repo's
    # parent may hold other repos).
    [[ -n $DEFAULT_BRANCH ]] && toplevel=$(worktree_on_branch "$DEFAULT_BRANCH")
    [[ -n $toplevel ]] && candidates+=("$toplevel/$CONFIG_REL")
    candidates+=("$ANCHOR_DIR/$CONFIG_REL")
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -r $candidate ]]; then CONFIG_FILE=$candidate; return; fi
  done
}

# Prints the user config path if one is readable (see the header).
find_user_config() {
  if [[ -n ${SOP_USER_CONFIG:-} ]]; then
    [[ -r $SOP_USER_CONFIG ]] || die "SOP_USER_CONFIG is not readable: $SOP_USER_CONFIG"
    printf '%s' "$SOP_USER_CONFIG"
    return
  fi
  local path=${XDG_CONFIG_HOME:-$HOME/.config}/spec-ops-pipeline/config.json
  [[ -r $path ]] && printf '%s' "$path"
  return 0
}

# cfg <dotted.key>: prints a scalar, or one line per list item; nothing if unset.
cfg() {
  [[ -n $CONFIG_FILE ]] || return 0
  command -v python3 >/dev/null || die "python3 is required to read $CONFIG_FILE"
  python3 - "$CONFIG_FILE" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node.get(part) if isinstance(node, dict) else None
if node is None:
    sys.exit(0)
for item in node if isinstance(node, list) else [node]:
    print(str(item).lower() if isinstance(item, bool) else item)
PY
}

# cfg_has <key>: succeeds if the repo config sets the top-level key (even to an empty value).
cfg_has() {
  [[ -n $CONFIG_FILE ]] || return 1
  command -v python3 >/dev/null || die "python3 is required to read $CONFIG_FILE"
  python3 -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' \
    "$CONFIG_FILE" "$1"
}

# Prints the path of the worktree checked out on branch $1 (bare entry excluded).
worktree_on_branch() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree / { path = substr($0, 10); next }
    /^branch /   { if (substr($0, 8) == b) { print path; exit } }'
}

# Populates: COMMON_DIR LAYOUT MAIN_WORKTREE ANCHOR_DIR REPO_NAME DEFAULT_BRANCH
#            CONFIG_FILE PATH_STYLE DEFAULT_BASE SOURCE_WORKTREE
inspect_repo() {
  local source
  COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
  DEFAULT_BRANCH=""
  if [[ $(git -C "$COMMON_DIR" config --bool core.bare 2>/dev/null || true) == true ]]; then
    LAYOUT=bare
    MAIN_WORKTREE=""
    ANCHOR_DIR=$(dirname "$COMMON_DIR")
    case $(basename "$COMMON_DIR") in
      .bare|.git) REPO_NAME=$(basename "$ANCHOR_DIR") ;;
      *)          REPO_NAME=$(basename "$COMMON_DIR" .git) ;;
    esac
    DEFAULT_BRANCH=$(git -C "$COMMON_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  else
    LAYOUT=standard
    # The first `worktree list` entry is always the main worktree, even when
    # called from inside a linked worktree (where --show-toplevel would lie).
    MAIN_WORKTREE=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')
    ANCHOR_DIR=$(dirname "$MAIN_WORKTREE")
    REPO_NAME=$(basename "$MAIN_WORKTREE")
  fi

  find_config
  PATH_STYLE=$(cfg pathStyle)
  if [[ -z $PATH_STYLE ]]; then
    if [[ $LAYOUT == bare ]]; then PATH_STYLE=branch; else PATH_STYLE=slug; fi
  fi
  [[ $PATH_STYLE == slug || $PATH_STYLE == branch ]] ||
    die "pathStyle must be \"slug\" or \"branch\" (got '$PATH_STYLE' in $CONFIG_FILE)"

  DEFAULT_BASE=$(cfg defaultBase)
  if [[ -z $DEFAULT_BASE ]]; then
    if [[ -z $DEFAULT_BRANCH ]]; then DEFAULT_BASE=HEAD
    elif git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
      DEFAULT_BASE="origin/$DEFAULT_BRANCH"
    else DEFAULT_BASE=$DEFAULT_BRANCH
    fi
  fi

  source=$(cfg sourceWorktree)
  if [[ -n $source ]]; then SOURCE_WORKTREE=$(anchor_path "$source")
  elif [[ $LAYOUT == standard ]]; then SOURCE_WORKTREE=$MAIN_WORKTREE
  else
    SOURCE_WORKTREE=""
    [[ -n $DEFAULT_BRANCH ]] && SOURCE_WORKTREE=$(worktree_on_branch "$DEFAULT_BRANCH")
    if [[ -z $SOURCE_WORKTREE && -n $DEFAULT_BRANCH && -d $ANCHOR_DIR/$DEFAULT_BRANCH ]]; then
      SOURCE_WORKTREE="$ANCHOR_DIR/$DEFAULT_BRANCH"
    fi
  fi
}

# Prints "path<TAB>branch<TAB>prunable(0|1)" for each linked (non-main, non-bare) worktree.
worktree_entries() {
  git worktree list --porcelain | awk '
    function flush() { if (n > 1 && path != "" && !bare) print path "\t" branch "\t" prunable }
    /^worktree / { flush(); n++; path = substr($0, 10); branch = ""; bare = 0; prunable = 0; next }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    /^bare$/     { bare = 1; next }
    /^prunable/  { prunable = 1; next }
    END          { flush() }'
}

# Prints "path<TAB>branch" for each linked, non-prunable worktree.
linked_worktrees() {
  worktree_entries | awk -F'\t' '$3 == 0 { print $1 "\t" $2 }'
}

configured_root() {
  local root=${SOP_WORKTREE_ROOT:-}
  [[ -n $root ]] || root=$(cfg worktreeRoot)
  [[ -n $root ]] || return 1
  anchor_path "$root"
}

is_tool_managed() {
  # Nested inside the main checkout (e.g. <repo>/.claude/worktrees) or under a
  # dot-dir in $HOME (e.g. ~/.gemini/antigravity-cli/worktrees).
  [[ -n $MAIN_WORKTREE && $1 == "$MAIN_WORKTREE"/* ]] || [[ $1 =~ ^$HOME/\.[^/]+/ ]]
}

existing_parent() {
  local roots path branch
  roots=$(linked_worktrees | while IFS=$'\t' read -r path branch; do
    is_tool_managed "$path" && continue
    if [[ $PATH_STYLE == branch && -n $branch && $path == */"$branch" ]]; then
      printf '%s\n' "${path%/"$branch"}"
    else
      dirname "$path"
    fi
  done | sort -u)
  [[ -n $roots && $(wc -l <<<"$roots") -eq 1 ]] || return 1
  printf '%s' "$roots"
}

# Populates: ROOT_DIR RESOLVED_BY
resolve_root() {
  local root
  if root=$(configured_root); then
    ROOT_DIR=$root RESOLVED_BY=config
  elif [[ $LAYOUT == bare ]]; then
    ROOT_DIR=$ANCHOR_DIR RESOLVED_BY=bare-layout
  elif root=$(existing_parent); then
    ROOT_DIR=$root RESOLVED_BY=existing-worktrees
  else
    ROOT_DIR="$ANCHOR_DIR/worktrees/$REPO_NAME" RESOLVED_BY=standard-layout
  fi
}

# resolve_path task|stage <name>  →  Populates: WORKTREE_PATH ROOT_DIR RESOLVED_BY
resolve_path() {
  local kind=$1 name=$2 rel
  resolve_root
  if [[ $PATH_STYLE == branch ]]; then
    if [[ $kind == stage ]]; then rel="$STAGE_PREFIX$name"; else rel="$BRANCH_PREFIX$name"; fi
  else
    if [[ $kind == stage ]]; then rel="_stage-$name"; else rel=$name; fi
  fi
  WORKTREE_PATH=$(realpath -m "$ROOT_DIR/$rel")
}

find_task_worktree() {
  # Prints the path of the worktree checked out on the task branch.
  linked_worktrees | awk -F'\t' -v b="$1" '$2 == b {print $1; exit}'
}

# Populates: COPIES LINKS COPY_MODE PROVISION_FROM (config | auto | disabled | no-source)
provision_lists() {
  local rel name
  COPIES=() LINKS=() COPY_MODE=""
  if cfg_has provision; then
    PROVISION_FROM=config
    mapfile -t COPIES < <(cfg provision.copy)
    mapfile -t LINKS < <(cfg provision.link)
    COPY_MODE=$(cfg provision.copyMode)
  elif [[ ${SOP_PROVISION:-1} == 0 ]]; then
    PROVISION_FROM=disabled
    return 0
  else
    PROVISION_FROM=auto
    [[ -n $SOURCE_WORKTREE && -d $SOURCE_WORKTREE ]] || return 0
    # Ignored, untracked paths; --directory collapses ignored dirs (so .venv is one entry).
    while IFS= read -r rel; do
      rel=${rel%/} name=${rel##*/}
      case $name in
        .venv)       [[ -d $SOURCE_WORKTREE/$rel ]] && LINKS+=("$rel") ;;
        .env|.env.*) [[ -f $SOURCE_WORKTREE/$rel ]] && COPIES+=("$rel") ;;
      esac
    done < <(git -C "$SOURCE_WORKTREE" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)
  fi
  if [[ -z $SOURCE_WORKTREE || ! -d $SOURCE_WORKTREE ]] && ((${#COPIES[@]} + ${#LINKS[@]})); then
    PROVISION_FROM=no-source
  fi
  return 0
}

# provision <worktree>: copy / symlink gitignored local files from the source worktree.
# Populates: PROVISIONED (JSON array body)
provision() {
  local wt=$1 rel
  PROVISIONED=""
  provision_lists
  if [[ $PROVISION_FROM == no-source ]]; then
    warn "provision skipped: no source worktree found (set \"sourceWorktree\" in .agents/spec-ops-pipeline.json)"
    return 0
  fi
  for rel in "${COPIES[@]}"; do [[ -n $rel ]] && provision_one copy "$wt" "$rel" "$COPY_MODE"; done
  for rel in "${LINKS[@]}"; do [[ -n $rel ]] && provision_one link "$wt" "$rel" ""; done
  return 0
}

provision_one() {
  local how=$1 wt=$2 rel=$3 mode=$4 src dest
  [[ $rel != /* && /$rel/ != */../* ]] || die "provision path must be repo-relative: $rel"
  src="$SOURCE_WORKTREE/$rel" dest="$wt/$rel"
  if [[ ! -e $src ]]; then warn "provision: $src not found, skipped"; return 0; fi
  if [[ -e $dest || -L $dest ]]; then warn "provision: $rel already exists, left as is"; return 0; fi
  if ! git -C "$wt" check-ignore -q "$rel"; then
    warn "provision: $rel is not gitignored in $wt, skipped"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  case $how in
    copy) cp -pR "$src" "$dest"; [[ -z $mode ]] || chmod "$mode" "$dest" ;;
    link) ln -s "$src" "$dest" ;;
  esac
  PROVISIONED+="${PROVISIONED:+,}\"$(json_escape "$how:$rel")\""
}

# Removes directories left empty between a removed worktree and the root ("branch" style).
prune_empty_parents() {
  local dir
  dir=$(dirname "$1")
  resolve_root
  while [[ $dir == "$ROOT_DIR"/* ]] && rmdir "$dir" 2>/dev/null; do
    dir=$(dirname "$dir")
  done
}

# compose_down <worktree>: stops Compose projects started only from inside the worktree.
compose_down() {
  local wt=$1 rows project dir
  [[ ${SOP_COMPOSE_DOWN:-1} != 0 ]] && command -v docker >/dev/null || return 0
  rows=$(docker ps -a --filter label=com.docker.compose.project \
    --format '{{.Label "com.docker.compose.project"}}{{"\t"}}{{.Label "com.docker.compose.project.working_dir"}}' \
    2>/dev/null) || return 0
  # "project<TAB>1" if the container's working dir is inside the worktree, else "project<TAB>0".
  rows=$(awk -F'\t' -v wt="$wt" '$1 != "" { print $1 "\t" ($2 == wt || index($2, wt "/") == 1) "\t" $2 }' <<<"$rows")
  while IFS= read -r project; do
    [[ -n $project ]] || continue
    if awk -F'\t' -v p="$project" '$1 == p && $2 == 0 { found = 1 } END { exit !found }' <<<"$rows"; then
      warn "compose project '$project' also has containers outside $wt; left running"
      continue
    fi
    dir=$(awk -F'\t' -v p="$project" '$1 == p { print $3; exit }' <<<"$rows")
    if (cd "$dir" && docker compose -p "$project" down) >&2; then
      printf 'stopped compose project: %s\n' "$project" >&2
    else
      warn "docker compose down failed for project '$project'; removing the worktree anyway"
    fi
  done < <(awk -F'\t' '$2 == 1 { print $1 }' <<<"$rows" | sort -u)
}

emit_json() {
  printf '{"layout":"%s","repo":"%s","common_dir":"%s","main_worktree":"%s","worktree_path":"%s","branch":"%s","resolved_by":"%s","path_style":"%s"%s}\n' \
    "$LAYOUT" "$(json_escape "$REPO_NAME")" "$(json_escape "$COMMON_DIR")" "$(json_escape "$MAIN_WORKTREE")" \
    "$(json_escape "$WORKTREE_PATH")" "$(json_escape "$1")" "$RESOLVED_BY" "$PATH_STYLE" "${2:-}"
}

cmd_config() {
  command -v python3 >/dev/null || die "python3 is required"
  resolve_root
  provision_lists
  local user_config
  user_config=$(find_user_config)
  python3 - "$CONFIG_FILE" "$LAYOUT" "$REPO_NAME" "$ANCHOR_DIR" "$MAIN_WORKTREE" \
    "$SOURCE_WORKTREE" "$ROOT_DIR" "$RESOLVED_BY" "$PATH_STYLE" "$DEFAULT_BRANCH" \
    "$DEFAULT_BASE" "$BRANCH_PREFIX" "$STAGE_PREFIX" "$PROVISION_FROM" "$COPY_MODE" \
    "$(printf '%s\n' "${COPIES[@]}")" "$(printf '%s\n' "${LINKS[@]}")" \
    "$user_config" "${SOP_AUTO_MERGE_RISK:-}" "${SOP_AUTO_MERGE:-}" "${SOP_MERGE_METHOD:-}" <<'PY'
import json, sys
(config, layout, repo, anchor, main_wt, source, root, resolved_by, path_style,
 default_branch, default_base, branch_prefix, stage_prefix, provision_from, copy_mode,
 copies, links, user_config, env_auto_merge_risk, env_auto_merge,
 env_merge_method) = sys.argv[1:22]
RISKS = ("L", "M", "H")
LEGACY_AUTO_MERGE = {"manual": [], "low-risk": ["L"], "all": list(RISKS)}
USER_KEYS = ("maxParallel", "workerNotes", "offerBareLayout", "autoMergeRisk", "mergeMethod")

def fail(message):
    print(f"worktree: {message}", file=sys.stderr)
    sys.exit(2)

def legacy_auto_merge(value, where):
    if value not in LEGACY_AUTO_MERGE:
        fail(f"autoMerge must be one of: {' '.join(LEGACY_AUTO_MERGE)} (got '{value}' from {where})")
    return LEGACY_AUTO_MERGE[value]

def load(path):
    layer = json.load(open(path)) if path else {}
    if "autoMerge" in layer and "autoMergeRisk" not in layer:
        layer["autoMergeRisk"] = legacy_auto_merge(layer["autoMerge"], f"autoMerge in {path}")
    return layer

# The repo config wins key by key; the user config only fills in USER_KEYS.
data, origin = load(config), {}
origin.update((key, config) for key in data)
for key, value in load(user_config).items():
    if key in USER_KEYS and key not in data:
        data[key], origin[key] = value, user_config

def choice(key, env_name, env_value, allowed, default):
    value = env_value or data.get(key, default)
    if value not in allowed:
        where = f"env {env_name}" if env_value else f"{key} in {origin[key]}"
        fail(f"{key} must be one of: {' '.join(allowed)} (got '{value}' from {where})")
    return value

def risk_levels():
    if env_auto_merge_risk:
        where = "env SOP_AUTO_MERGE_RISK"
        value = [] if env_auto_merge_risk == "none" else \
            [r.strip() for r in env_auto_merge_risk.split(",") if r.strip()]
    elif env_auto_merge:
        return legacy_auto_merge(env_auto_merge, "env SOP_AUTO_MERGE")
    elif "autoMergeRisk" in data:
        where, value = f"autoMergeRisk in {origin['autoMergeRisk']}", data["autoMergeRisk"]
    else:
        return ["L", "M"]
    if not isinstance(value, list) or any(r not in RISKS for r in value):
        fail(f"autoMergeRisk must be a list of {', '.join(RISKS)} (got {json.dumps(value)} from {where})")
    return [r for r in RISKS if r in value]

auto_merge_risk = risk_levels()
merge_method = choice("mergeMethod", "SOP_MERGE_METHOD", env_merge_method,
                      ("squash", "merge", "rebase"), "squash")
offer_bare = layout == "standard" and data.get("offerBareLayout", True) is not False
print(json.dumps({
    "config_file": config or None,
    "user_config_file": user_config or None,
    "layout": layout,
    "repo": repo,
    "anchor": anchor,
    "main_worktree": main_wt or None,
    "source_worktree": source or None,
    "worktree_root": root,
    "resolved_by": resolved_by,
    "path_style": path_style,
    "default_branch": default_branch or None,
    "default_base": default_base,
    "branch_prefix": branch_prefix,
    "stage_prefix": stage_prefix,
    "provision": {
        "from": provision_from,
        "copy": [p for p in copies.splitlines() if p],
        "link": [p for p in links.splitlines() if p],
        "copy_mode": copy_mode or "preserve",
    },
    "max_parallel": data.get("maxParallel", 4),
    "worker_notes": data.get("workerNotes", []),
    "offer_bare_migration": offer_bare,
    "auto_merge_risk": auto_merge_risk,
    "merge_method": merge_method,
}, ensure_ascii=False, indent=2))
PY
}

cmd_path() {
  validate_slug "${1:-}"
  resolve_path task "$1"
  emit_json "$BRANCH_PREFIX$1"
}

cmd_create() {
  local slug=${1:-} base=$DEFAULT_BASE base_sha branch
  validate_slug "$slug"; shift
  while (($#)); do
    case $1 in
      --base) [[ $# -ge 2 ]] || die "--base needs a value"; base=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  branch="$BRANCH_PREFIX$slug"
  base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "base ref '$base' not found"
  git show-ref --verify --quiet "refs/heads/$branch" && die "branch '$branch' already exists"
  resolve_path task "$slug"
  [[ -e $WORKTREE_PATH ]] && die "target path already exists: $WORKTREE_PATH"

  mkdir -p "$(dirname "$WORKTREE_PATH")"
  git worktree add --quiet -b "$branch" "$WORKTREE_PATH" "$base_sha" >&2
  printf '%s\n' "$base_sha" >"$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/sop-base"
  provision "$WORKTREE_PATH"
  emit_json "$branch" ",\"base\":\"$base_sha\",\"provisioned\":[$PROVISIONED]"
}

cmd_integrate() {
  local id=${1:-} base="" base_sha branch b conflicts merged_json=""
  local -a branches=()
  validate_slug "$id"; shift
  while (($#)); do
    case $1 in
      --base) [[ $# -ge 2 ]] || die "--base needs a value"; base=$2; shift 2 ;;
      -*) die "unknown argument: $1" ;;
      *) branches+=("$1"); shift ;;
    esac
  done
  [[ -n $base ]] || die "--base is required"
  ((${#branches[@]})) || die "no branches to integrate"
  branch="$STAGE_PREFIX$id"
  base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "base ref '$base' not found"
  git show-ref --verify --quiet "refs/heads/$branch" && die "branch '$branch' already exists"
  for b in "${branches[@]}"; do
    git show-ref --verify --quiet "refs/heads/$b" || die "branch '$b' not found"
    [[ -n $(git rev-list -n 1 "$base_sha..$b") ]] ||
      die "branch '$b' has no commits beyond base (commit the approved changes first)"
  done
  resolve_path stage "$id"
  [[ -e $WORKTREE_PATH ]] && die "target path already exists: $WORKTREE_PATH"

  mkdir -p "$(dirname "$WORKTREE_PATH")"
  git worktree add --quiet -b "$branch" "$WORKTREE_PATH" "$base_sha" >&2
  printf '%s\n' "$base_sha" >"$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/sop-base"
  provision "$WORKTREE_PATH"

  for b in "${branches[@]}"; do
    if ! git -C "$WORKTREE_PATH" merge --quiet --no-ff --no-edit "$b" >&2; then
      conflicts=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U)
      git -C "$WORKTREE_PATH" merge --abort >/dev/null 2>&1 || true
      [[ -n $conflicts ]] && printf 'CONFLICT  %s\n' $conflicts
      printf 'worktree: merging %s into %s failed; worktree kept at %s (merged so far: [%s])\n' \
        "$b" "$branch" "$WORKTREE_PATH" "$merged_json" >&2
      exit 1
    fi
    merged_json+="${merged_json:+,}\"$(json_escape "$b")\""
  done
  emit_json "$branch" ",\"base\":\"$base_sha\",\"merged\":[$merged_json],\"provisioned\":[$PROVISIONED]"
}

cmd_remove() {
  local name="" prefix=$BRANCH_PREFIX force=0 branch path dirty
  while (($#)); do
    case $1 in
      --force) force=1; shift ;;
      --stage)
        [[ $# -ge 2 && -z $name ]] || die "usage: remove <slug> | remove --stage <id>"
        prefix=$STAGE_PREFIX name=$2; shift 2 ;;
      -*) die "unknown argument: $1" ;;
      *) [[ -z $name ]] || die "unexpected argument: $1"; name=$1; shift ;;
    esac
  done
  validate_slug "$name"
  branch="$prefix$name"
  path=$(find_task_worktree "$branch")
  [[ -n $path ]] || die "no worktree found on branch '$branch'"

  # Provisioned files are gitignored, so they never count as dirty here.
  dirty=$(git -C "$path" status --porcelain)
  if [[ -n $dirty && $force -eq 0 ]]; then
    printf '%s\n' "$dirty" >&2
    die "worktree has uncommitted changes: $path (re-run with --force to discard)"
  fi
  compose_down "$path"
  if ((force)); then git worktree remove --force "$path"; else git worktree remove "$path"; fi
  printf 'removed worktree: %s\n' "$path" >&2
  [[ $PATH_STYLE == branch ]] && prune_empty_parents "$path"

  # -d (not -D): only deletes when merged into the current HEAD.
  if git branch -d "$branch" >/dev/null 2>&1; then
    printf 'deleted merged branch: %s\n' "$branch" >&2
  elif [[ $prefix == "$STAGE_PREFIX" &&
          -z $(git rev-list --no-merges "refs/heads/$branch" --not --exclude="$branch" --branches) ]] &&
       git branch -D "$branch" >/dev/null 2>&1; then
    # A stage branch holding only merges of still-existing branches can be rebuilt
    # with `integrate`, so drop it to let the same stage id be integrated again.
    printf 'deleted stage branch (rebuildable from its task branches): %s\n' "$branch" >&2
  else
    printf 'kept branch (not merged into HEAD): %s\n' "$branch" >&2
  fi
}

cmd_list() {
  local path branch kind name
  linked_worktrees | while IFS=$'\t' read -r path branch; do
    if [[ $branch == "$STAGE_PREFIX"* ]]; then kind=stage name=${branch#"$STAGE_PREFIX"}
    elif [[ $branch == "$BRANCH_PREFIX"* ]]; then kind=task name=${branch#"$BRANCH_PREFIX"}
    else continue
    fi
    printf '{"kind":"%s","slug":"%s","branch":"%s","path":"%s"}\n' \
      "$kind" "$(json_escape "$name")" "$(json_escape "$branch")" "$(json_escape "$path")"
  done
}

# Prints "<kind> <slug>" for a spec-ops-pipeline branch; fails for any other branch.
sop_kind() {
  if [[ $1 == "$STAGE_PREFIX"* ]]; then printf 'stage %s\n' "${1#"$STAGE_PREFIX"}"
  elif [[ $1 == "$BRANCH_PREFIX"* ]]; then printf 'task %s\n' "${1#"$BRANCH_PREFIX"}"
  else return 1
  fi
}

cmd_status() {
  local check=0 bad=0 path branch prunable kind name state head base base_file ahead
  local staged unstaged untracked conflicts
  export GIT_OPTIONAL_LOCKS=0   # read-only: no index refresh, no lock contention with Workers
  while (($#)); do
    case $1 in
      --check) check=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  while IFS=$'\t' read -r path branch prunable; do
    read -r kind name < <(sop_kind "$branch") || continue
    head=null base=null ahead=null staged=0 unstaged=0 untracked=0 conflicts=0
    if ((prunable)) || [[ ! -d $path ]]; then
      state=missing
    else
      head="\"$(git -C "$path" rev-parse --short HEAD)\""
      base_file="$(git -C "$path" rev-parse --absolute-git-dir)/sop-base"
      if [[ -r $base_file ]]; then
        base="\"$(<"$base_file")\""
        ahead=$(git -C "$path" rev-list --count "$(<"$base_file")..HEAD")
      fi
      read -r staged unstaged untracked conflicts < <(git -C "$path" status --porcelain=v1 | awk '
        { xy = substr($0, 1, 2); x = substr(xy, 1, 1); y = substr(xy, 2, 1) }
        xy == "??" { u++; next }
        xy ~ /^(DD|AU|UD|UA|DU|AA|UU)$/ { c++; next }
        { if (x != " ") s++; if (y != " ") w++ }
        END { print s + 0, w + 0, u + 0, c + 0 }')
      if ((staged + unstaged + untracked + conflicts)); then state=dirty; else state=clean; fi
    fi
    [[ $state == clean ]] || bad=1
    printf '{"kind":"%s","slug":"%s","branch":"%s","path":"%s","state":"%s","head":%s,"base":%s,"ahead_of_base":%s,"staged":%d,"unstaged":%d,"untracked":%d,"conflicts":%d}\n' \
      "$kind" "$(json_escape "$name")" "$(json_escape "$branch")" "$(json_escape "$path")" \
      "$state" "$head" "$base" "$ahead" "$staged" "$unstaged" "$untracked" "$conflicts"
  done < <(worktree_entries)
  ((check == 0 || bad == 0))
}

cmd_provision() {
  local wt=${1:-}
  [[ -n $wt && $# -eq 1 ]] || die "usage: provision <worktree>"
  [[ -d $wt ]] || die "not a directory: $wt"
  wt=$(realpath "$wt")
  [[ $(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) == "$COMMON_DIR" ]] ||
    die "not a worktree of this repository: $wt"
  [[ -z $SOURCE_WORKTREE || $wt != "$(realpath -m "$SOURCE_WORKTREE")" ]] ||
    die "refusing to provision the source worktree itself: $wt"
  provision "$wt"
  printf '{"worktree_path":"%s","provisioned":[%s]}\n' "$(json_escape "$wt")" "$PROVISIONED"
}

# The run dir holds a run's plan, specs, whitelists, logs, and state.json. It lives in the
# git common dir: outside every work tree (no effect on baselines or scope gates), shared by
# all worktrees, and kept across agent sessions.
cmd_rundir() {
  local archive=0 dir=$COMMON_DIR/sop-run target
  while (($#)); do
    case $1 in
      --archive) archive=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if ((archive)); then
    [[ -d $dir ]] || die "no run dir to archive: $dir"
    target=$dir.$(date -u +%Y%m%dT%H%M%SZ)
    [[ -e $target ]] && die "archive target already exists: $target"
    mv "$dir" "$target"
    printf '{"archived":"%s"}\n' "$(json_escape "$target")"
    return
  fi
  mkdir -p "$dir/logs"
  printf '{"run_dir":"%s","logs":"%s","has_state":%s}\n' "$(json_escape "$dir")" \
    "$(json_escape "$dir/logs")" "$([[ -f $dir/state.json ]] && echo true || echo false)"
}

usage() {
  # Prints the header comment up to the first non-comment line; $1 = max lines (0 = all).
  awk -v max="${1:-0}" 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print; if (max && NR > max) exit }' "$0"
}

main() {
  local cmd=${1:-}
  [[ -n $cmd ]] || { usage 18 >&2; exit 2; }
  shift
  case $cmd in
    -h|--help) usage; exit 0 ;;
  esac
  require_git
  inspect_repo
  case $cmd in
    config) cmd_config ;;
    path)   cmd_path "$@" ;;
    create) cmd_create "$@" ;;
    integrate) cmd_integrate "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list ;;
    status) cmd_status "$@" ;;
    provision) cmd_provision "$@" ;;
    rundir) cmd_rundir "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
