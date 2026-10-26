# Worker Spec Template

The Lead fills one spec per task and passes it **verbatim** as the Worker's prompt.
Everything the Worker needs must be in here — it has no access to the Lead's conversation.
Save the Whitelist section to a file too; `check_scope.sh` consumes it.

```markdown
# Worker Spec: <task-slug>

## Role
You are the Worker (implementer) in a Lead-Worker workflow. You modify code ONLY inside
the worktree below and ONLY files matched by the Whitelist. The Lead will reject any
change outside it. Do not commit, push, merge, rebase, or touch other worktrees/branches.

- Worktree (your working root): <absolute path>
- Branch: so/<task-slug> (already checked out; base <short sha>)
- Stage: <n>/<total> · Base includes: <slugs of earlier tasks already merged in, or "none">

Other Workers may be editing other files in other worktrees at the same time. Never read,
write, or run commands in any worktree but your own.

## Repo rules
<Rules from the repo's AGENTS.md / CLAUDE.md that apply to this task (how and where to run
 tests, lint, type checks; required flags; language rules), known repo pitfalls from the
 Lead's memory, and any `worker_notes` — one bullet each.>
- Provisioned files listed by `worktree.sh create` (`.env*` copies, `.venv` symlinks into the
  source worktree) are secret or shared: never edit or delete them, never install packages
  into a linked venv.
- Format and lint only with the versions the repo pins (e.g. `pre-commit run <hook> --files
  <files you changed>`), never with another locally installed formatter, and never over the
  whole tree — a different version rewrites unrelated files.
- Docker Compose derives its project name from the directory name, which is the same in
  every worktree (e.g. `app/`), so all worktrees share one set of images, volumes, and
  networks. Use only `docker compose run --rm ...`; never `build`, `up`, or `down` (the
  Lead's `worktree.sh remove` stops what `run` leaves behind). If the DoD needs a rebuilt
  image (Dockerfile or dependency changes), stop and report.

## Goal
<One or two sentences: the outcome, not the steps.>

## Context
<Audit findings this task resolves, each with file:line and why it matters.
 Relevant conventions (naming, error handling, test layout) observed in the codebase.
 If this task depends on earlier ones: what they changed that you can now rely on
 (new APIs, renamed symbols, changed behaviour), with file:line in your base.>

## Whitelist
<One glob per line, repo-relative. `**` spans dirs, `*` one segment, trailing `/` = whole dir,
 `!pattern` forbids. Include test files you expect the Worker to add or edit.>

    src/payments/**
    tests/payments/**
    !src/payments/vendor/**

## Forbidden
- Files outside the Whitelist (including lockfiles, CI config, formatter config) unless listed.
- New dependencies, public API signature changes, or disabling/skipping tests and lint rules
  — unless explicitly allowed here: <exceptions or "none">.

## Steps (suggested, not mandatory)
1. <...>
2. <...>

## Definition of Done
Every command must exit 0 when run from the worktree root. The `# baseline:` note is how
each command behaved on your base before any change: `FAIL-EXPECTED` commands fail because
of the problem you are fixing — make them pass; `PASS` commands already pass — keep them
passing; `NOT-YET` commands need files you will add.

    <test command, e.g. pytest tests/payments -q>        # baseline: FAIL-EXPECTED (test_duplicate_charge)
    <lint command, e.g. ruff check src/payments tests/payments>   # baseline: PASS
    <type check / build, if applicable>                  # baseline: <...>

Plus these behavioural criteria:
- <e.g. "duplicate charge path at src/payments/charge.py:88 is unreachable; covered by a test">

## If blocked
If the DoD cannot be met without touching a non-whitelisted file, STOP and report the file
and the reason instead of editing it.

## Report back (final message)
Keep it short — the Lead re-runs every DoD command itself.
1. Summary of changes per file (one line each).
2. Each DoD command with its exit code; for a non-zero exit, only its last 20 lines. Do not
   paste full output.
3. Anything skipped, assumed, or left for follow-up.
```

## DoD dry run
Before the checkpoint, the Lead runs every DoD command once on the code the Worker will start
from, so a broken or unreachable DoD never reaches a Worker:
- `independent` mode and stage 1: in `source_worktree` (where step 1 ran the tests);
- stage 2+: in the task's worktree right after `worktree.sh create`, before dispatch — its
  base `so-stage/<n-1>` does not exist at the checkpoint.

Run each command through `run_logged.sh` (log `<run dir>/logs/<slug>-dry-<n>.log`), so only
its exit code and, on failure, its tail reach the Lead. Classify each command and write the
class into the spec as `# baseline: <class>`; collect command, class, and tail in
`<run dir>/dod-dry-run.md`:

| Class | Meaning | Action |
| :--- | :--- | :--- |
| `PASS` | Already exits 0 | Keep (regression guard). A behaviour-change task needs at least one command that is not `PASS` — otherwise the DoD cannot tell fixed from unfixed. |
| `FAIL-EXPECTED` | Fails because of the finding this task fixes | Ideal. Note the failing test or message. |
| `NOT-YET` | Needs a file the Worker will add (e.g. a new test file) | Prove the runner works instead: `pytest --collect-only tests/payments`, `command -v <tool>`. |
| `BROKEN` | Command not found, wrong flags or working directory, missing tool or env | Fix the command before the checkpoint. |
| `FAIL-UNRELATED` | Fails for a reason outside this task (pre-existing failure, flaky test, missing service) | The Worker cannot reach it within the whitelist. Narrow the command, split off the failure as its own finding, or list it under "Decisions for you". |

Afterwards re-run the step 0 baseline command on `source_worktree`. If it changed, a DoD
command writes files that are not gitignored — stop and report; the same files would fail
the Worker's scope gate.

In stage 2+ a fix that only changes how a command is invoked (path, flag, working directory)
and not what it checks may be applied without new approval; say so in the dispatch summary.
Any other change to a DoD needs the user's approval.

## Lead checklist before dispatching
- [ ] Slug is kebab-case and matches the worktree branch.
- [ ] Worker tier (`light` / `standard`) meets [models.md](models.md#worker-tier).
- [ ] Whitelist is the minimum set; tests are included.
- [ ] Every DoD item is a runnable command or an objectively checkable statement, and
      follows the Repo rules (working directory, flags, allowed tools).
- [ ] Every DoD command was dry-run and carries a `# baseline:` class; none is `BROKEN`,
      and every `FAIL-UNRELATED` was resolved or approved by the user.
- [ ] Repo rules cover the repo's agent docs, relevant pitfalls, and every `worker_notes` entry.
- [ ] The task is in the execution plan; its stage, dependencies, and base ref match it,
      and its whitelist does not overlap any other task in the same stage
      (`check_scope.sh --overlap` shows no `OVERLAP`; every `POSSIBLE` was checked).
- [ ] The user has approved this spec (Phase 2 checkpoint).
