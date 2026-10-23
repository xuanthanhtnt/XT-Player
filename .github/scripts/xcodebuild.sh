#!/usr/bin/env bash
# Runs xcodebuild with the given arguments, keeps the full log in $XCODE_LOG (default build.log),
# prints a compact summary, and turns compiler errors into GitHub annotations.
set -uo pipefail

LOG="${XCODE_LOG:-build.log}"
mkdir -p "$(dirname "$LOG")"

xcodebuild "$@" >"$LOG" 2>&1
status=$?

# Compiler / linker diagnostics → ::error / ::warning annotations (deduplicated, capped).
grep -E "^/.+:[0-9]+:[0-9]+: (error|warning): " "$LOG" | sort -u | head -n 60 | while IFS= read -r line; do
  file="${line%%:*}"; rest="${line#*:}"
  ln="${rest%%:*}"; rest="${rest#*:}"
  col="${rest%%:*}"; rest="${rest#*: }"
  kind="${rest%%:*}"; msg="${rest#*: }"
  file="${file#"${GITHUB_WORKSPACE:-$PWD}"/}"
  echo "::${kind} file=${file},line=${ln},col=${col}::${msg}"
done

if [ $status -ne 0 ]; then
  echo "::group::Errors"
  grep -E "error:|fatal error|ld: |Undefined symbols|clang: error" "$LOG" | sort -u | head -n 120 || true
  echo "::endgroup::"
  echo "::group::Last 80 lines of $LOG"
  tail -n 80 "$LOG"
  echo "::endgroup::"
  echo "::error::xcodebuild failed (exit $status) — full log uploaded as an artifact."
  exit $status
fi

grep -E "^\*\* .* SUCCEEDED \*\*|Executed [0-9]+ tests?" "$LOG" | tail -n 5 || true
# Surface the test summary as an annotation so it is visible without opening the log.
summary=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$LOG" | tail -n 1 | sed -E 's/^[[:space:]]+//')
[ -n "$summary" ] && echo "::notice title=Tests::${summary}"
exit 0
