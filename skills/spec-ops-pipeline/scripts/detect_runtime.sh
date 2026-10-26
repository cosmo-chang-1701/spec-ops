#!/usr/bin/env bash
# Detect the agent ecosystem and resolve Lead / Worker model assignments.
#
# Usage: detect_runtime.sh [--agent claude|gemini|codex]
#
# Detection priority (first hit wins):
#   1. --agent flag            (the running agent knows who it is; most reliable)
#   2. SOP_ECOSYSTEM env var   (user override)
#   3. Runtime markers         (env vars injected by the agent CLI itself)
#   4. API keys                (only when exactly ONE provider key is present;
#                               several keys at once are common and ambiguous)
#   5. Fallback                (claude)
#
# Roles: "lead" runs phase 1 (preflight, audit, spec, checkpoint); "lead_phase2" runs
# phase 2 (dispatch, gate, review, close-out) in a fresh session; "worker" implements;
# "worker_light" implements small mechanical L-risk tasks; "scout" sweeps code read-only
# during the audit (see references/models.md). The read-only Reviewer of a Worker's diff runs
# on "lead" (use its dispatch_model).
# Per-field overrides: SOP_LEAD_MODEL, SOP_LEAD_EFFORT, SOP_LEAD2_MODEL, SOP_LEAD2_EFFORT,
# SOP_WORKER_MODEL, SOP_WORKER_EFFORT, SOP_WORKER_LIGHT_MODEL, SOP_WORKER_LIGHT_EFFORT,
# SOP_SCOUT_MODEL, SOP_SCOUT_EFFORT.
# Session split: SOP_SESSION_SPLIT = auto (default: split only multi-task or H-risk runs),
# always, or never; reported as "session_split".
# Output: a single JSON object on stdout.
set -euo pipefail

readonly VALID_ECOSYSTEMS="claude gemini codex"
readonly CODEX_DEFAULT_MODEL="gpt-5.4"

