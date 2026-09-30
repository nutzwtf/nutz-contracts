#!/usr/bin/env bash
# scripts/bls-precompiles-live.sh — runs the EIP-2537 vectors in test/fixtures/bls/eip2537.json against the chain's own
# node with `cast call`, positives and fail-* alike. `forge test` (fork tests included) executes precompiles in the
# local revm, so only this run proves the BLS12-381 precompiles NutzDraw relies on behave on chain 4663 (ArbOS 61).
# Manual, pre-deploy: engineering-spec §10 step 2, security-review launch gate item 10.
# usage: scripts/bls-precompiles-live.sh [rpc-url]   (default $RPC_4663, exported by mise from .env)
set -u
rpc="${1:-${RPC_4663:-}}"
fixture="$(dirname "$0")/../test/fixtures/bls/eip2537.json"
[ -n "$rpc" ] || { echo "no RPC url: pass one or export RPC_4663" >&2; exit 2; }
[ -r "$fixture" ] || { echo "no fixture at $fixture (pnpm -C tooling gen:bls-fixtures)" >&2; exit 2; }
for tool in cast jq; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing" >&2; exit 2; }; done

chain="$(cast chain-id --rpc-url "$rpc" 2>&1)" || { echo "cast chain-id failed: $chain" >&2; exit 2; }
[ "$chain" = "4663" ] || { echo "chain id $chain, expected 4663 (Robinhood Chain)" >&2; exit 2; }
echo "chain 4663, block $(cast block-number --rpc-url "$rpc"), $(jq -r '.sources | length' "$fixture") upstream files, commit $(jq -r '.sources[0].commit' "$fixture")"

addr() { printf '0x%040x' "$1"; }
pass=0; fail=0

# positives: the call must succeed and return exactly `expected`
while IFS=$'\t' read -r name precompile input expected; do
  got="$(cast call --rpc-url "$rpc" "$(addr "$precompile")" "$input" 2>&1)"
  if [ "$got" = "$expected" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'MISMATCH %s (0x%02x)\n  expected %s\n  got      %s\n' "$name" "$precompile" "$expected" "$got"; fi
done < <(jq -r '.vectors.positive[] | [.name, .precompile, .input, .expected] | @tsv' "$fixture")
echo "positives: $pass returned the expected output, $fail did not"

# fail-*: the call must error; the node's message is compared with the EIP's for information only
p2=0; f2=0; other=0
while IFS=$'\t' read -r name precompile input error; do
  if got="$(cast call --rpc-url "$rpc" "$(addr "$precompile")" "$input" 2>&1)"; then
    f2=$((f2+1)); printf 'ACCEPTED %s (0x%02x): expected error "%s", got %s\n' "$name" "$precompile" "$error" "$got"
  else
    p2=$((p2+1))
    case "$got" in *"$error"*) ;; *) other=$((other+1)); printf 'errored, other message: %s: %s\n' "$name" "${got##*: }";; esac
  fi
done < <(jq -r '.vectors.fail[] | [.name, .precompile, .input, .expectedError] | @tsv' "$fixture")
echo "fail vectors: $p2 errored ($other with a message other than the EIP's), $f2 were accepted"

if [ "$fail" -eq 0 ] && [ "$f2" -eq 0 ]; then echo "OK: the chain's EIP-2537 precompiles agree with every vector"; exit 0; fi
echo "FAIL: the chain's precompiles disagree with $((fail+f2)) vector(s)" >&2; exit 1
