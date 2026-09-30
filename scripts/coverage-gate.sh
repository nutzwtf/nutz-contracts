#!/usr/bin/env bash
# scripts/coverage-gate.sh — fails unless every non-vendor src/ file in an LCOV report has 100% branch coverage.
# usage: scripts/coverage-gate.sh [lcov.info]
set -u
lcov="${1:-lcov.info}"
[ -r "$lcov" ] || { echo "no LCOV report at $lcov" >&2; exit 2; }
# One line per SF record: file, branches hit / branches found. Only src/ counts; src/vendor/ is skipped here as
# well as in foundry.toml's coverage skip_files, so the gate holds if that setting ever goes.
awk -F: '
  /^SF:/  { sf = $2; brf = 0; brh = 0 }
  /^BRF:/ { brf = $2 }
  /^BRH:/ { brh = $2 }
  /^end_of_record/ && sf ~ /^src\// && sf !~ /^src\/vendor\// {
    printf "%-28s %s/%s branches%s\n", sf, brh, brf, (brh == brf ? "" : "  <-- below 100%")
    if (brh != brf) bad++
    seen++
  }
  END {
    if (!seen) { print "no src/ records in the report" > "/dev/stderr"; exit 2 }
    exit bad > 0
  }
' "$lcov"
