# Review: `Signers` (2-of-3 base) and `IKeeper`

- Contract: `Signers` (abstract; inherited by `NutzDistributor` and `NutzConverter`)
- Files: `/home/eduar/code/nutz/nutz-contracts/src/Signers.sol`, `/home/eduar/code/nutz/nutz-contracts/src/interfaces/IKeeper.sol`; call sites read in `src/NutzDistributor.sol` (lines 47-52, 263-323, 423-429, 493-520) and `src/NutzConverter.sol` (lines 66-79, 117-119, 210, 262-295, 427-443)
- Commit tag: `review-2026-09-rc1` (74d724c); OpenZeppelin 5.7.0 (`EIP712`, `ECDSA`)
- Spec: engineering-spec v0.6.2 §2.2, §3.2, §6, §10; CONTEXT.md "Signer"

## How the base is used (facts the checklist relies on)

Every privileged entry point hashes a struct that ends in the storage `nonce` and passes it to `_require2of3`, which recovers two addresses with `ECDSA.recover` (reverts on bad length, high-`s`, bad `v`, zero address), rejects `a == b`, requires both in `signers[3]`, then `nonce++`. Eleven typehashes, all distinct strings: `SetKeeper`, `RotateSigner`, `Cancel` (base); `PostRoot`, `VoidRoot`, `SetRateRange`, `SetDrawContract`, `AppendExcluded` (Distributor); `SetOpsCap`, `DisableLeg`, `EnableLeg` (Converter). Instant: `setKeeper`, `postRoot`, `voidRoot`, `setRateRange`, `setOpsCap`, `disableLeg`, `cancel`. Timelocked: `proposeSignerRotation`, `proposeDrawContract`, `proposeExclusion`, `proposeLegEnable` (2-of-3 at propose, nonce consumed there; `execute*` permissionless, no nonce, re-checks conditions). Queue id = `keccak256(abi.encode(TYPEHASH, args))` without the nonce. Domain: `EIP712(name, "1")` with `name` = `"NutzDistributor"` / `"NutzConverter"`; OZ binds `block.chainid` and `address(this)` and recomputes the separator if either changes. `PostRoot` hashes `uint256[5] totals` as `keccak256(abi.encode(totals))`, which is the EIP-712 array rule. Every argument of every signed call is inside the struct; no caller-chosen field is unsigned.

## Checklist

