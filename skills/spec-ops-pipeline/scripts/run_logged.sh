#!/usr/bin/env bash
# Run a command with its output going to a log file, not to the caller's context.
#
# Usage: run_logged.sh <log-file> '<command string>'
#
# Runs the command with `bash -c` in the current directory; stdout and stderr go to
# <log-file> (parent dirs are created, an existing file is replaced). Prints one line,
#   exit=<rc> lines=<n> log=<path>
# and on failure also the last ${SOP_LOG_TAIL:-40} lines of the log. Exits with the
# command's own exit code, so it can stand in for the command in a gate.
# Exit codes: the command's, or 2 for a usage error.
set -uo pipefail

die() { printf 'run_logged: %s\n' "$*" >&2; exit 2; }

case ${1:-} in
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[[ $# -eq 2 && -n $1 && -n $2 ]] || die "usage: run_logged.sh <log-file> '<command string>'"
log=$1 command=$2
tail_lines=${SOP_LOG_TAIL:-40}
[[ $tail_lines =~ ^[0-9]+$ ]] || die "SOP_LOG_TAIL must be a number"

mkdir -p "$(dirname "$log")" || die "cannot create the log directory for $log"
log=$(realpath -m "$log")
bash -c "$command" >"$log" 2>&1 </dev/null
rc=$?
lines=$(wc -l <"$log")
printf 'exit=%d lines=%d log=%s\n' "$rc" "$lines" "$log"
if ((rc != 0 && tail_lines > 0)); then
  printf -- '--- last %d lines ---\n' "$tail_lines"
  tail -n "$tail_lines" "$log"
fi
exit "$rc"