die() { printf 'detect_runtime: %s\n' "$*" >&2; exit 2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

is_valid_ecosystem() { [[ " $VALID_ECOSYSTEMS " == *" $1 "* ]]; }

has_env_prefix() {
  # Succeeds if any exported variable name matches the ERE (anchored at name start).
  compgen -e | grep -Eq "^($1)"
}

codex_configured_model() {
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml" model=""
  if [[ -r $config ]]; then
    # Top-level `model = "..."` only (before the first [table] header).
    model=$(awk '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{gsub(/^[^=]*=[[:space:]]*"|".*$/, ""); print; exit}' "$config")
  fi
  printf '%s' "${model:-$CODEX_DEFAULT_MODEL}"
}

agent_flag=""
while (($#)); do
  case $1 in
    --agent) [[ $# -ge 2 ]] || die "--agent needs a value"; agent_flag=$2; shift 2 ;;
    --agent=*) agent_flag=${1#*=}; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

session_split=${SOP_SESSION_SPLIT:-auto}
case $session_split in
  auto|always|never) ;;
  *) die "SOP_SESSION_SPLIT must be one of: auto always never" ;;
esac

ecosystem="" detected_by=""
if [[ -n $agent_flag ]]; then
  is_valid_ecosystem "$agent_flag" || die "--agent must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$agent_flag detected_by="flag:--agent"
elif [[ -n ${SOP_ECOSYSTEM:-} ]]; then
  is_valid_ecosystem "$SOP_ECOSYSTEM" || die "SOP_ECOSYSTEM must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$SOP_ECOSYSTEM detected_by="env:SOP_ECOSYSTEM"
elif [[ -n ${CLAUDECODE:-} ]] || has_env_prefix 'CLAUDE_CODE_'; then
  ecosystem=claude detected_by="runtime:claude-code"
elif has_env_prefix 'CODEX_(SANDBOX|THREAD_ID|SESSION|MANAGED)'; then
  ecosystem=codex detected_by="runtime:codex"
elif has_env_prefix 'ANTIGRAVITY_|AGY_|JETSKI|GEMINI_CLI'; then
  ecosystem=gemini detected_by="runtime:antigravity-or-gemini-cli"
else
  keys=()
  [[ -n ${ANTHROPIC_API_KEY:-} ]] && keys+=(claude)
  [[ -n ${GOOGLE_API_KEY:-}${GEMINI_API_KEY:-} ]] && keys+=(gemini)
  [[ -n ${OPENAI_API_KEY:-} ]] && keys+=(codex)
  if ((${#keys[@]} == 1)); then
    ecosystem=${keys[0]} detected_by="api-key:single"
  else
    ecosystem=claude detected_by="fallback(api-keys=${#keys[@]})"
  fi
fi

case $ecosystem in
  claude)
    lead_model=claude-opus-5-5   lead_effort=high   lead_alias=opus
    lead2_model=claude-sonnet-5-5 lead2_effort=high lead2_alias=sonnet
    worker_model=claude-sonnet-5-5 worker_effort=medium
    worker_alias=sonnet
    light_model=claude-haiku-5-5   light_effort=medium light_alias=haiku
    scout_model=claude-haiku-5-5   scout_effort=low    scout_alias=haiku ;;
  gemini)
    # Antigravity encodes effort in the model id (see `agy models`).
    lead_model=gemini-4-argon-high     lead_effort=high  lead_alias=$lead_model
    lead2_model=gemini-3.8-flash-high  lead2_effort=high lead2_alias=$lead2_model
    worker_model=gemini-3.8-flash-high worker_effort=high
    worker_alias=gemini-3.8-flash-high
    light_model=$worker_model light_effort=$worker_effort light_alias=$worker_alias
    scout_model=$worker_model scout_effort=$worker_effort scout_alias=$worker_alias ;;
  codex)
    lead_model=$(codex_configured_model) lead_effort=high
    lead_alias=$lead_model
    lead2_model=$lead_model              lead2_effort=$lead_effort lead2_alias=$lead_model
    worker_model=$lead_model             worker_effort=medium
    worker_alias=$lead_model
    light_model=$lead_model              light_effort=low light_alias=$lead_model
    scout_model=$lead_model              scout_effort=low scout_alias=$lead_model ;;
esac

lead_model=${SOP_LEAD_MODEL:-$lead_model}
lead_effort=${SOP_LEAD_EFFORT:-$lead_effort}
[[ -n ${SOP_LEAD_MODEL:-} ]] && lead_alias=$SOP_LEAD_MODEL
lead2_model=${SOP_LEAD2_MODEL:-$lead2_model}
lead2_effort=${SOP_LEAD2_EFFORT:-$lead2_effort}
[[ -n ${SOP_LEAD2_MODEL:-} ]] && lead2_alias=$SOP_LEAD2_MODEL
worker_model=${SOP_WORKER_MODEL:-$worker_model}
worker_effort=${SOP_WORKER_EFFORT:-$worker_effort}
[[ -n ${SOP_WORKER_MODEL:-} ]] && worker_alias=$SOP_WORKER_MODEL
light_model=${SOP_WORKER_LIGHT_MODEL:-$light_model}
light_effort=${SOP_WORKER_LIGHT_EFFORT:-$light_effort}
[[ -n ${SOP_WORKER_LIGHT_MODEL:-} ]] && light_alias=$SOP_WORKER_LIGHT_MODEL
scout_model=${SOP_SCOUT_MODEL:-$scout_model}
scout_effort=${SOP_SCOUT_EFFORT:-$scout_effort}
[[ -n ${SOP_SCOUT_MODEL:-} ]] && scout_alias=$SOP_SCOUT_MODEL

printf '{"ecosystem":"%s","detected_by":"%s","lead":{"model":"%s","effort":"%s","dispatch_model":"%s"},"lead_phase2":{"model":"%s","effort":"%s","dispatch_model":"%s"},"worker":{"model":"%s","effort":"%s","dispatch_model":"%s"},"worker_light":{"model":"%s","effort":"%s","dispatch_model":"%s"},"scout":{"model":"%s","effort":"%s","dispatch_model":"%s"},"session_split":"%s"}\n' \
  "$ecosystem" "$(json_escape "$detected_by")" \
  "$(json_escape "$lead_model")" "$(json_escape "$lead_effort")" "$(json_escape "$lead_alias")" \
  "$(json_escape "$lead2_model")" "$(json_escape "$lead2_effort")" "$(json_escape "$lead2_alias")" \
  "$(json_escape "$worker_model")" "$(json_escape "$worker_effort")" "$(json_escape "$worker_alias")" \
  "$(json_escape "$light_model")" "$(json_escape "$light_effort")" "$(json_escape "$light_alias")" \
  "$(json_escape "$scout_model")" "$(json_escape "$scout_effort")" "$(json_escape "$scout_alias")" \
  "$session_split"
