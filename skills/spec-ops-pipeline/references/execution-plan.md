# Execution Plan (multiple Workers)

When the audit yields more than one task, the Lead decides how Workers run before the
spec checkpoint: **independent** (all in parallel at once) or **staged** (parallel within a
stage, stages in order). The plan is shown to the user in the checkpoint report (§3).

## 1. Dependency analysis
Task B **depends on** task A when any of these hold:
- B uses a symbol, API, schema, config key, or behaviour that A adds or changes.
- B's DoD can only pass once A's change exists.
- B's whitelist overlaps A's — including shared hot spots such as route/registry/index
  files, lockfiles, migrations, or a common test fixture. Overlapping tasks never share a stage.
  `check_scope.sh --overlap <source_worktree> <a>.wl <b>.wl ...` lists shared tracked files
  (`OVERLAP`) and patterns that could meet on a new file (`POSSIBLE`).

Cycles mean the split is wrong: merge the tasks in the cycle into one task.
Prefer a split that removes edges (e.g. one task owns the shared file) over a longer chain.

## 2. Mode
| Dependency edges | Mode | Shape |
| :--- | :--- | :--- |
| none | `independent` | One wave. Every worktree is created from the same base; each task is gated, reviewed, and offered as its own PR. No inter-stage commits. |
| some | `staged` | Topologically layer the tasks; stage *n* holds every task whose dependencies all sit in earlier stages. Use the fewest stages possible. |

Concurrency cap: at most `max_parallel` (from `worktree.sh config`, default **4**) Workers
running at once unless the user sets another limit;
split a larger stage (or wave) into batches.

## 3. Checkpoint report
Lead the report with what needs a human decision; put the detail last. Always in this order
(a single task gets a one-row matrix and no plan block):

**① Decision matrix** — one row per task:

| Task | Findings | Scope | Stage ← deps | Risk | Worker | Merge | Shared resources | DoD baseline | Critic |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| fix-auth-token | #1, #4 | `src/auth/` · 6 files | 1 | H — auth | standard | manual | — | 1 FAIL-EXPECTED · 2 PASS | 1 accepted |
| add-rate-limit | #2 | `src/api/middleware/` · 3 files | 1 | M | standard | auto | Redis (compose) | 1 NOT-YET · 2 PASS | — |
| drop-dead-helpers | #5 | `src/utils/` · 2 files | 1 | L | light | auto | — | 1 FAIL-EXPECTED · 1 PASS | — |
| migrate-callers | #3 | `src/api/routes/` · 11 files | 2 ← fix-auth-token | M | standard | auto | `routes/index.py` POSSIBLE | 2 PASS · 1 FAIL-EXPECTED | 1 rejected (H) |

- **Scope**: top directories of the whitelist and the file count from
  `check_scope.sh --list <source_worktree> <slug>.wl`.
- **Risk** — the highest that applies:
  - **H**: touches auth/security, a public API, a DB migration, or data deletion; or the
    changed code has no existing tests;
  - **M**: crosses modules, or changes behaviour that existing tests cover;
  - **L**: local, behaviour-preserving, covered by tests.
