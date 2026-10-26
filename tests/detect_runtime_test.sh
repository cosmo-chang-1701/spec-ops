#!/usr/bin/env bash
# Tests for detect_runtime.sh.  Run: bash tests/detect_runtime_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D=$SCRIPTS/detect_runtime.sh
# A clean env so the caller's agent markers and API keys do not leak into detection.
run() { env -i PATH="$PATH" HOME="$WORK" "$@" bash "$D" --agent "$AGENT"; }

section "claude defaults"
AGENT=claude; out=$(run)
check_eq "lead model" "$(json_get '["lead"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "lead effort" "$(json_get '["lead"]["effort"]' <<<"$out")" high
check_eq "phase 2 lead model" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "phase 2 lead effort" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" high
check_eq "lead dispatch alias" "$(json_get '["lead"]["dispatch_model"]' <<<"$out")" opus
check_eq "phase 2 lead dispatch alias" "$(json_get '["lead_phase2"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "worker model" "$(json_get '["worker"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "worker effort" "$(json_get '["worker"]["effort"]' <<<"$out")" medium
check_eq "worker dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "light worker model" "$(json_get '["worker_light"]["model"]' <<<"$out")" claude-haiku-5-5
check_eq "light worker effort" "$(json_get '["worker_light"]["effort"]' <<<"$out")" medium
check_eq "light worker dispatch alias" "$(json_get '["worker_light"]["dispatch_model"]' <<<"$out")" haiku
check_eq "scout model" "$(json_get '["scout"]["model"]' <<<"$out")" claude-haiku-5-5
check_eq "scout effort" "$(json_get '["scout"]["effort"]' <<<"$out")" low
check_eq "scout dispatch alias" "$(json_get '["scout"]["dispatch_model"]' <<<"$out")" haiku

section "gemini defaults"
AGENT=gemini; out=$(run)
check_eq "lead model" "$(json_get '["lead"]["model"]' <<<"$out")" gemini-4-argon-high
check_eq "phase 2 lead model" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" gemini-3.8-flash-high
check_eq "phase 2 lead effort" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" high
check_eq "lead dispatch alias" "$(json_get '["lead"]["dispatch_model"]' <<<"$out")" gemini-4-argon-high
check_eq "worker model" "$(json_get '["worker"]["model"]' <<<"$out")" gemini-3.8-flash-high
check_eq "worker dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" gemini-3.8-flash-high
check_eq "light worker = worker" "$(json_get '["worker_light"]' <<<"$out")" "$(json_get '["worker"]' <<<"$out")"
check_eq "scout = worker" "$(json_get '["scout"]' <<<"$out")" "$(json_get '["worker"]' <<<"$out")"

section "codex: phase 2 lead = lead"
AGENT=codex; out=$(run)
check_eq "codex" "$(json_get '["lead_phase2"]' <<<"$out")" "$(json_get '["lead"]' <<<"$out")"
check_eq "light worker: same model" "$(json_get '["worker_light"]["model"]' <<<"$out")" "$(json_get '["lead"]["model"]' <<<"$out")"
check_eq "light worker effort" "$(json_get '["worker_light"]["effort"]' <<<"$out")" low
check_eq "scout effort" "$(json_get '["scout"]["effort"]' <<<"$out")" low

section "overrides"
AGENT=claude; out=$(run SOP_LEAD2_MODEL=claude-opus-5-5 SOP_LEAD2_EFFORT=medium SOP_LEAD_EFFORT=max SOP_WORKER_MODEL=haiku)
check_eq "SOP_LEAD2_MODEL" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "SOP_LEAD2_EFFORT" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" medium
check_eq "SOP_LEAD2_MODEL sets the dispatch alias" "$(json_get '["lead_phase2"]["dispatch_model"]' <<<"$out")" claude-opus-5-5
check_eq "SOP_LEAD_MODEL sets the dispatch alias" "$(json_get '["lead"]["dispatch_model"]' <<<"$(run SOP_LEAD_MODEL=sonnet)")" sonnet
check_eq "SOP_LEAD_EFFORT leaves phase 2 alone" "$(json_get '["lead_phase2"]["effort"]' <<<"$(run SOP_LEAD_EFFORT=max)")" high
check_eq "SOP_WORKER_MODEL sets the dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" haiku
out=$(run SOP_WORKER_LIGHT_MODEL=sonnet SOP_WORKER_LIGHT_EFFORT=low SOP_SCOUT_MODEL=sonnet SOP_SCOUT_EFFORT=medium)
check_eq "SOP_WORKER_LIGHT_MODEL sets the dispatch alias" "$(json_get '["worker_light"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "SOP_WORKER_LIGHT_EFFORT" "$(json_get '["worker_light"]["effort"]' <<<"$out")" low
check_eq "SOP_SCOUT_MODEL sets the dispatch alias" "$(json_get '["scout"]["dispatch_model"]' <<<"$out")" sonnet
check_eq "SOP_SCOUT_EFFORT" "$(json_get '["scout"]["effort"]' <<<"$out")" medium
check_eq "session split defaults to auto" "$(json_get '["session_split"]' <<<"$out")" auto
check_eq "SOP_SESSION_SPLIT" "$(json_get '["session_split"]' <<<"$(run SOP_SESSION_SPLIT=never)")" never
run SOP_SESSION_SPLIT=bogus >/dev/null 2>&1; rc=$?
check_eq "invalid SOP_SESSION_SPLIT: exit 2" "$rc" 2

section "detection"
check_eq "--agent wins over runtime markers" \
  "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" --agent codex | json_get '["ecosystem"]')" codex
check_eq "Claude Code marker" "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" | json_get '["ecosystem"]')" claude
bash "$D" --agent other >/dev/null 2>&1; rc=$?
check_eq "invalid --agent: exit 2" "$rc" 2

finish
