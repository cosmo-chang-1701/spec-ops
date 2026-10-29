# Scripts and worktree layout

Script paths are relative to the skill directory (`SKILL_DIR` in SKILL.md).

## Scripts
| Script | Purpose | Exit codes |
| :--- | :--- | :--- |
| `scripts/detect_runtime.sh [--agent X]` | Ecosystem + model JSON | 0 ok, 2 usage |
| `scripts/worktree.sh config\|path\|create\|integrate\|remove\|list\|status\|provision\|rundir\|sync` | Layout-aware worktree lifecycle with auto-provisioning; `integrate` builds a stage's `sop-stage/<n>` branch; `status` adds state, base, ahead count and change counts per task/stage; `rundir [--archive]` creates (or archives) the persistent run dir; `remove` runs `docker compose down` for the worktree's own Compose projects first (`SOP_COMPOSE_DOWN=0` disables), and with `--pr-merged` also deletes a branch whose PR was squash- or rebase-merged; `sync` fast-forwards `source_worktree`'s branch to its upstream (JSON) | 0 ok, 1 merge conflict (`integrate`), dirty/missing (`status --check`) or skipped (`sync`, nothing changed), 2 error |
| `scripts/pr.sh preflight\|open\|merge\|state` | Opens an approved task's PR (push, `gh pr create`, reusing an open one) and merges it after its checks pass; `state` reports a PR's `OPEN` / `MERGED` / `CLOSED`; one JSON line on stdout. `preflight` = can PRs be opened at all. Never uses `--admin` | 0 ok, 1 not done (JSON says why), 2 usage |
| `scripts/run_logged.sh <log> '<command>'` | Runs a command with its output in a log file; prints a one-line summary (plus the tail on failure) | the command's exit code, 2 usage |
| `scripts/check_scope.sh <wt> <whitelist> [--base ref]` | Whitelist gate on all changes | 0 ok, 1 violations, 2 usage |
| `scripts/check_scope.sh --list <dir> <whitelist>` · `--overlap <dir> <whitelist>...` | Spec-time: tracked files a whitelist covers · files (`OVERLAP`) and patterns (`POSSIBLE`) shared between whitelists | 0 ok, 1 `OVERLAP` found, 2 usage |
| `scripts/migrate_to_bare.sh [--apply]` | Plan (default) or perform the in-place conversion to the bare-repo worktree layout; see [bare-layout.md](bare-layout.md) | 0 ok, 1 blocked, 2 failed + rolled back, 3 rollback incomplete |
| `scripts/wt.sh add\|remove\|list\|status\|link-config` | For people, not the Lead: everyday branch worktrees in the bare layout; `link-config` re-syncs the agent-config symlinks at the container root | 0 ok, 1 dirty/missing (`status --check`), 2 error |

The script tests live in the source repository's `tests/` directory, not in the installed skill.

## Worktree layout
Detected automatically; nothing to configure per repo. A standard repo can be converted to
the bare layout in place (preflight step 4, [bare-layout.md](bare-layout.md)).

| | Bare container (`<root>/.bare` + `<root>/main/`) | Standard repo (`.git` in the checkout) |
| :--- | :--- | :--- |
| Task worktree | `<root>/sop/<slug>` (dir = branch name) | `<parent>/worktrees/<repo>/<slug>` |
| Stage worktree | `<root>/sop-stage/<id>` | `<parent>/worktrees/<repo>/_stage-<id>` |
| Source (Lead's checkout) | worktree on the default branch, e.g. `<root>/main` | the main checkout |
| Default base | `origin/<default branch>` (else `<default branch>`) | `HEAD` |

Provisioning (both layouts): each new task/stage worktree gets the source worktree's
gitignored, untracked `.env` / `.env.*` files copied (mode kept) and `.venv` dirs symlinked,
so tests run there like in the source. Paths not gitignored in the new worktree are
skipped and never become changes. Disable with `SOP_PROVISION=0`. Workers must not edit
these files or install into a linked venv (it is the source worktree's) — the spec
template says so.

Overrides, only for a repo that deviates: env `SOP_WORKTREE_ROOT`, or
`.agents/spec-ops-pipeline.json` (in `SOP_CONFIG`, the worktree toplevel, or — bare layout — the
default-branch worktree or the container root) with keys `worktreeRoot`, `pathStyle`
(`slug`|`branch`), `defaultBase`, `sourceWorktree`, `provision`
(`{"copy": [...], "link": [...], "copyMode": "644"}`, replaces auto-discovery),
`maxParallel`, `workerNotes`, `offerBareLayout` (`false` = never offer the conversion),
`autoMergeRisk` (Risk levels whose PRs are merged automatically, default `["L", "M"]`; env
`SOP_AUTO_MERGE_RISK=L,M|none`) and `mergeMethod` (`squash` (default) | `merge` | `rebase`; env
`SOP_MERGE_METHOD`) and `autoCleanup` (default `true`; env `SOP_AUTO_CLEANUP=1|0`); see
`worktree.sh --help`. The repo-independent keys (`maxParallel`, `workerNotes`,
`offerBareLayout`, `autoMergeRisk`, `mergeMethod`, `autoCleanup`) can also be set for every repo
in the user config, `~/.config/spec-ops-pipeline/config.json` (`$XDG_CONFIG_HOME`, env
`SOP_USER_CONFIG`); the repo config wins key by key.
`pr.sh` reads `SOP_PR_TIMEOUT` (seconds to wait for checks, default 1800) and
`SOP_PR_CHECKS_DELAY` (default 20).
Branch prefixes: `SOP_BRANCH_PREFIX` (tasks, default `sop/`), `SOP_STAGE_PREFIX` (stages, default `sop-stage/`).
