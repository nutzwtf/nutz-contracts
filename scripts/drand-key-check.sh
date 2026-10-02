#!/usr/bin/env bash
# scripts/drand-key-check.sh — the human check of engineering-spec §10 step 2 before the Draw stage: drand's quicknet
# `/info` must publish the public key NutzDraw hard-codes (compressed form, re-derived from the eight limbs by
# test/unit/BlsVerifier.t.sol), and its genesis time and period must equal `GENESIS` and `PERIOD` in src/NutzDraw.sol.
# A wrong key would make the Draw's constructor self-test revert `VerifierSelfTestFailed`; a changed chain would be a
# different beacon altogether. Reads the constants out of the sources, so the check follows the code.
# usage: scripts/drand-key-check.sh [info-url]
set -u
url="${1:-https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info}"
cd "$(dirname "$0")/.." || exit 2
for tool in curl jq; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing" >&2; exit 2; }; done

want_key="$(awk '/PUBLIC_KEY_COMPRESSED =/{f=1} f{printf "%s", $0} f && /;/{exit}' test/unit/BlsVerifier.t.sol \
  | grep -o 'hex"[0-9a-f]*"' | sed 's/^hex"//; s/"$//' | tr -d '\n')"
want_genesis="$(grep -o 'constant GENESIS = [0-9_]*' src/NutzDraw.sol | sed 's/.*= //; s/_//g')"
want_period="$(grep -o 'constant PERIOD = [0-9_]*' src/NutzDraw.sol | sed 's/.*= //; s/_//g')"
[ "${#want_key}" = 192 ] || { echo "could not read PUBLIC_KEY_COMPRESSED (96 bytes) from test/unit/BlsVerifier.t.sol" >&2; exit 2; }
[ -n "$want_genesis" ] && [ -n "$want_period" ] || { echo "could not read GENESIS / PERIOD from src/NutzDraw.sol" >&2; exit 2; }

info="$(curl -s -m 30 "$url")" || { echo "fetch failed: $url" >&2; exit 2; }
got_key="$(echo "$info" | jq -r '.public_key // empty')"
got_genesis="$(echo "$info" | jq -r '.genesis_time // empty')"
got_period="$(echo "$info" | jq -r '.period // empty')"
got_scheme="$(echo "$info" | jq -r '.schemeID // empty')"
got_beacon="$(echo "$info" | jq -r '.metadata.beaconID // empty')"
[ -n "$got_key" ] || { echo "no public_key in the response: $info" >&2; exit 2; }

fail=0
printf 'beacon %s, scheme %s\n' "$got_beacon" "$got_scheme"
if [ "$got_key" = "$want_key" ]; then echo "public_key   MATCH  ${got_key:0:16}…${got_key: -8}"; else fail=1; printf 'public_key   MISMATCH\n  drand %s\n  code  %s\n' "$got_key" "$want_key"; fi
if [ "$got_genesis" = "$want_genesis" ]; then echo "genesis_time MATCH  $got_genesis"; else fail=1; echo "genesis_time MISMATCH drand $got_genesis, code $want_genesis"; fi
if [ "$got_period" = "$want_period" ]; then echo "period       MATCH  $got_period"; else fail=1; echo "period       MISMATCH drand $got_period, code $want_period"; fi
[ "$got_scheme" = "bls-unchained-g1-rfc9380" ] || { fail=1; echo "scheme       UNEXPECTED $got_scheme (the Draw verifies G1 signatures under RFC 9380 hashing)"; }
[ "$fail" = 0 ] && { echo "OK: the quicknet key, genesis and period match src/NutzDraw.sol"; exit 0; }
echo "FAIL: do not deploy the Draw against this beacon" >&2; exit 1
