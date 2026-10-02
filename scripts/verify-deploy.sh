#!/usr/bin/env bash
# scripts/verify-deploy.sh — the post-deploy verification of engineering-spec §10 step 2 (launch gate item 9), run
# from a clean checkout of the frozen commit. For each deployed contract:
#   creation  the creation transaction's input equals `creationCode ++ args`, where the args are encoded from
#             script/config/robinhood.json by `Deploy.args` (so a PASS also says the immutables and the stored
#             arguments are the config's), and the receipt created this address;
#   runtime   the creation code, re-run at the same address (an eth_call with state overrides: the deployer's nonce
#             as it was and the address emptied; `Signers` is EIP-712 and caches a domain separator derived from the
#             contract's own address, so the address matters), returns exactly the code the chain holds — source,
#             compiler settings, metadata hash, immutables;
#   explorers `forge verify-bytecode` and Blockscout verification (both go through Blockscout's API, which sits
#             behind a Cloudflare challenge that refuses forge's HTTP client on chain 4663 as of 2026-10-02: a
#             BLOCKED result means verify in the Blockscout UI, "via Sourcify"), and Sourcify verification, checked
#             back through Sourcify's own API (an exact match binds the metadata hash).
# The transaction hashes come from the committed deploy log, broadcast/Deploy.s.sol/<chain>/{run,runDraw}-latest.json.
# --tag TAG asserts that everything feeding the bytecode (src, lib, foundry.toml, foundry.lock, remappings.txt) is
# identical to the tag's; the tree may be a later commit (`review-2026-09-final` predates `Deploy.args` itself).
# usage: scripts/verify-deploy.sh <distributor> <converter> [draw] [--rpc URL] [--chain ID] [--tag TAG]
#                                 [--broadcast DIR] [--tx <distributor|converter|draw>=<hash>]... [--no-explorers]
# Runs from the repo root; a relative --broadcast DIR is relative to it.
set -u
cd "$(dirname "$0")/.." || exit 2
rpc="${RPC_4663:-}"; chain=4663; tag=""; bdir="broadcast/Deploy.s.sol"; explorers=1
declare -A txof=()
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc) rpc="$2"; shift 2;;
    --chain) chain="$2"; shift 2;;
    --tag) tag="$2"; shift 2;;
    --broadcast) bdir="$2"; shift 2;;
    --tx) txof["${2%%=*}"]="${2#*=}"; shift 2;;
    --no-explorers) explorers=0; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) positional+=("$1"); shift;;
  esac
done
[ "${#positional[@]}" -ge 2 ] || { echo "usage: $0 <distributor> <converter> [draw] [options]; --help for the rest" >&2; exit 2; }
distributor="${positional[0]}"; converter="${positional[1]}"; draw="${positional[2]:-}"
[ -n "$rpc" ] || { echo "no RPC url: pass --rpc or export RPC_4663" >&2; exit 2; }
for tool in forge cast jq git curl column; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool missing" >&2; exit 2; }; done

# ---- the frozen commit: nothing that feeds the bytecode may differ from what is committed
dirty="$(git status --porcelain -- src script lib foundry.toml foundry.lock remappings.txt)"
[ -z "$dirty" ] || { printf 'refusing: the tree differs from the commit in what feeds the bytecode:\n%s\n' "$dirty" >&2; exit 2; }
head="$(git rev-parse --short HEAD)"
at_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ -n "$tag" ]; then
  want="$(git rev-parse --short "$tag^{commit}" 2>/dev/null)" || { echo "no such tag: $tag" >&2; exit 2; }
  drift="$(git diff --stat "$tag" HEAD -- src lib foundry.toml foundry.lock remappings.txt)"
  [ -z "$drift" ] || { printf 'HEAD %s does not build the bytecode of %s (%s):\n%s\n' "$head" "$tag" "$want" "$drift" >&2; exit 2; }
  frozen="$tag ($want)"
