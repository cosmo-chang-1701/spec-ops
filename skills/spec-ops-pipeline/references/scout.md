# Scouts (read-only audit sweeps)

Scouts are cheap read-only subagents that sweep a large audit scope for candidate issues, so
the phase 1 Lead reads only the spots they point at instead of every file. They only collect
leads; the Lead verifies each one, judges severity, and writes the gap report.

## When to run
At step 1, when the agreed scope holds more than about 30 tracked files or spans two or more
top-level directories. For a smaller scope read the code yourself and skip scouts.

Split the scope into non-overlapping areas — one directory, or one concern (security / perf /
debt) over a directory — and give each scout one area. At most `max_parallel` scouts.

## Prompt
```markdown
# Scout: <area>

You sweep code for candidate issues. You are read-only: do not edit, create, or delete
files, and do not run tests, builds, installs, or git commands that change state. Reading
files and searching (`git grep`, `rg`, `git log`, `git show`) are allowed.

- Code: <source_worktree absolute path>
- Your area: <paths>
- Look for: <concern(s) agreed with the user, with concrete examples of what counts>

Output only this, at most 30 items, most suspicious first:
n. <file:line> — <pattern> — <one line of evidence: the code or grep hit>
Then one line: "Clean: <files you read that had nothing>".
No fixes, no severity, no file contents beyond the one evidence line.
```

## Dispatch
Use the `scout` block from `detect_runtime.sh`. Dispatch every scout at once (Claude Code:
all `Agent` calls in one message).

| Runtime | Call |
| :--- | :--- |
| Claude Code | `Agent` with `subagent_type: Explore`, `model: <scout.dispatch_model>` (`haiku`), the prompt above. No `isolation`. |
| Codex | `codex exec -C "<source_worktree>" -m "<scout.model>" -c model_reasoning_effort="<scout.effort>" -s read-only -o "<run dir>/scout-<area>.md" - < "<run dir>/scout-<area>-prompt.md"` |
| Antigravity | `(cd "<source_worktree>" && agy -p "$(cat "<run dir>/scout-<area>-prompt.md")" --model "<scout.dispatch_model>" --mode plan --output-format text) > "<run dir>/scout-<area>.md"` |

Afterwards re-run the step 0 baseline command on `source_worktree`; it must still match.

## Lead disposition
- A lead is not evidence. Open the cited lines yourself (with a small range, not the whole
  file) before it becomes a gap-report finding; drop what you cannot confirm.
- Severity, the proposed fix, and the task grouping are yours.
- Lint, test, and type-check commands are still run by you through `run_logged.sh`; scouts do
  not replace them.
- Areas a scout reports as clean need no re-read unless a finding elsewhere points there.