- **Worker**: `light` or `standard` per [models.md](models.md#worker-tier); the user may
  override it with the approval.
- **Merge**: whether the task's PR is merged automatically once it is open, pre-filled from
  `auto_merge_risk` (`worktree.sh config`; [rules](#auto-merge-modes)): `auto` when the task's
  Risk is in the list, else `manual`. `auto` is conditional: the task must also be approved in
  review round 1 and keep its Worker tier. The user may change a task's value, or the list,
  with the approval.
- **Shared resources**:
  - static: `OVERLAP` / `POSSIBLE` lines from `check_scope.sh --overlap`, lockfiles,
    migrations, common fixtures;
  - runtime, for tasks in the same stage: Docker Compose volumes and networks (shared across
    worktrees, see the spec template's Repo rules), databases, ports, the linked `.venv`.
- **DoD baseline**: class counts from the [DoD dry run](worker-spec-template.md#dod-dry-run).
- **Critic**: accepted/rejected counts, or `skipped` ([plan-critic.md](plan-critic.md)).

Below the matrix, one line on the session plan
([SKILL.md](../SKILL.md#sessions-and-context)), so the user can override it with the approval:
`Session: single (auto — 2 L/M tasks)` or `Session: split (auto — 3 tasks)`; the source is
`auto`, `always`, `never` (from `SOP_SESSION_SPLIT`) or `user`. Then one line on the PRs:
`PRs: open on APPROVE · auto-merge risk L, M (user config) · squash · into main`, or
`PRs: local commits only — <pr.sh preflight reason>` when `pr.sh preflight` failed.

**② Decisions for you** — one bullet each, empty section if none: every H-risk task, every
rejected H Critic finding (with the reason), every `FAIL-UNRELATED` DoD, every whitelist
that reaches beyond the files the findings name, and every unresolved `POSSIBLE` overlap.

**③ Execution plan**:
```text
Mode: staged · max parallel 4
Stage 1 (base origin/main 1a2b3c4): fix-auth-token, add-rate-limit, drop-dead-helpers  [parallel]
Stage 2 (base sop-stage/1):  migrate-callers ← fix-auth-token
Stage 3 (base sop-stage/2):  drop-legacy-auth ← migrate-callers
Inter-stage: local commits on sop/* and sop-stage/* branches, merges via worktree.sh integrate; no push
```

**④ Gap report and full specs**, with the run-dir path of each spec file.

The approval is what authorises the Lead's commits, pushes and PRs, so state it explicitly and
ask the user to approve it:
- after APPROVE, `git commit` on the task's `sop/*` branch (for `staged`: the inter-stage local
  commits and merges, and the PR from the last `sop-stage/<n>`), then push that branch and open
  a PR into the default branch;
- for every task whose Merge is `auto`, merging that PR once its checks pass, with the
  configured method, and deleting the remote head branch.

The user may narrow it (change the risk list, change one task to `manual`, or "no PRs": commit
locally only). It never covers removing worktrees or archiving the run dir; those keep their own
consent at close-out. Record the approval in `state.json` (§7) so a phase 2 session can rely on it.

### Auto-merge modes
`auto_merge_risk` in `worktree.sh config` lists the Risk levels whose PRs the Lead merges after
opening them; every APPROVEd task gets a PR either way. Default `["L", "M"]`: only H-risk PRs
are left for the user. Set by `autoMergeRisk` in the user config
(`~/.config/spec-ops-pipeline/config.json`), overridden by the repo's
`.agents/spec-ops-pipeline.json`, overridden by env `SOP_AUTO_MERGE_RISK` (`L,M`, or `none`);
`config_file` and `user_config_file` say which files were read. `[]` = the user merges every PR.

The Lead merges a task's PR only when **all** hold:
- its Merge is `auto` (its Risk is in `auto_merge_risk`, unless the user changed it);
- it was approved in review round 1 (`ever_rejected == false`: never REQUEST_CHANGES, a failed
  gate included);
- it was not escalated to the `worker` model.

Merge method: `merge_method` (`mergeMethod`, same files, env `SOP_MERGE_METHOD`; default
`squash`). The deprecated `autoMerge` / `SOP_AUTO_MERGE` (`manual`, `low-risk`, `all`) still
map to `[]`, `["L"]`, `["L", "M", "H"]`.

## 4. Running a stage
`independent` mode is a single stage without steps 4–6.

1. **Create** — `worktree.sh create <slug> --base <stage base>` for each task in the stage
   (stage 1: `default_base`, i.e. omit `--base`; stage *n*: `sop-stage/<n-1>`).
   Stage 2+: dry-run each task's DoD in its new worktree (through `run_logged.sh`) and update
   the `# baseline:` notes
   per [worker-spec-template.md](worker-spec-template.md#dod-dry-run) before dispatching.
2. **Dispatch** — all Workers of the stage at once, per [dispatch.md](dispatch.md).
3. **Gate + review per task** — `check_scope.sh`, re-run its DoD, review per
   [review-checklist.md](review-checklist.md). Tasks loop independently (max 3 rounds each);
   a slow task does not reset or block the others' rounds.
4. **Barrier + commit** — once every task in the stage is APPROVED, commit each worktree:
   `git -C <wt> add -A && git -C <wt> commit -m "sop(<slug>): <goal>"`.
5. **Integrate** — `worktree.sh integrate <n> --base <stage base> sop/<slug>...`.
   It creates `sop-stage/<n>` in its own worktree and merges each branch with `--no-ff`.
   Exit 1 = merge conflict (conflicting files are listed): the whitelists overlapped after all,
   so fix the plan (re-split, or move a task to a later stage) and ask the user if specs change.
6. **Integration gate** — in the stage worktree, re-run every DoD command of the stage
   (plus the project's full test command if one exists), each through `run_logged.sh`
   (logs `stage-<n>-gate-<k>.log`). This catches tasks that pass alone
   but break together. On failure, find the responsible task and send REQUEST_CHANGES to its
   Worker in its own worktree (counts toward its rounds); after APPROVE, commit again,
   `worktree.sh remove --stage <n> --force`, and re-run step 5.
7. Only then create the next stage's worktrees on `sop-stage/<n>`. Each new worktree records
   that as its base, so `check_scope.sh` sees only the task's own changes. Before that, mark
   the stage `integrated` and advance `current_stage` in `state.json`, then go on in the same
   session. This is the one point where a fresh session (`/clear`, then `resume`) is safe;
   offer it only when the context has grown large (e.g. two stages already ran in this
   session, or the stage took several review rounds).

## 4a. After APPROVE (independent mode)
No question to the user; the checkpoint approval covers it. Per task, as soon as it is APPROVEd
(use `run_logged.sh` for the `pr.sh` calls, logs `<slug>-pr-<step>.log`; the JSON is the last
line):
1. Re-run the baseline command; it must match, or stop and report (nothing is committed).
2. `git -C <wt> add -A && git -C <wt> commit -m "sop(<slug>): <goal>"` → status `committed`.
3. If `pr_enabled`: write `<run dir>/pr-<slug>.md` (goal, finding numbers, DoD commands with
   results, review summary, `Merge: auto|manual`) and run
   `bash SKILL_DIR/scripts/pr.sh open <wt> --title "sop(<slug>): <goal>" --body-file <run dir>/pr-<slug>.md`
   → status `pr-open`, record `pr`. Exit 1: record the `reason`, stay `committed`, and list the
   manual commands in the final summary.
4. Merge when the [auto-merge rules](#auto-merge-modes) hold (`merge == "auto"`,
   `ever_rejected == false`, `worker_tier` not escalated): `pr.sh merge <pr> --method
   <merge_method>` → status `merged`. In Claude Code run it with `run_in_background` so
   waiting for CI does not hold up the other tasks. Exit 1: record `pr_state`
   (`checks-failed`, `checks-timeout`, `merge-refused`), leave the PR open and report it.
   Otherwise leave the PR open and say why in the summary (`manual: risk H`,
   `manual: 2 review rounds`).

`pr.sh` never uses `--admin` and never works around branch protection; a refused merge is
the user's to resolve.

## 5. When a task fails
A task that is still REQUEST_CHANGES after 3 rounds (or is blocked on a non-whitelisted file)
stops the barrier. It is not committed and gets no PR. Report to the user and let them choose:
- **Defer** it and every task that transitively depends on it; integrate the rest of the stage
  and continue with the remaining plan, or
- **Revise** the spec (whitelist, goal, DoD), which needs fresh approval.

Never silently drop a task or its dependents.

## 6. Close-out
- `independent`: the PRs were opened (and merged where allowed) at §4a; collect them into the
  summary: PR URL and `merged` / `open — <reason>` / `local only — <reason>` per task.
- `staged`: after the last stage's integration gate and the baseline check, `pr.sh open
  <stage worktree> --base <default_base_sha> ...` for `sop-stage/<last>` (one PR with
  everything; stacked per-stage PRs only if the user asked for them at the checkpoint). Merge
  it with `pr.sh merge` only when **every** task meets the
  [auto-merge rules](#auto-merge-modes).
- Removing worktrees and archiving the run dir still need the user's consent. A squash or
  rebase merge leaves `sop/<slug>` "unmerged" for `worktree.sh remove`, which keeps the
  branch; delete it with `git branch -D` after the user agrees, once its PR is `merged`.
- Remove task worktrees with `worktree.sh remove <slug>` and stage worktrees with
  `worktree.sh remove --stage <n>`. A stage branch built only from merges is deleted locally
  (task branches are kept unless merged), so push or keep the PR's stage branch first.
  `remove` first runs `docker compose down` (volumes kept) for Compose projects started only
  from inside that worktree; one shared with another checkout is left running.

## 7. Run state
`<run dir>/state.json` (run dir = `worktree.sh rundir`) is what a fresh phase 2 session
resumes from. The Lead writes it at the checkpoint and rewrites it on every status change.
It records facts only — decisions stay in `plan.md` and the specs.

```json
{
  "phase": 2,
  "session": "split",
  "approved_at": "2026-10-16T09:30:00Z",
  "approval": "Plan as shown; inter-stage local commits and merges approved (no push).",
  "source_worktree": "/abs/path/to/main",
  "baseline": "<exact output of the step 0 baseline command>",
  "default_base": "origin/main",
  "default_base_sha": "1a2b3c4d…",
  "auto_merge_risk": ["L", "M"],
  "merge_method": "squash",
  "pr_enabled": true,
  "pr_into": "main",
  "mode": "staged",
  "max_parallel": 4,
  "current_stage": 1,
  "stages": [
    {"n": 1, "status": "pending", "tasks": ["fix-auth-token", "add-rate-limit", "drop-dead-helpers"]},
    {"n": 2, "status": "pending", "tasks": ["migrate-callers"]}
  ],
  "tasks": {
    "fix-auth-token": {"stage": 1, "status": "pending", "worker_tier": "standard", "round": 0, "worktree": null, "open_findings": [],
                       "risk": "H", "merge": "manual", "ever_rejected": false, "pr": null, "pr_state": null}
  }
}
```

- `session`: `single` (phase 2 continued in the phase 1 session) or `split` (fresh session).
  A resumed session always runs on the `lead_phase2` model, whichever it was.
- Stage status: `pending` → `running` → `integrated` (or `deferred`).
- Task status: `pending` → `dispatched` → `in-review` (with `round`) → `approved` →
  `committed` → `pr-open` → `merged`, or `deferred` / `escalated`. `open_findings` holds the blocking findings of the
  last REQUEST_CHANGES, so a resumed session can re-dispatch with them.
- `risk` and `merge` (`auto` | `manual`) come from the decision matrix; `ever_rejected` turns
  `true` on the first REQUEST_CHANGES (a failed gate counts) and never goes back, since `round`
  only shows the latest. `pr` is the PR URL; `pr_state` is the last non-success result of
  `pr.sh` (`checks-failed`, `checks-timeout`, `merge-refused`). `pr_enabled` is `false` when
  `pr.sh preflight` failed or the user asked for local commits only.
- `worker_tier`: `light` or `standard` ([models.md](models.md#worker-tier)); set to
  `standard` when a `light` task is escalated, and a resumed session dispatches on that tier.
- `approval` quotes what the user approved at the checkpoint; a resumed Lead never assumes
  more than it says.
