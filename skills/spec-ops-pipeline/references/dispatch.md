# Dispatching the Worker

Use the `detect_runtime.sh` block of the task's `worker_tier`: `worker` for `standard`,
`worker_light` for `light` ([models.md](models.md#worker-tier)). Always pass the **complete spec** (the
Worker cannot see the Lead's context) and the worktree's **absolute path**.

## Claude Code (ecosystem: claude)
Use the subagent tool (`Agent` / `Task`), not a shell call:

- `subagent_type`: `general-purpose` (needs edit + bash tools)
- `model`: the tier's `dispatch_model` (`sonnet` / `haiku`)
- `effort`: the tier's `effort` — this skill explicitly requests it (omit it only if the
  runtime rejects it for that model)
- `prompt`: the filled spec. It must state the worktree path as the working root; the
  subagent starts in the Lead's cwd, so the spec must tell it to use absolute paths
  under the worktree (or `cd` there in each shell command).
- Do **not** set `isolation: "worktree"` — the worktree is already managed by `worktree.sh`.

Dispatch runs in phase 2, so the Lead is the `lead_phase2` model (Sonnet 5.5 / high by
default). If the current session is on another model, tell the user to switch with `/model`
(and effort with `/effort`) rather than proceeding silently. Exception: a `single`-session run
([SKILL.md](../SKILL.md#sessions-and-context)) dispatches from the phase 1 Lead model.

A Worker's diff is later reviewed by a different, read-only subagent on the `lead` model
(`lead.dispatch_model`), dispatched by the same phase 2 Lead after the gate; see
[review-checklist.md](review-checklist.md#reviewer-subagent).

## Codex CLI (ecosystem: codex)
```bash
codex exec \
  -C "<worktree>" \
  -m "<tier.model>" \
  -c model_reasoning_effort="<tier.effort>" \
  -s workspace-write \
  -o "<run dir>/worker-<slug>.md" \
  - < "<run dir>/spec-<slug>.md"
```
`-s workspace-write` confines writes to the worktree; `-o` captures the Worker's final report.

## Antigravity CLI (ecosystem: gemini)
```bash
(cd "<worktree>" && agy -p "$(cat "<run dir>/spec-<slug>.md")" \
  --model "<tier.dispatch_model>" \
  --mode accept-edits \
  --output-format text) > "<run dir>/worker-<slug>.md"
```
Model ids carry the effort suffix (`gemini-3.8-flash-high`); list them with `agy models`.
If the Antigravity session exposes a native subagent tool, prefer it with the same model.

## Parallel dispatch (several tasks in a stage)
Dispatch every task of the current stage at once — `independent` mode is one stage
holding all tasks. Which tasks share a stage is decided by
[execution-plan.md](execution-plan.md); never parallelise tasks whose whitelists overlap.
Respect the concurrency cap (`max_parallel`, default 4); dispatch the rest as earlier Workers finish.

- **Claude Code**: put all of the stage's `Agent` calls in **one message** so they run
  concurrently. Each call gets its own complete spec and its own worktree path. Gate and
  review each task as its completion notification arrives; start the next stage only after
  every task of this stage has cleared the barrier.
- **Codex / Antigravity**: start one background process per task, each with its own spec
  and its own report file, then `wait` for all of them:
  ```bash
  for slug in fix-auth-token add-rate-limit; do
    codex exec -C "<worktree-of-$slug>" ... -o "<run dir>/worker-$slug.md" \
      - < "<run dir>/spec-$slug.md" &
  done
  wait
  ```
  (Same pattern for `agy`, one `(cd <worktree> && agy ...) > <report> &` per task.)
- Review rounds go back to the same Worker for that task only (`SendMessage` to its agent
  in Claude Code; a new `codex exec` / `agy` run in the same worktree otherwise). Escalating
  a `light` task to `standard` is always a new dispatch on the `worker` model (a message keeps
  the old model): full spec plus `open_findings`, same worktree.

## Any runtime
- Keep spec and report files in the run dir (`worktree.sh rundir`), never inside the
  worktree (they would show up as untracked files and fail the scope gate). Name them per slug.
- After each Worker returns: `check_scope.sh`, then re-run the DoD yourself through
  `run_logged.sh`. The Worker's report holds exit codes and failure tails only; do not ask
  it for full command output.
- Mark the task `dispatched` in `state.json` when it starts. A Worker cannot be reached from
  a later session, so on [resume](../SKILL.md#resume-phase-2) an unfinished task is
  re-dispatched into its existing worktree.
