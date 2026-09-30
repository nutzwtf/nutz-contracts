#!/usr/bin/env bash
# scripts/semgrep.sh — runs Semgrep with the Decurity smart-contract rules over src/, the way CI does.
# usage: scripts/semgrep.sh [extra semgrep args]      (needs `semgrep` on PATH: `uv tool install semgrep`)
#
# The rules repo is pinned to a commit (last touched 2025-06-02) and cloned into semgrep-rules/ (gitignored) on
# first use. Rule ids are derived from that directory name, so the exclusions below depend on it.
set -euo pipefail
# semgrep-core opens an io_uring by default and fails with "Cannot allocate memory" under a small RLIMIT_MEMLOCK
# (8 MiB in some shells); the POSIX backend needs none of it.
export EIO_BACKEND="${EIO_BACKEND:-posix}"
cd "$(dirname "$0")/.."

RULES_REPO=https://github.com/Decurity/semgrep-smart-contracts
RULES_SHA=2e878a89ac7bba1f8435e8a68e3ecb7700096cd5   # master @ 2025-06-02, rules v1.2.1
RULES_DIR=semgrep-rules

if [ ! -d "$RULES_DIR/.git" ] || [ "$(git -C "$RULES_DIR" rev-parse HEAD)" != "$RULES_SHA" ]; then
  rm -rf "$RULES_DIR"
  git init -q "$RULES_DIR"
  git -C "$RULES_DIR" fetch -q --depth 1 "$RULES_REPO" "$RULES_SHA"
  git -C "$RULES_DIR" checkout -q FETCH_HEAD
fi

# Only the `security/` and `best-practice/` rule sets run. `performance/` is gas-style advice (prefix increments,
# unchecked loop counters, payable constructors): not security, already covered by `forge lint`'s gas severity,
# and the contracts are frozen for review.
#
# Triaged false positives, one rule each (both are taint rules with confidence LOW in their own metadata):
#   basic-arithmetic-underflow  — written for pre-0.8 code (its references are the 2022 Umbrella Network hack);
#                                 this repo compiles with 0.8.37 checked arithmetic, so every flagged subtraction
#                                 reverts instead of wrapping, and each site is either preceded by an explicit
#                                 bound check (`postRoot`, `voidRoot`, `pushClaims`) or documents the revert
#                                 (`NutzDraw.roundAt` before GENESIS).
#   exact-balance-check         — the two `== 0` guards on `address(this).balance` / `balanceOf(this)` in the
#                                 Converter decide only "is there anything to sweep/sell"; a donated wei just
#                                 makes a tiny run happen. Same reasoning as the `incorrect-equality`
#                                 slither-disable comments at those lines.
exec semgrep scan \
  --config "$RULES_DIR/solidity/security" \
  --config "$RULES_DIR/solidity/best-practice" \
  --exclude-rule "$RULES_DIR.solidity.security.basic-arithmetic-underflow" \
  --exclude-rule "$RULES_DIR.solidity.security.exact-balance-check" \
  --metrics=off --error "$@" src/
