# Model assignment

`bash SKILL_DIR/scripts/detect_runtime.sh --agent <claude|gemini|codex>` prints one block per
role. Pass **your own runtime** (you know which CLI you are running in; the flag beats env
heuristics — e.g. a Claude Code session may also have `GEMINI_API_KEY` set).

## Roles and defaults

| Role | Runs | Claude (Claude Code) | Gemini (Antigravity) | Codex |
| :--- | :--- | :--- | :--- | :--- |
| `lead` | Phase 1: preflight, audit, spec, checkpoint | `claude-opus-5-5` · high | `gemini-4-argon-high` · high | `model` from `~/.codex/config.toml` · high |
| `lead_phase2` | Phase 2: dispatch, gate, review, close-out | `claude-sonnet-5-5` · high | `gemini-3.8-flash-high` · high | same as `lead` |
| `worker` | Standard tasks | `claude-sonnet-5-5` · medium | `gemini-3.8-flash-high` · high | same model · medium |
| `worker_light` | Light tasks ([tiers](#worker-tier)) | `claude-haiku-5-5` · medium | same as `worker` | same model · low |
| `scout` | Read-only audit sweeps ([scout.md](scout.md)) | `claude-haiku-5-5` · low | same as `worker` | same model · low |
| Reviewer | Read-only review of a Worker's diff ([review-checklist.md](review-checklist.md#reviewer-subagent)) | `lead` | `lead` | `lead` |
| Plan Critic | [plan-critic.md](plan-critic.md) | `lead` if any task is H-risk, else `lead_phase2` | same rule | same rule |

Unknown ecosystems fall back to the Claude column. Each block also has `dispatch_model`, the
value to pass to the runtime's dispatch call (`opus`, `sonnet`, `haiku` in Claude Code). A
`single`-session run needs no Reviewer subagent: the Lead already runs on `lead`.

Overrides: `SOP_LEAD_MODEL`, `SOP_LEAD_EFFORT`, `SOP_LEAD2_MODEL`, `SOP_LEAD2_EFFORT`,
`SOP_WORKER_MODEL`, `SOP_WORKER_EFFORT`, `SOP_WORKER_LIGHT_MODEL`, `SOP_WORKER_LIGHT_EFFORT`,
`SOP_SCOUT_MODEL`, `SOP_SCOUT_EFFORT`. Setting a model also sets its `dispatch_model`.

## Lead model per phase
If you are not running as the Lead model of the current phase, tell the user how to switch
(`/model`, `/effort` in Claude Code); do not silently continue. Exception: a `single`-session
run ([SKILL.md](../SKILL.md#sessions-and-context)) keeps the phase 1 Lead model for phase 2.

## Worker tier
Decide each task's tier at step 2 and show it in the decision matrix's **Worker** column
([execution-plan.md §3](execution-plan.md#3-checkpoint-report)); the user may override it
with the approval. A task is `light` only when **all** of these hold:
- Risk **L**;
- mechanical and behaviour-preserving: rename, move, dead-code removal, lint or type fixes,
  docstrings — no new logic;
- the whitelist covers at most 5 files (`check_scope.sh --list`);
- its DoD can tell done from not done: at least one command is not `PASS`, or the touched
  code is covered by tests the DoD runs.

Everything else is `standard`. Record the tier as `worker_tier` in `state.json`.

**Escalation** — when a `light` task gets REQUEST_CHANGES in round 1 (a failed gate counts),
set `worker_tier` to `standard` and re-dispatch it on the `worker` model. A Worker blocked on a
non-whitelisted file is a spec problem, not a model one: handle it per the review checklist
(ask the user before widening the whitelist) without escalating. The re-dispatch is a new
dispatch (not a message to the old Worker, which keeps its model) with the full spec plus the
`open_findings`, into the same worktree — as on [resume](../SKILL.md#resume-phase-2). Add a
section above the spec's Repo rules telling the new Worker that the worktree already holds the
earlier round's uncommitted changes, to keep them, and to fix only the numbered findings.
Rounds keep counting; escalation does not reset them.