| # | Item | Verdict |
|---|---|---|
| 1 | §6 bad root: only 2-of-3 posts or voids | OK. `postRoot`/`voidRoot` go through `_require2of3`; two distinct current signers over the exact `(kind,id,root,totals,nonce)`. |
| 1 | §6 keeper key compromise: keeper cannot post a root alone; replaceable without timelock | OK. `onlyKeeper` never gates a signed action; `setKeeper` is instant 2-of-3 (§3.2). Note: `robinhood.json` makes the keeper key signer 3 (item 7). |
| 1 | §6 router/token, blocklist, Pons, sybil | N/A for the base; the circuit-breaker path `disableLeg` correctly uses the instant 2-of-3 and `EnableLeg` the timelock. |
| 1 | §6 reentrancy: "nonReentrant on all external state-changing functions" | Info F-5. The four `Signers` externals have no modifier, but make no external call (ecrecover is a builtin), so no reentrancy path exists. |
| 1 | §6 no admin backdoors | OK. No owner, no proxy, no pause; the only Signer powers are the eleven listed actions; none moves a token. |
| 1 | §6 monitoring events | OK. `KeeperSet`, `Scheduled(id, readyAt)`, `Executed`, `Cancelled`, `SignerRotated` all emitted; `readyAt` and `signers` are public. |
| 2 | SOL-HMT-1..5 (Merkle) | N/A (Distributor). |
| 2 | SOL-Signature-1 replay within the contract | OK. Global nonce in every struct, consumed on success; a signature is valid at exactly one nonce. |
| 2 | SOL-Signature-2 malleability | OK. OZ 5.7.0 `recover` reverts `ECDSAInvalidSignatureS` on high-`s` and on bad `v`; signatures are never map keys; a malleated copy recovers the same signer at an already-consumed nonce. |
| 2 | SOL-Signature-3 recovered signer matches | OK. `_isSigner(a)`, `_isSigner(b)`, `a != b`; the same key twice (or the same bytes twice) reverts `SameSigner`. |
| 2 | SOL-Signature-4 deadline | Info F-2. No expiry field; freshness is the nonce only, which on the Converter moves rarely. |
| 2 | SOL-Signature-5 address(0) from failed ecrecover | OK. OZ reverts `ECDSAInvalidSignature` on a zero recovery, and no signer slot can ever be zero (constructor line 46, `_checkRotation` line 92). |
| 2 | SOL-AM-ReplayAttack-1 cross-contract | OK. Distributor and Converter share the three keys and the same struct names, but the domain differs in `name` and `verifyingContract`; each has its own nonce. |
| 2 | SOL-AM-ReplayAttack-2 cross-chain | OK. `chainId` in the domain; OZ `_domainSeparatorV4` recomputes when `block.chainid` differs from the cached value. |
| 2 | SOL-LL-4 precompile staticcall | N/A. The only precompile is `ecrecover` through OZ, which checks the result. |
| 2 | SOL-McCc-1 block.number/timestamp | OK. `block.number` unused; `block.timestamp` only in `_schedule`/`_consume` (item 4). |
| 2 | SOL-McCc-3, 12 opcodes, PUSH0 | OK. Nothing beyond `keccak256`, `ecrecover`, `timestamp`, `chainid`; PUSH0 is live since ArbOS 11. |
| 2 | SOL-Defi-AS-12 | N/A (Converter). |
| 3 | Merkle leaf domain separation | N/A. |
| 4 | Arbitrum semantics | OK. Timestamp skew (−24 h / +1 h, non-decreasing) bounds the real 48 h delay to [23 h, 73 h] and shifts the 7-day TTL by the same amount; no loss, no lock. `prevrandao`/`blockhash` unused. |
| 5 | Stock Token pause/blocklist | N/A. |
| 6 | EIP-2537 G1ADD | N/A. |
| 7 | Constructor args in `robinhood.json` | OK with note. Domain names match §2.2/§3.2; three distinct non-zero signers; keeper non-zero; keeper `0x7c3a…5214` equals `signers[2]`, which matches §3.2 custody (one signer key lives on the keeper host) and §5 step 3. The file's own `_comment` marks signers and keeper as TODO, so re-check at the frozen commit. §10 step 1 lists "keeper, cold A, cold B" and omits the warm recompute signer named in §3.2: a spec inconsistency, not a code one. |
| 8 | Shadowing at NutzConverter.sol:68, 69, 78 | OK (false positive). `Params.signers`, `Params.keeper`, `Params.opsCap` are struct members reached only as `p.x`; they cannot capture the `Signers.signers`, `Signers.keeper`, `opsCap` state variables. Rename to `signers_`-style if the detector must be silent. 692 and BLS2.sol:370: N/A. |
| 9 | Timelock id collisions | OK. Ids are `keccak256(abi.encode(TYPEHASH, args))`; distinct typehash per action, separate storage per contract; the same `(action,args)` twice reverts `AlreadyScheduled`. |
| 9 | Same signature for a different action | OK. Typehash is the first word of every struct hash. |
| 9 | Removed signer's old signatures | OK. Membership is checked at submission against the current `signers`; after `executeSignerRotation(C, D)`, anything C signed reverts `NotSigner(C)`. |
| 9 | Pending proposals across a rotation or keeper change | Info F-3 (rotation); OK for keeper (the keeper is not part of any proposal; `execute*` is permissionless; the Draw reads `keeper()` at call time). |
| 9 | Expired proposals | Low F-1. |
| 9 | Global nonce and the hourly root | Info F-6. |

Tally: OK 22, N/A 9, findings 6 (1 Low, 5 Info).

## Findings

