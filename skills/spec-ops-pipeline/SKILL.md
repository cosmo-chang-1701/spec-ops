---
name: spec-ops-pipeline
description: >-
  Runs a Lead-Worker workflow for code audits and delegated refactoring. The Lead
  (reviewer/orchestrator) scans code read-only, writes a gap analysis, drafts a
  whitelisted spec with a Definition of Done, dispatches a Worker subagent to
  implement it inside an isolated git worktree, gates the result (scope + DoD), and
  reviews the PR diff. With several tasks it runs Workers in parallel — all at once
  when the tasks are independent, or in dependency-ordered stages (parallel within a
  stage, integrated between stages) when they are related. Use when the user asks to
  audit a codebase and fix what is found, to delegate a refactor or cleanup to one or
  more subagents in separate worktrees, to run a spec-driven or Lead-Worker
  implementation, or to review a worker's branch before merging.
---

# Spec Ops Pipeline (Lead-Worker)

`SKILL_DIR` below = the directory containing this file (e.g. `~/.agents/skills/spec-ops-pipeline`).

## Role boundaries (non-negotiable)

| Role | May | Must not |
| :--- | :--- | :--- |
| **Lead** (you) | Read/search code, run tests/linters/builds, write specs, reviews, and run state (in the run dir), create/remove/integrate worktrees via `worktree.sh`; after the user's explicit yes, convert the repo to the bare-repo worktree layout with `migrate_to_bare.sh --apply`; once the user approved it at the checkpoint, commit approved work on `sop/*` branches (in staged mode also between stages), and run `pr.sh open` / `pr.sh merge` to push, open the PR and — per `auto_merge` — merge it | Edit, create, delete, or move any application file — in the main checkout **or** in a worker worktree (sole exception: `migrate_to_bare.sh --apply` as above); resolve merge conflicts by hand; merge a task that was not APPROVEd, use `--admin`, or otherwise get around branch protection |
| **Worker** (subagent) | Edit files matched by its whitelist, inside its worktree, until the DoD passes | Touch non-whitelisted files, commit/push, or work outside its worktree |

If the Lead is tempted to "just fix it quickly", write it into a spec instead.

## Model assignment
Run `bash SKILL_DIR/scripts/detect_runtime.sh --agent <claude|gemini|codex>` with **your own
runtime**. It prints the models for each role: `lead` (phase 1), `lead_phase2`, `worker`,
`worker_light` (small mechanical L-risk tasks), and `scout` (read-only audit sweeps). The
read-only Reviewer of a Worker's diff runs on `lead`. Roles,
defaults, overrides, the Critic's model, and the Worker tier rules:
[references/models.md](references/models.md). If you are not running as the Lead model of the
current phase, tell the user how to switch (`/model`, `/effort` in Claude Code); do not
silently continue — except in a `single`-session run, which keeps the phase 1 Lead model.