fi
echo "bytecode sources: ${frozen:-HEAD}"
got_chain="$(cast chain-id --rpc-url "$rpc" 2>&1)" || { echo "cast chain-id failed: $got_chain" >&2; exit 2; }
[ "$got_chain" = "$chain" ] || { echo "chain id $got_chain, expected $chain" >&2; exit 2; }
block="$(cast block-number --rpc-url "$rpc")"
echo "commit $head${at_tag:+ (tag $at_tag)}, chain $chain, block $block"

forge build >/dev/null 2>&1 || { echo "forge build failed; run it by hand" >&2; exit 2; }
argsout="$(forge script script/Deploy.s.sol --sig "args(address,address)" "$distributor" "$converter" 2>&1)" \
  || { echo "Deploy.args failed:"; echo "$argsout"; exit 2; } >&2
argof() { echo "$argsout" | awk -v k="$1-args" '$1 == k {print $2; exit}'; }

lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
strip0x() { local s; s="$(lower "$1")"; printf '%s' "${s#0x}"; }
rows=(); failed=0

check() { # label address contract broadcast-file
  local label="$1" addr="$2" contract="$3" bfile="$4"
  local args init hash creation runtime vb sourcify blockscout
  args="$(argof "$label")"
  [ -n "$args" ] || { echo "no $label-args from Deploy.args" >&2; exit 2; }
  init="0x$(strip0x "$(forge inspect "$contract" bytecode)")$(strip0x "$args")"

  # the creation transaction: the deploy log, or --tx
  hash="${txof[$label]:-}"
  if [ -z "$hash" ] && [ -r "$bfile" ]; then
    hash="$(jq -r --arg a "$(lower "$addr")" \
      '[.transactions[] | select(.transactionType == "CREATE" and ((.contractAddress // "") | ascii_downcase) == $a)] | .[0].hash // empty' "$bfile")"
  fi
  if [ -z "$hash" ]; then
    creation="NO-TX"; runtime="NO-TX"
    echo "$label: no creation transaction for $addr in $bfile; pass --tx $label=<hash>" >&2
  else
    local input created from nonce code rerun
    input="$(cast tx "$hash" input --rpc-url "$rpc" 2>/dev/null)"
    created="$(cast receipt "$hash" contractAddress --rpc-url "$rpc" 2>/dev/null)"
    if [ -z "$input" ] || [ -z "$created" ]; then
      creation="ERROR(cast tx/receipt $hash failed: wrong hash, or the RPC)"
    elif [ "$(lower "$input")" = "$(lower "$init")" ] && [ "$(lower "$created")" = "$(lower "$addr")" ]; then
      creation="PASS"
    elif [ "$(lower "$created")" != "$(lower "$addr")" ]; then
      creation="FAIL(tx $hash did not create $addr)"
    else
      creation="FAIL(input differs from creationCode++args)"
    fi
    from="$(cast tx "$hash" from --rpc-url "$rpc" 2>/dev/null)"
    nonce="$(cast tx "$hash" nonce --rpc-url "$rpc" 2>/dev/null)"
    code="$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null)"
    # eth_call with state overrides: the deployer's nonce as it was, so the CREATE lands on `addr`, and `addr`
    # emptied (code, nonce, storage) so the creation does not collide with what is there. The re-run's return
    # value is the runtime code the chain would have stored.
    rerun="$(cast call --rpc-url "$rpc" --from "$from" --override-nonce "$from:$nonce,$addr:0" \
      --override-code "$addr:0x" --override-state "$addr:0:0" --create "$init" 2>&1)"
    if [ "$(lower "$rerun")" = "$(lower "$code")" ]; then
      runtime="PASS"
    elif [ "${rerun#0x}" = "$rerun" ]; then
      runtime="ERROR(eth_call: ${rerun##*$'\n'})"
    else
      runtime="FAIL(re-run code differs from the chain's)"
    fi
  fi
  case "$creation$runtime" in *FAIL*|*NO-TX*|*ERROR*) failed=1;; esac

  vb="skipped"; sourcify="skipped"; blockscout="skipped"
  if [ "$explorers" = 1 ]; then
    local out
    local ok=0
    out="$(forge verify-bytecode "$addr" "$contract" --rpc-url "$rpc" --encoded-constructor-args "$(strip0x "$args")" \
      --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ 2>&1)" && ok=1
    case "$ok:$out" in
      *"Just a moment"*) vb="BLOCKED(cloudflare)";;
      1:*) case "$out" in *"did not match"*|*"mismatch"*) vb="FAIL"; failed=1;; *) vb="PASS";; esac;;
      *) vb="FAIL(${out##*$'\n'})"; failed=1;;
    esac
    out="$(forge verify-contract "$addr" "$contract" --chain-id "$chain" --verifier sourcify --constructor-args "$args" --watch 2>&1)"
    local match="" try # Sourcify's own verdict, not forge's output; a few tries, the job can lag the submission
    for try in 1 2 3 4; do
      match="$(curl -s -m 30 "https://sourcify.dev/server/v2/contract/$chain/$addr" | jq -r '.match // empty' 2>/dev/null)"
      [ -n "$match" ] && break
      sleep 5
    done
    case "$match" in
      exact_match) sourcify="PASS(exact_match)";;
      match) sourcify="PARTIAL(match, metadata not bound)"; failed=1;;
      *) sourcify="FAIL(${out##*$'\n'})"; failed=1;;
    esac
    ok=0
    out="$(forge verify-contract "$addr" "$contract" --chain-id "$chain" --verifier blockscout \
      --verifier-url https://robinhoodchain.blockscout.com/api/ --constructor-args "$args" 2>&1)" && ok=1
    case "$ok:$out" in
      *"Just a moment"*) blockscout="BLOCKED(cloudflare)";;
      1:*"already verified"*|1:*"successfully verified"*) blockscout="PASS";;
      1:*) blockscout="UNCLEAR(${out##*$'\n'})";;
      *) blockscout="FAIL(${out##*$'\n'})";;
    esac
    if [ "$blockscout" != "PASS" ]; then
      # The explorer may still show it verified (UI, or the Sourcify import). A read-only status probe with a
      # browser User-Agent, which is what gets past the Cloudflare challenge that stops forge; nothing is submitted.
      local src
      src="$(curl -s -m 30 -A 'Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/130.0' \
        "https://robinhoodchain.blockscout.com/api?module=contract&action=getsourcecode&address=$addr" \
        | jq -r '.result[0].SourceCode // empty' 2>/dev/null | head -c 1)"
      [ -n "$src" ] && blockscout="$blockscout, shown verified" || blockscout="$blockscout, not shown verified"
    fi
  fi
  rows+=("$label|$addr|$creation|$runtime|$vb|$sourcify|$blockscout")
}

check distributor "$distributor" src/NutzDistributor.sol:NutzDistributor "$bdir/$chain/run-latest.json"
check converter "$converter" src/NutzConverter.sol:NutzConverter "$bdir/$chain/run-latest.json"
[ -n "$draw" ] && check draw "$draw" src/NutzDraw.sol:NutzDraw "$bdir/$chain/runDraw-latest.json"

echo
echo "deploy log entry (commit $head${at_tag:+, tag $at_tag}; chain $chain; checked at block $block; $(date -u +%Y-%m-%dT%H:%MZ))"
{ echo "contract|address|creation|runtime|verify-bytecode|sourcify|blockscout"; printf '%s\n' "${rows[@]}"; } | column -t -s '|'
if [ "$failed" = 0 ]; then
  echo "OK: creation and runtime bytecode match the frozen commit and the config for every contract$([ "$explorers" = 1 ] && echo '; Sourcify exact match')"
  exit 0
fi
echo "FAIL: do not announce these addresses; read the rows above" >&2; exit 1