### F-1 An expired proposal is never cleared and blocks the identical proposal until a `cancel` ceremony
- Severity: Low
- Location: `src/Signers.sol:98-103` (`_schedule`), `:106-117` (`_consume`)
- Spec line: §3.2 "Timelocked (… execute by anyone after 48h, cancel with 2-of-3, expires 7 days after ready)"; §2.2 `executeLegEnable` "(7-day TTL, cancellable with `Signers.cancel`)"
- Transaction sequence:
  1. Day 0: SPY is paused by its issuer; Signers A+B `disableLeg(0, s1, s2)` on the Converter (nonce 5 → 6). Every Sweep now pays SPY's `perStock` (15 % of each Sweep, e.g. 1,500 USDG of a 10,000 USDG Sweep) as USDG.
  2. Day 3: SPY resumes; A+B `proposeLegEnable(0, s1, s2)` (nonce 6 → 7); `readyAt[id_SPY] = day 5`.
  3. Nobody calls `executeLegEnable(0)` before day 12 (an outage, a holiday). Day 13: `executeLegEnable(0)` reverts `Expired`; `readyAt[id_SPY]` is still `day 5`, not zero.
  4. A+B sign a fresh `EnableLeg(0, nonce 7)` and call `proposeLegEnable(0, …)`: reverts `AlreadyScheduled` at line 99, because the stale entry is non-zero.
  5. Recovery needs `cancel(id_SPY, …)` (nonce 7 → 8) and then `proposeLegEnable(0, …)` (nonce 8 → 9) and a new 48 h wait. The same holds for a rotation `(from,to)`, a draw address and an exclusion address.
- Impact: no funds lost; the Leg stays in USDG mode (or the rotation/exclusion stays pending) for one extra 2-of-3 ceremony plus 48 h. "Expires" in the spec reads as "is gone"; in code an expired entry is a permanent tombstone until cancelled. The `readyAt` getter and `Scheduled` history cannot tell a live proposal from an expired one without the timestamp arithmetic.
- Suggested fix: in `_schedule`, treat an expired entry as empty: `uint256 r = readyAt[id]; if (r != 0 && block.timestamp <= r + PROPOSAL_TTL) revert AlreadyScheduled();`. Alternatively have `_consume` `delete readyAt[id]` and emit `Cancelled`/`Expired` before reverting (costs a state write in a reverting call, so the first form is better). Document either in §3.2.

### F-2 Signed approvals carry no deadline; they stay valid until the contract's nonce moves, which on the Converter can be months
- Severity: Info
- Location: `src/Signers.sol:121-129`; every typehash in the three contracts
- Spec line: none violated; Solodit SOL-Signature-4
- Transaction sequence:
  1. Converter nonce is 3 and has been for six weeks (Converter governance is rare; only `setOpsCap`, `disableLeg`, `proposeLegEnable`, `setKeeper`, rotation, `cancel` move it).
  2. During an issuer-pause scare A and B each sign `DisableLeg(stock=0, nonce=3)` and send the signatures to the keeper operator over the ops channel; the scare passes and nobody submits.
  3. Two months later anyone holding the two 65-byte signatures (a leaked chat export, a decommissioned keeper host) calls `disableLeg(0, s1, s2)`: it succeeds. The next Sweep pays SPY's 25 % of the Stash slice as USDG (on a 10,000 USDG Sweep: 1,500 USDG of USDG instead of SPY). Re-enabling costs a 2-of-3 plus 48 h.
  4. The same applies to a stale `SetKeeper(k, nonce)` (redirects the Ops Slice and push fees to `k` instantly) and to a stale `SetOpsCap`.
- Impact: no loss; a state change the signers approved once can be applied at a time they did not choose. On the Distributor the exposure is bounded by the hourly `postRoot`, which bumps the nonce within about an hour.
- Suggested fix: add `uint256 deadline` to every struct and `if (block.timestamp > deadline) revert Expired();` in `_require2of3` (or per call site), or state in the Signer runbook that a signature is only ever produced for immediate submission and that a stale one is invalidated by any Converter ceremony.

### F-3 A rotation does not cancel pending proposals; a removed signer's earlier approval still executes
- Severity: Info
- Location: `src/Signers.sol:74-80` (`executeSignerRotation`), `:106-117` (`_consume` has no signer check)
- Spec line: §3.2 (silent on this)
- Transaction sequence:
  1. Signers A, B, C. C's key is suspected compromised. Before that, B+C had signed `proposeExclusion(X)` (an exchange deposit address) on the Distributor; `readyAt[id_X] = T+48h`.
  2. A+B `proposeSignerRotation(C, D)`; 48 h later anyone `executeSignerRotation(C, D)`; `signers = [A, B, D]`.
  3. Anyone calls `executeExclusion(X)`: succeeds, although one of its two approvers is no longer a signer. Likewise a pending `EnableLeg` or `SetDrawContract` co-signed by C.
