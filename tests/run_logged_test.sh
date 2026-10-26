#!/usr/bin/env bash
# Tests for run_logged.sh.  Run: bash tests/run_logged_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R=$SCRIPTS/run_logged.sh

section "success"
out=$(bash "$R" "$WORK/logs/ok.log" 'seq 1 5000; echo done >&2'); rc=$?
check_eq "exit 0" "$rc" 0
check_eq "prints exactly one line" "$(wc -l <<<"$out")" 1
check_eq "summary line" "$out" "exit=0 lines=5001 log=$WORK/logs/ok.log"
check "log dir created, full output kept" grep -qx 5000 "$WORK/logs/ok.log"
check "stderr captured" grep -qx done "$WORK/logs/ok.log"

section "failure"
out=$(bash "$R" "$WORK/logs/fail.log" 'seq 1 1000; echo boom >&2; exit 3'); rc=$?
check_eq "command's exit code kept" "$rc" 3
check "summary reports exit=3" grep -q '^exit=3 lines=1001 ' <<<"$out"
check_eq "summary + marker + default 40-line tail" "$(wc -l <<<"$out")" 42
check_eq "tail ends with the error" "$(tail -n 1 <<<"$out")" boom
out=$(SO_LOG_TAIL=5 bash "$R" "$WORK/logs/fail.log" 'seq 1 100; exit 1')
check_eq "SO_LOG_TAIL limits the tail" "$(wc -l <<<"$out")" 7
check_eq "log replaced, not appended" "$(wc -l <"$WORK/logs/fail.log")" 100

section "command semantics"
mkdir -p "$WORK/cwd" && touch "$WORK/cwd/marker"
(cd "$WORK/cwd" && bash "$R" "$WORK/logs/cwd.log" 'test -f marker' >/dev/null); rc=$?
check_eq "runs in the current directory" "$rc" 0
bash "$R" "$WORK/logs/pipe.log" 'false | true; exit ${PIPESTATUS[0]}' >/dev/null; rc=$?
check_eq "shell syntax in the command string" "$rc" 1
(cd "$WORK" && bash "$R" rel.log 'true' >/dev/null)
check "relative log path resolved" test -f "$WORK/rel.log"

section "usage"
bash "$R" "$WORK/x.log" >/dev/null 2>&1; rc=$?
check_eq "missing command: exit 2" "$rc" 2
SO_LOG_TAIL=abc bash "$R" "$WORK/x.log" true >/dev/null 2>&1; rc=$?
check_eq "bad SO_LOG_TAIL: exit 2" "$rc" 2

finish
