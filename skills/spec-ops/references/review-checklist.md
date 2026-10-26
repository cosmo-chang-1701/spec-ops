# PR Review Checklist

A Worker's diff is reviewed on the **`lead` model** (phase 1: `claude-opus-5-5` · high by
default), not on the cheaper phase 2 Lead model. Review the task diff, not the whole repo.

Only review once the gates pass: `check_scope.sh` exits 0 **and** you re-ran every DoD
command yourself in the worktree through `run_logged.sh` (never trust the Worker's report
alone). A failed gate is a REQUEST_CHANGES round without a review (it still sets the
task's `ever_rejected`, see [disposition](#lead-disposition)).

## Who reviews
- `split` session — the phase 2 Lead is on a cheaper model, so it dispatches a read-only
  **Reviewer** on the `lead` model ([below](#reviewer-subagent)) and decides on its findings
  ([disposition](#lead-disposition)). Tasks of a stage can be reviewed in parallel, up to
  `max_parallel` Reviewers at once.
- `single` session — the Lead already runs on the `lead` model: review the diff yourself with
  the checks below, with no subagent.

## What to check, in priority order
1. **Correctness** — logic errors, unhandled edge cases (empty/null/boundary/concurrency),
   error paths that swallow failures, resource leaks.
2. **Spec conformance** — every Goal / DoD criterion met; nothing beyond the Goal
   (unrequested refactors, renamed symbols, reformatted unrelated lines).
3. **Tests** — new behaviour is covered; tests assert outcomes (not just "no exception");
   no tests deleted, skipped, or weakened to make the DoD pass.
4. **Safety** — no secrets, no disabled lint rules / type ignores without justification,
   no new dependencies unless the spec allowed them.
5. **Consistency** — matches surrounding naming, error-handling, and comment style.

Do not report style nits a linter would catch, or pre-existing issues outside the diff
(record those as follow-up audit findings instead).

Read the diff against the recorded base. Start with the stat; read the full diff only when
it is small, otherwise file by file (append `-- <path>`), so a large change does not flood the
context:

```bash
base=$(cat "$(git -C <worktree> rev-parse --absolute-git-dir)/so-base")
git -C <worktree> diff "$base" --stat
git -C <worktree> diff "$base" [-- <path>]
```

In later rounds, review only what changed since the previous round: note the files the
findings named and re-read just those, plus any new entries in `--stat`.

## Verdict format

```markdown
## Review: <task-slug> — round <n>/3
Verdict: APPROVE | REQUEST_CHANGES

Gates: scope ✅/❌ · DoD ✅/❌ (<commands re-run>)

Findings (blocking first):
1. [blocking] path/to/file.py:42 — <what is wrong> → <required change>
2. [non-blocking] path/to/file.py:77 — <suggestion>
```

## Reviewer subagent
Write the inputs to `<run dir>/review-<slug>-r<n>-input.md`: the worktree's absolute path, the
base SHA (`so-base`), the path of `spec-<slug>.md`, the round number, the gate summary lines
(the `run_logged.sh` line of each command), and from round 2 the previous round's findings.
Then dispatch with the `lead` block of `detect_runtime.sh` (model, effort, `dispatch_model`):

| Runtime | Call |
| :--- | :--- |
| Claude Code | `Agent` with `subagent_type: Plan` (no edit tools), `model: <lead.dispatch_model>`, `effort: <lead.effort>`, the prompt below. No `isolation`. |
| Codex | `codex exec -C "<worktree>" -m "<lead.model>" -c model_reasoning_effort="<lead.effort>" -s read-only -o "<run dir>/review-<slug>-r<n>.md" - < "<run dir>/review-<slug>-r<n>-prompt.md"` |
| Antigravity | `(cd "<worktree>" && agy -p "$(cat "<run dir>/review-<slug>-r<n>-prompt.md")" --model "<lead.dispatch_model>" --mode plan --output-format text) > "<run dir>/review-<slug>-r<n>.md"` |

```markdown
# Code Reviewer

You review a change written by someone else. You are read-only: do not edit, create, or
delete files, and do not run tests, builds, installs, or git commands that change state.
Reading files and searching (`git diff`, `git show`, `git log`, `git grep`, `rg`) are allowed.

Inputs: <run dir>/review-<slug>-r<n>-input.md (worktree, base SHA, spec, round, gate results,
previous findings). Review `git -C <worktree> diff <base>` against the spec.

[the "What to check" list and the "Do not report" paragraph above]

Round 2 and later: review only the files the previous findings named and new `--stat`
entries, and say for each previous finding whether it is fixed.

Every blocking finding needs `file:line` evidence from the diff or the code it touches — no
evidence, no finding. Output only the verdict in this format:
[the "Verdict format" block above]
```

Afterwards re-run the step 0 baseline command on `source_worktree`; it must still match.

## Lead disposition
1. Open the `file:line` of every blocking finding yourself. One you cannot reproduce is
   `rejected — not reproducible`; note it in the verdict.
2. A verified blocking finding remains → REQUEST_CHANGES; none remain → APPROVE.
3. You may add a **non-blocking** finding the Reviewer missed, never a blocking one of your
   own. If you think something blocking was missed, re-dispatch the Reviewer for the same
   round with that file named.
4. Record the verdict as `<run dir>/review-<slug>-r<n>-verdict.md`. If the verdict is
   REQUEST_CHANGES, set the task's `ever_rejected` to `true` in `state.json`.

## Loop rules
- REQUEST_CHANGES → send the Worker the numbered blocking findings plus the original spec
  (same worktree, same whitelist), and store the findings as the task's `open_findings` in
  `state.json`. Max **3 rounds**; after that, stop and escalate to the user
  with the remaining findings. A `light` task's first REQUEST_CHANGES escalates it to the
  `worker` model instead ([models.md](models.md#worker-tier)).
- A finding that requires a file outside the whitelist is a spec change: ask the user before
  widening the whitelist. With parallel tasks, also check the new file is not in another
  task's whitelist for the same stage.
- Parallel tasks are reviewed and counted separately; one task's rounds never block or reset
  another's.
- APPROVE (`independent` mode) → no question to the user: the checkpoint approval already
  covers the commit, push and PR. Continue with
  [execution-plan.md §4a](execution-plan.md#4a-after-approve-independent-mode).
- APPROVE (`staged` mode) → hold the task at the stage barrier. When the whole stage is
  approved, commit locally under the checkpoint approval (no push), integrate, and run the
  integration gate per [execution-plan.md](execution-plan.md). An integration-gate failure
  becomes a REQUEST_CHANGES round for the responsible task.