## Sessions and context
- **Phase 1** — steps 0–2 (preflight, audit, spec, checkpoint) on the phase 1 Lead model.
- **Phase 2** — steps 3–6. In a `split` run it starts with [Resume](#resume-phase-2) in a
  **fresh session** on the phase 2 Lead model, reading only the plan, the state, and the
  current stage's specs — specs are self-contained by design, so nothing else from phase 1
  is needed. In a `single` run it continues in the same session on the phase 1 Lead model.

Which one, from `session_split` (`detect_runtime.sh`, env `SOP_SESSION_SPLIT`):
- `auto` (default) — `single` for a small run: exactly one task with risk L or M. `split`
  for two or more tasks (including `staged`) or any H-risk task, where a fresh session keeps
  the Lead's context small.
- `always` → `split`; `never` → `single`.

Show the result in the checkpoint report; an explicit request from the user there wins.

Run state lives in the **run dir**, `bash SKILL_DIR/scripts/worktree.sh rundir` →
`<git common dir>/sop-run/`: outside every work tree (baselines and scope gates never see it),
shared by all worktrees, and kept across sessions. Never use a session scratchpad for it.

**Command output** — run every lint/test/build/DoD command through
`bash SKILL_DIR/scripts/run_logged.sh <run dir>/logs/<slug>-<step>-<n>.log '<command>'`.
It prints one `exit=<rc> lines=<n> log=<path>` line (plus the last 40 lines on failure) and
exits with the command's code. Read more of the log (with an offset) only when the tail does
not explain a failure. Never let a full test suite's output into the conversation.

## Workflow

### 0. Preflight
1. `detect_runtime.sh` as above; note the `worker` block and `session_split`.
2. `bash SKILL_DIR/scripts/worktree.sh config` — the detected layout and its defaults
   (see [scripts-and-layout.md](references/scripts-and-layout.md#worktree-layout)); no
   per-repo setup is needed. Note
   `source_worktree`, `default_base`, `provision`, `max_parallel`, and `offer_bare_migration`.
   In a bare layout run every Lead git/test command inside `source_worktree` (the container
   root is not a work tree).
3. Check `bash SKILL_DIR/scripts/worktree.sh status` for leftover tasks from earlier runs,
   and `bash SKILL_DIR/scripts/worktree.sh rundir` for a run in progress (`has_state: true`):
   ask the user whether to [resume](#resume-phase-2) it or archive it
   (`worktree.sh rundir --archive`) and start over. Note `run_dir`.
4. If `offer_bare_migration` is `true`: run `bash SKILL_DIR/scripts/migrate_to_bare.sh`
   (dry run) and ask the user whether to convert to the **bare-repo worktree layout**, in the
   format of [references/bare-layout.md](references/bare-layout.md). Only on an explicit
   yes: `migrate_to_bare.sh --apply`, re-run `worktree.sh config`, and re-read the agent docs
   from the new `source_worktree`. Blocked or declined → continue with the standard layout.
5. Record the Lead baseline of `source_worktree`:
   `git status --porcelain=v1 && git diff HEAD | sha256sum` — keep the output (it goes into
   `state.json` at the checkpoint).
6. `bash SKILL_DIR/scripts/pr.sh preflight` — can PRs be opened (gh installed and logged in,
   `origin` set)? Note `ok` and `into`; `ok: false` means the run only commits locally, and
   the checkpoint says so. Note `auto_merge` and `merge_method` from `worktree.sh config`
   ([execution-plan.md](references/execution-plan.md#auto-merge-modes)).
7. If `default_base` is not `HEAD`: `git fetch` its remote, then check
   `git rev-parse HEAD` equals `git rev-parse <default_base>`. If not, the audited code
   differs from what Workers will start from — tell the user and agree on the base first.

### 1. Audit (read-only)
- Establish scope with the user (paths, concern: security / perf / debt / spec gaps).
- Scan statically — for a large scope, sweep it first with parallel read-only scouts per
  [references/scout.md](references/scout.md) and verify their leads. Run the project's
  existing lint/test/type-check commands to get ground truth, each through `run_logged.sh` (logs `audit-<n>.log`). Do not install tools or
  change config to do so.
- Produce a **gap report**: numbered findings, each with `file:line`, severity, evidence,
  and a proposed fix. Group findings into tasks that can each be done by one Worker with
  a small, non-overlapping whitelist.
- With more than one task, analyse dependencies and draft the **execution plan** per
  [references/execution-plan.md](references/execution-plan.md):
  - no dependencies → `independent`: one Worker per task, all in parallel;
  - related tasks → `staged`: dependency-ordered stages, parallel within each stage, each
    stage built on the integrated result of the previous one.

### 2. Spec (checkpoint)
- For each task, fill [references/worker-spec-template.md](references/worker-spec-template.md):
  slug, goal, context, whitelist, forbidden, DoD commands (and stage/dependencies), and pick
  its Worker tier (`light` / `standard`, [models.md](references/models.md#worker-tier)).
  Fill the spec's **Repo rules** from the repo's agent docs (`AGENTS.md`, `CLAUDE.md`, and
  the ones in directories the whitelist touches): how to run tests/lint/type checks,
  required flags, language rules. Add pitfalls you know about this repo from your own
  memory that those docs do not cover, plus any `worker_notes`. Workers cannot see your
  context or memory, so anything left out is unknown to them. Write DoD commands the way
  those rules require (working directory, flags, tools).
- Save the gap report, the execution plan, each spec, and each whitelist to the run dir
  (never inside a worktree): `gap-report.md`, `plan.md`, `spec-<slug>.md`, `<slug>.wl`.
- **Overlap check** — per stage: `bash SKILL_DIR/scripts/check_scope.sh --overlap
  <source_worktree> <slug>.wl...`. An `OVERLAP` means re-split or re-stage; check every
  `POSSIBLE` by hand.
- **DoD dry run** — run each DoD command of `independent` / stage-1 tasks in
  `source_worktree` through `run_logged.sh` (logs `<slug>-dry-<n>.log`), classify it, and
  note the class in the spec; fix `BROKEN` commands. Stage 2+ tasks are dry-run at step 3. See
  [worker-spec-template.md](references/worker-spec-template.md#dod-dry-run).
- **Plan Critic** — with 2+ tasks, `staged` mode, an H-risk task, or on request: dispatch a
  read-only critic (`lead` model only if a task is H-risk, else `lead_phase2`) and decide
  on each finding per
  [references/plan-critic.md](references/plan-critic.md). One round.
- **Show the checkpoint report to the user and wait for approval** before step 3: decision
  matrix, decisions for you, execution plan, then gap report and specs, in the format of
  [execution-plan.md §3](references/execution-plan.md#3-checkpoint-report). In `staged` mode
  the approval must explicitly cover the inter-stage local commits and merges. For every run
  it must also cover the automatic commit, push, PR and — per the Merge column — merge after
  APPROVE (wording in [execution-plan.md §3](references/execution-plan.md#3-checkpoint-report)).
- **Phase boundary** — after approval, write `<run dir>/state.json`
  ([execution-plan.md §7](references/execution-plan.md#7-run-state)) with `phase: 2` and the
  agreed `session`, then:
  - `split` — end phase 1 by telling the user:
    > Plan approved and saved to `<run dir>`. Run `/clear`, switch to the phase 2 Lead
    > (`/model <lead_phase2.model>`, `/effort <lead_phase2.effort>`), then invoke this skill
    > with `resume`.

    (Codex / Antigravity: start a new session with the `lead_phase2` model.)
  - `single` — tell the user the plan is saved to `<run dir>` and the run continues in this
    session, then go straight to step 3 without switching models. If the session is lost,
    `resume` still works from `state.json`.

### Resume (phase 2)
Entered when the skill is invoked with `resume`, or when preflight finds a run in progress
and the user chooses to resume. Do not redo steps 0–2.
1. `detect_runtime.sh` and `worktree.sh config` as in preflight; check you are on the
   `lead_phase2` model. `worktree.sh rundir` → `run_dir`.
2. Read `state.json` and `plan.md`, then only the specs and whitelists of `current_stage`
   (not the gap report; read it only if a finding's wording is needed to decide something).
3. Re-run the baseline command on `source_worktree`; it must equal `baseline` in the state.
   Check `git rev-parse <default_base>` still equals `default_base_sha` (`git fetch` first if
   it is remote). On any mismatch stop and ask the user — the plan was approved for that code.
4. `worktree.sh status`: compare with the task states in `state.json`. Worktrees of the
   current stage that already exist are reused, not re-created; a task recorded as
   `dispatched` or `in-review` has no reachable Worker anymore — re-dispatch it on its
   `worker_tier` with its spec (plus the open findings, if any) into its existing worktree,
   telling the new Worker to keep the uncommitted changes already there
   ([models.md](references/models.md#worker-tier)). A task recorded as `approved` continues
   with its commit; `committed` (with `pr_enabled`) re-runs `pr.sh open` (it reuses an open PR);
   `pr-open` with `merge: auto`, no `pr_state` and the merge conditions met re-runs `pr.sh merge`
   ([execution-plan.md §4a](references/execution-plan.md#4a-after-approve-independent-mode)).
5. Continue at step 3 for `current_stage`.

Steps 3–5 run **once per stage** (`independent` mode = a single stage), in plan order. Keep
`state.json` current: update a task's status when it is dispatched, enters a review round,
is approved or deferred, and the stage when it is integrated.

### 3. Worktree + dispatch
1. For each task in the stage: `bash SKILL_DIR/scripts/worktree.sh path <slug>` to preview,
   then `bash SKILL_DIR/scripts/worktree.sh create <slug> [--base <ref>]` (stage 1: omit
   `--base` to use `default_base`; stage 2+: `--base sop-stage/<n-1>`). The path adapts to
   the repo (config → existing worktree layout → bare → standard); see the script header.
   Branch is `sop/<slug>`; the fork point is recorded for later diffs. Files listed under
   `provision` (gitignored secrets, venvs) are copied/linked in; check `provisioned` in the
   output and stop if an expected entry is missing. Stage 2+: dry-run each task's DoD in its
   new worktree through `run_logged.sh` before dispatch (path/flag fixes only; anything
   else goes back to the user).
2. Insert the worktree path and base into each spec, then dispatch **all of the stage's
   Workers in parallel** per [references/dispatch.md](references/dispatch.md), each on the
   model of its `worker_tier` (`worker` or `worker_light`; concurrency cap = `max_parallel`).

### 4. Gate (per task)
1. `bash SKILL_DIR/scripts/check_scope.sh <worktree> <whitelist-file>` — must exit 0.
   On violations: send them back to the Worker to revert (counts as a review round).
2. Re-run every DoD command yourself inside the worktree through `run_logged.sh` (logs
   `<slug>-gate-r<round>-<n>.log`). All must exit 0.

### 5. Review (per task) + stage barrier
Follow [references/review-checklist.md](references/review-checklist.md): the diff is reviewed on
the `lead` model — in a `split` run by a read-only Reviewer subagent whose findings you verify,
in a `single` run by you — against the recorded base. Issue APPROVE or REQUEST_CHANGES with
numbered `file:line` findings, and loop with the Worker at most **3 rounds**, then escalate to
the user.
Tasks loop independently of each other. A `light` task that fails round 1 is re-dispatched on
the `worker` model ([models.md](references/models.md#worker-tier)).
- `independent`: on APPROVE, commit, push and open the PR with `pr.sh`, and merge it when the
  task's Merge value and `auto_merge` allow — all under the checkpoint approval, with no
  question ([execution-plan.md §4a](references/execution-plan.md#4a-after-approve-independent-mode)).
- `staged`: when every task in the stage is APPROVED, commit each locally, run
  `worktree.sh integrate <n> --base <stage base> sop/<slug>...`, and pass the integration
  gate (all of the stage's DoD in the stage worktree) before starting the next stage. See
  execution-plan.md for conflicts, integration failures, and escalated tasks. With more
  stages to go, set `current_stage` to the next one in `state.json` and offer the user a
  fresh session (`/clear`, then `resume`) — safe here, since no Worker of the stage is active.

### 6. Close-out
1. Re-run the baseline command from step 0; it must match. If it does not, report exactly
   what changed in the main checkout — do not "fix" it yourself.
2. PRs: `independent` PRs already exist (§5); list each task's PR and whether it is `merged`,
   `open` (with the reason) or local only. For `staged`, open the single PR from the last
   `sop-stage/<n>` with `pr.sh` (merge per `auto_merge`, see
   [execution-plan.md §6](references/execution-plan.md#6-close-out)).
3. With user consent, `bash SKILL_DIR/scripts/worktree.sh remove <slug>` for every task and
   `remove --stage <n>` for every stage (refuses dirty worktrees without `--force`; task
   branches are deleted only if merged — a squash or rebase merge does not count, so keep
   them or `git branch -D` those whose PR is `merged`, with consent). Each `remove` first runs `docker compose down`
   (volumes kept) for Compose projects started only from inside that worktree; a project
   shared with another checkout is left running and reported.
4. With user consent, `bash SKILL_DIR/scripts/worktree.sh rundir --archive` (keeps the
   plan, specs, and logs as `sop-run.<timestamp>/` in the git common dir; delete it if the
   user prefers).
5. Final summary: findings addressed, findings deferred (and their blocked dependents),
   branches/PRs created with their state.

## Scripts and layout
Script usage and exit codes, the worktree paths per layout, provisioning, and config overrides:
[references/scripts-and-layout.md](references/scripts-and-layout.md).
