#!/usr/bin/env bash
# scripts/doctor.sh — prints every tool the repo depends on and its version.
set -u
ok=0; bad=0
check() {
  printf '%-12s' "$1"
  if command -v "$1" >/dev/null 2>&1; then echo "$($2 2>&1 | head -1)"; ok=$((ok+1)); else echo "MISSING"; bad=$((bad+1)); fi
}
check forge    "forge --version"
check cast     "cast --version"
check anvil    "anvil --version"
check chisel   "chisel --version"
check slither  "slither --version"
check aderyn   "aderyn --version"
check z3       "z3 --version"
check gitleaks "gitleaks version"
check node     "node --version"
check pnpm     "pnpm --version"
check uv       "uv --version"
check mise     "mise --version"
echo "ok=$ok missing=$bad"
[ "$bad" -eq 0 ]
