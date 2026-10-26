# Plan Critic (adversarial spec review)

A read-only subagent challenges the Lead's specs and execution plan before the checkpoint.
It catches what the author of a plan tends to miss in their own work. It only reports; the
Lead decides on each finding and still owns the plan.

## When to run
Run it at step 2, after the overlap check and the DoD dry run, when **any** of these hold:
- the plan has 2 or more tasks, or the mode is `staged`;
- a task touches auth/security, a public API, a DB migration, or data deletion;
- the user asks for it.

Otherwise skip it and say so in the checkpoint ("Critic: skipped — single low-risk task").

## Inputs (all as files in the run dir)
- `gap-report.md`, `plan.md`, every `spec-<slug>.md` and `<slug>.wl` (saved at step 2);
- `overlap-stage-<n>.txt` — the `check_scope.sh --overlap` output per stage, redirected there;
- `dod-dry-run.md` — each dry-run command with its class and the tail of its output (from
  the `run_logged.sh` summary or its log, never the full output)
  ([worker-spec-template.md](worker-spec-template.md#dod-dry-run));
- the absolute path of `source_worktree` (the code the plan was written against).

## Prompt
```markdown
# Plan Critic

You review a refactoring plan written by someone else. You are read-only: do not edit,
create, or delete files, and do not run tests, builds, installs, or git commands that change
state. Reading files and searching (`git grep`, `rg`, `git log`, `git show`) are allowed.

- Code: <source_worktree absolute path>
- Plan files: <run dir>/gap-report.md, spec-<slug>.md, <slug>.wl, plan.md,
  overlap-stage-<n>.txt, dod-dry-run.md

Find concrete problems in four areas. Each finding needs evidence from the code or the plan
files — no evidence, no finding. Do not restate the plan or comment on style.

1. whitelist — a file the task must change to meet its goal or DoD but its whitelist misses:
   callers of a symbol it changes, tests, fixtures, registry/index/route files, config.
2. dependency — a missing edge between tasks (B uses a symbol, schema, or behaviour A
   changes; grep for every symbol a spec adds, renames, or removes), or two tasks in one
   stage that share a file or hot spot (lockfile, migration, common fixture).
3. dod — a DoD that would pass without the fix (only "no error" checks, a test the Worker
   could skip or weaken, a lint-only DoD for a behaviour change), or a behavioural criterion
   that no command checks.
4. coverage — a gap-report finding that no task claims, or a task whose goal reaches beyond
   its findings.

Output only this list, most severe first:
n. [category][H|M|L] <task slug> — <evidence: file:line, grep result, or plan line> → <suggested change>
End with "No findings" if there are none.
```

## Dispatch
The Critic runs in phase 1. If any task is **H**-risk, use the phase 1 Lead model and effort
(`lead`); otherwise use `lead_phase2`, which is enough to check a plan of L/M tasks and reads
the many files the critic opens at a fraction of the cost. Never use a Worker or scout model.

| Runtime | Call |
| :--- | :--- |
| Claude Code | `Agent` with `subagent_type: Plan` (no edit tools), `model` as above (`opus` or `sonnet`), the prompt above. No `isolation`. |
| Codex | `codex exec -C "<source_worktree>" -m "<critic model>" -c model_reasoning_effort="<critic effort>" -s read-only -o "<run dir>/critic.md" - < "<run dir>/critic-prompt.md"` |
| Antigravity | `(cd "<source_worktree>" && agy -p "$(cat "<run dir>/critic-prompt.md")" --model "<critic model>" --mode plan --output-format text) > "<run dir>/critic.md"` |

Afterwards re-run the step 0 baseline command on `source_worktree`; it must still match.

## Lead disposition
One round only; do not argue with the Critic or re-run it on the revised plan.
For each finding:
1. Check the evidence yourself (open the file, re-run the grep). Unverified claims are
   `rejected — not reproducible`.
2. Mark it `accepted` (state the spec/plan change you made) or `rejected` (one-line reason).
3. Accepted findings change the specs before the checkpoint. If a change adds a dependency
   edge or moves a task between stages, re-run `check_scope.sh --overlap` for the stages
   affected and redo the dry run for any DoD you changed.

At the checkpoint, show the Critic column in the decision matrix (`2 accepted · 1 rejected`)
and list every rejected **H** finding under "Decisions for you", with your reason.