- Impact: none by itself (a proposal needed one honest signer too, and `cancel` by A+B removes it). It is a runbook item: on any rotation, enumerate `Scheduled` events without a matching `Executed`/`Cancelled` and decide each one. Cancelling costs one nonce each.
- Suggested fix: none in code (recording the approving pair per id would cost storage for little); add the enumeration step to the Signer runbook in §6.

### F-4 Wrong comment: the Ops Slice destination is not timelocked
- Severity: Info
- Location: `src/NutzConverter.sol:427` ("The destination is `keeper`, set only through the Signers' timelock")
- Spec line: §3.2 "`KEEPER` … Replaced by 2-of-3 without timelock"; §2.2 `setKeeper` listed with the instant actions
- Transaction sequence: A+B `setKeeper(K2, s1, s2)` on the Converter at block N; at block N+1 `sweep` sends `opsAmt` (up to `opsCap − K2.balance`, at most 2 % of `ethIn`, so ≤ 0.4 ETH of a 20 ETH Sweep) to K2. Instant, as the spec says; the comment says otherwise.
- Impact: none; a reviewer relying on the comment would over-estimate the delay before a new keeper receives ETH.
- Suggested fix: change the comment to "set by an instant 2-of-3 (`setKeeper`)".

### F-5 `Signers` externals lack `nonReentrant` although §6 asks for it on every external state-changing function
- Severity: Info
- Location: `src/Signers.sol:58, 67, 74, 83` (and the Distributor/Converter governance setters that call into the base)
- Spec line: §6 "Threat: reentrancy / accounting. `nonReentrant` on all external state-changing functions"
- Transaction sequence: none reaches a re-entry: `setKeeper`, `proposeSignerRotation`, `executeSignerRotation`, `cancel` perform no external call (`ecrecover` is a builtin; no token, no ETH). A re-entrant path would require one, so no state can be observed mid-update.
- Impact: none. The literal spec sentence is not met; the threat it names is.
- Suggested fix: reword §6 to "on every external function that makes an external call", or add the modifier for uniformity (about 2.5k gas per governance call).

### F-6 The global nonce makes cold-signer ceremonies race the hourly `postRoot`
- Severity: Info
- Location: `src/Signers.sol:39, 128`; `src/NutzDistributor.sol:279`
- Spec line: §3.2 "one global nonce"; §5 hourly step 3
- Transaction sequence:
  1. Distributor nonce is 700. The cold signer (hardware wallet, §3.2) and the warm signer sign `RotateSigner(C, D, nonce=700)` over an afternoon.
  2. At :05 the keeper lands `postRoot(Epoch, e, …)` with nonce 700 (nonce → 701).
  3. `proposeSignerRotation(C, D, s1, s2)` reverts `NotSigner(<garbage>)` (the digest no longer matches; recovery yields an arbitrary address). The cold signer must sign again for 701 and land before the next hourly root.
- Impact: liveness only; no loss and no bypass (a nonce only moves with two valid signatures, so nobody can burn a nonce unilaterally; a `voidRoot` inside the Dispute window cannot be starved by the keeper alone). For a `voidRoot` the race is real if the keeper had several closed periods to post, because each later root also makes the bad one no longer the latest (§3.3).
- Suggested fix: keep one nonce; have the keeper (which submits the transactions anyway) sequence governance ahead of the next root in the same block or hold the root for one hour; put the rule in the Signer runbook.

## Notes without a finding
- The keeper key is signer 3 in `robinhood.json` (as §3.2 intends). Replacing a compromised keeper-signer needs four ceremonies: `setKeeper` on both contracts (instant) and `proposeSignerRotation` on both (48 h). During those 48 h the compromised key is still one signer, but 2-of-3 holds with the other two.
- Contract signers (EIP-1271) are not supported; all three keys must be EOAs, which matches the custody plan.
- `Cancel(bytes32 id, …)` shows the hardware-wallet signer an opaque hash; the runbook should give the id formula per action (typehash + args, no nonce).
- Domain names `"NutzDistributor"` and `"NutzConverter"`, version `"1"`, match §2.2/§3.2; `eip712Domain()` (EIP-5267) is available for tooling.
