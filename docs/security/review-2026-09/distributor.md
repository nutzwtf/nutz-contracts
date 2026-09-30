# Review: NutzDistributor

- Contract: `NutzDistributor` (`src/NutzDistributor.sol`, 595 lines), base `src/Signers.sol` (read as context only), interfaces `src/interfaces/INutzDistributor.sol`, `INutzDraw.sol`, `IKeeper.sol`.
- Commit tag: `review-2026-09-rc1` (74d724c). Spec v0.6.2 (working tree). Chain 4663, solc 0.8.37, EVM prague.
- Method: source + spec + ADR-0001..0004 + `script/config/robinhood.json`. No tests assumed.

## Checklist

| # | Item | Verdict |
|---|---|---|
| 1a | §6 bad root | OK. `postRoot` L272-299: ordered ids, `totals[i] <= funded[i] + carryIn[i]` per token, remainder to Carry; `_settle` L456-461 caps `claimed[i] <= totals[i]` per period, so an over-allocating tree stops at its totals. `voidRoot` L306-323 only latest, only before Final; Final and voidable are the same predicate (`isFinal`), so no claim can precede a void and `L.claimed`/`B.claimed` are never stale. Skipped ids are always `<= rootedThrough` after a void (`id-1`), so a skipped period's funding can never enter Carry twice and can never be rooted (ADR-0002 "one period, one tree" holds). |
| 1b | §6 keeper key / gas-fee abuse | OK. `pushClaims` L389-406: rate must be in the Signer range, fee `> 5%` of the entry's pushed USDG reverts; stocks are always paid in full to `account`. `gasPriceWei` is unbounded but the 5% cap is what §6 promises (see F-5). |
| 1c | §6 router/token behaviour | OK with F-2. `_payout`/`_tryTransfer` L469-488 isolate each of the five tokens: revert or `false` lands in `stuck`. Malformed return data is the one shape that still reverts the whole claim (F-2). |
| 1d | §6 issuer blocklist/pause, Distributor blocked | OK. Blocked/paused token → `stuck[account][t]`, others flow; `claimStuck` L433-439 is permissionless and keeps the record on failure. Funding path (`safeTransferFrom`) reverting while blocked is a Converter-side revert, as §6(c) intends (circuit breaker). |
| 1e | §6 Pons redirect / Pons operator | N/A (Converter). |
| 1f | §6 reentrancy / accounting | OK with F-1. All money-moving entry points are `nonReentrant`; checks-effects before every external call (`_settle` fully precedes `_payout`; `stuckOf` write after a *failed* call, which cannot re-enter successfully). Five governance setters lack the modifier (F-1); none makes an external call. `seedOf` is a `view` → STATICCALL. |
| 1g | §6 sybil | N/A (off-chain rule). |
| 1h | §6 no admin backdoors | OK. No owner, no proxy, no pause on claims, no token exit except leaf `account`, `claimStuck` to `account`, push fee to `msg.sender` (Keeper) and `pullAcorn` to `CONVERTER`. Note: 2-of-3 can halt *funding* via `setRateRange(min=huge)` (Converter reverts `UsdgBelowFloor`) and can delay a period's Drop indefinitely by post/void cycles; both are Signer liveness, not backdoors. |
| 2a | SOL-HMT-1 front-running | OK. `claim` is permissionless by design; tokens go only to the leaf's `account`. Residual: a stranger's `claim` makes the Keeper's 200-entry batch revert `AlreadyClaimed` (F-5). |
| 2b | SOL-HMT-2 msg.sender | OK by design (§3.3 "permissionless; tokens always go to account"). |
| 2c | SOL-HMT-3 zero hash / empty proof | OK. Empty proof ⇒ `root == leaf`; a double-keccak leaf is never `bytes32(0)`. `postRoot` accepts `root == 0` (an unclaimable root; F-6). A never-posted or voided ledger has `rootPostedAt == 0` ⇒ `NotFinal`. |
| 2d | SOL-HMT-4 same proof/leaf twice | OK. `B.claimed[id][account]` L451/455 per (kind, id, account); `claimMany`/`pushClaims` duplicates hit it too. |
| 2e | SOL-HMT-5 leaf includes claimant | OK. Leaf = `keccak256(bytes.concat(keccak256(abi.encode(id, account, amounts))))` L453, byte-identical to §3.3 / OZ StandardMerkleTree `["uint256","address","uint256[5]"]`. |
| 2f | SOL-Signature-1..5, ReplayAttack-1..2 | OK (base). Domain `EIP712("NutzDistributor","1")` binds chainId + verifyingContract; one global `nonce` inside every struct; OZ `ECDSA.recover` rejects high-s, bad v and address(0) by reverting; `a == b` ⇒ `SameSigner`; signers non-zero. Typed data L47-52 and `keccak256(abi.encode(totals))` L279 match EIP-712 fixed-array encoding. No deadline on signed structs: a collected-but-unsent pair stays valid until any other action consumes the nonce (Info, by design). |
| 2g | SOL-LL-4 precompile staticcall | N/A. No precompile calls in this contract. |
| 2h | SOL-McCc-1, 3, 12 | OK. No `block.number`; `block.timestamp` only for period ids, `CLAIM_DELAY`, timelock (see item 4). PUSH0 and MCOPY (cancun) are supported on ArbOS 61 (≥ ArbOS 30). |
| 2i | SOL-Defi-AS-12 | N/A. |
| 3 | Merkle domain separation | OK with note. Double hash ⇒ leaf preimage 32 bytes, node preimage 64 bytes: no node-as-leaf. `id` and `account` bound; `kind` is not in the leaf (F-4) but the proof is checked against the book selected by `kind`, and the id spaces never meet (epochs ≈ 497,000, draws ≈ 2,960; each book's other-kind ids are permanently `PeriodClosed` or `PeriodNotClosed`). |
| 4 | Arbitrum semantics | OK with note. `prevrandao`/`blockhash` unused; timestamps used only as monotone period counters, and every boundary rule (`< current`, `<= current`, `>= postedAt + 1800`) is self-consistent on the chain clock. A +1 h sequencer skew would compress the real-time Dispute window (F-8, trust assumption). |
| 5 | Stock Token pause/blocklist on every transfer path | OK. Outbound: `_tryTransfer` on all five in `claim`/`claimMany`/`pushClaims` (holder and Keeper fee); `claimStuck` and `pullAcorn` use `safeTransfer` and revert by design (record kept / pool untouched). Inbound: `safeTransferFrom` reverts the Converter's call, as §6(c) intends. |
| 6 | EIP-2537 G1ADD subgroup | N/A. |
| 7 | Constructor args vs spec (`robinhood.json`) | FINDING F-3 (excludedBase). Others match §3.1/3.3: rate range 1e9..1e10 raw USDG/ETH, `pushGasBase`/`PerLeaf` (fork-measurement TODO stated in the file), token addresses equal §2.1, `keeper == signers[2]` matches §5 step 3 / §3.2 custody (Keeper compromise = one of the two signatures, per design). Converter address is predicted by the script (not readable here). |
| 8 | Static-analysis items | N/A. All three are in `NutzConverter.sol` / `BLS2.sol`. |
| 9 | Anything else | F-4..F-9 (Info). |

Count: OK 17, N/A 7, findings on 3 rows (F-1, F-2, F-3).

## Findings

### F-1 Five governance entry points are not `nonReentrant`
- Severity: Low (deviation from spec, no loss).
- Location: `src/NutzDistributor.sol:423` (`setRateRange`), `:493` (`proposeDrawContract`), `:500` (`executeDrawContract`), `:508` (`proposeExclusion`), `:515` (`executeExclusion`); also inherited `setKeeper`, `proposeSignerRotation`, `executeSignerRotation`, `cancel` in `Signers.sol`.
- Spec line: §6 "Threat: reentrancy / accounting. `nonReentrant` on all external state-changing functions".
- Transaction sequence: (1) state: Root for Epoch E Final, Alice owed 100 USDG. (2) Alice calls `claim(Epoch, E, alice, [0,0,0,0,100e6], proof)`; inside `_payout` the USDG proxy's `transfer` (issuer-controlled code) calls back `setRateRange(1e9, 1e10, sig1, sig2)` with a valid, previously published signature pair; it executes (no guard, no external call) and consumes the nonce. (3) Alice's claim completes normally: 100 USDG paid, nothing lost, rate range unchanged in value. End state: correct; only the spec statement is false.
- Impact: none today (no external calls in these functions; all effects are signature- or timelock-gated). The statement in §6 is relied on as a marketing/verification claim.
- Suggested fix: add `nonReentrant` to the five Distributor functions (and the four in `Signers`), or reword §6 to "on every function that moves tokens".

### F-2 A malformed `transfer` return reverts the whole claim instead of recording `stuck`
- Severity: Low (deviation; frozen only while an issuer upgrade misbehaves, reversible by the issuer).
- Location: `src/NutzDistributor.sol:485-488` (`_tryTransfer`: `abi.decode(ret, (bool))`).
- Spec line: §2.5(a) "every stock transfer in claim/pushClaims is isolated"; §6 "transfer failures must never brick claims (`stuck` path)"; NatSpec L480-481 claims reverts, `false` and empty returns are "all handled".
- Transaction sequence: (1) state: Root for Epoch E Final; Bob owed `[1e18 SPY, 0, 0, 0, 100e6 USDG]`. (2) Robinhood upgrades SPY's implementation so `transfer` returns 1 byte (`0x01`) or a 32-byte word other than 0/1 (or `abi.encode(uint8)` truncated by a proxy). (3) Bob calls `claim(Epoch, E, bob, amounts, proof)`: `_settle` passes, `_payout` token 0: `ok == true`, `ret.length == 1` → `abi.decode` reverts → the entire transaction reverts, including the 100 USDG leg. (4) Same for `pushClaims`: every batch containing any SPY amount reverts. End state: 0 paid; all five tokens of every claimant with a non-zero SPY leaf are frozen until the issuer changes the token again; nothing is recorded in `stuck`.
- Impact: bounded and reversible by the issuer, but it is exactly the class §6 says must never brick claims, and the same upgrade power is what §2.5 designs for.
- Suggested fix: never `abi.decode`; treat success as `ok && (ret.length == 0 || (ret.length >= 32 && uint256(bytes32(ret)) == 1))`, reading only the first word; optionally cap return-data copied (assembly, `returndatasize()`).

### F-3 `excludedBase` in `robinhood.json` is `[0x…dEaD]` only; §3.5 requires six entries
- Severity: Low (config, acknowledged TODO in the file; becomes Medium if frozen as is).
- Location: `script/config/robinhood.json:3-5`; constructor `src/NutzDistributor.sol:186-191`.
- Spec line: §3.5 `EXCLUDED_BASE[] = [Pons locker, Pons buyback vault, Converter, Distributor, dead address]` plus "the v4 PoolManager, which is global, belongs in the base list"; §4.2 the Excluded set of an Epoch is built from `ExcludedAppended` logs only, and an append zeroes an address only from the Epoch it lands in.
- Transaction sequence: (1) deploy with the file as is; only `ExcludedAppended(0xdEaD)` is emitted. (2) NUTZ graduates; the v4 pool's NUTZ (say 30 % of supply) sits in `V4_POOL_MANAGER = 0x8366…`; `proposeExclusion(0x8366…)` is sent the same hour; `executeExclusion` is possible 48 h later, i.e. ≥ 49 Epochs. (3) Each of those Epochs is funded with, say, 1,000 USDG + stocks; the indexer, following §4.2, allocates 30 % ≈ 300 USDG per Epoch to `0x8366…`, and the Signers post the Root. (4) `0x8366…` can never call `claim`; ≥ 49 × 300 = 14,700 USDG (plus 30 % of the Stash) is committed in `totals`, unclaimable, and never returns to Carry (no reclaim path, §3.3 "never expire").
- Impact: bounded per Epoch by the cap, but repeated every Epoch until the append lands; permanent lock of the affected Allocations. Same shape for the Pons locker (post-graduation LP lock) if it holds NUTZ, and for the Converter in the hour after an owner `rescuePoolFees` (§2.4).
- Suggested fix: fill the list before the freeze with `V4_POOL_MANAGER`, the Pons locker and buyback vault; have the constructor itself push `address(this)` and `converter_` (both known at construction) so those two can never be forgotten; reject `address(0)` and duplicates in `excludedBase_`.

### F-4 `kind` is not bound into the leaf
- Severity: Info.
- Location: `src/NutzDistributor.sol:453`.
- Spec line: §3.3 leaf format (code matches the spec; this is a defense-in-depth note).
- Sequence: the same leaf `(id, account, amounts)` is only ever checked against `_book(kind).ledgers[id].root`; a Draw-book ledger with an Epoch-sized id (≈ 497,000) is `PeriodNotClosed` for ~9,500 years and an Epoch-book ledger with a Draw-sized id is `<= rootedThrough` since deploy. Not reachable.
- Suggested fix (optional, breaks fixture parity ADR-0001): encode `kind` into the leaf or use distinct id namespaces; otherwise leave and document the id-space argument.

### F-5 `pushClaims`: `gasPriceWei` unbounded; permissionless `claim` can revert a whole batch
- Severity: Info (both behaviours are what §3.3/§6 specify).
- Location: `src/NutzDistributor.sol:404-405`, `:399` (revert inside the loop).
- Sequence (a): a compromised Keeper passes `gasPriceWei` so that `fee == floor(sum[USDG] * 5 %)` for every entry; on 10,000 USDG pushed it keeps 500 USDG per batch, whatever the real gas (< $1). Bound is the 5 % of §6, so no deviation. Sequence (b): at `rootPostedAt + 30 min` a stranger sends `claim` for one wallet in the Keeper's next batch (~100k gas); the batch reverts `AlreadyClaimed` after settling up to 199 entries; the Keeper retries without it. Cost to the attacker: one transaction per hour; cost to the Keeper: one reverted batch per hour, paid from Ops.
- Suggested fix: (a) require `gasPriceWei <= tx.gasprice` (on Arbitrum `tx.gasprice` is the effective L2 price; L1 DA is charged in gas units, already in `PUSH_GAS_*`), which makes the fee track real cost instead of only the cap; (b) keep all-or-nothing (spec) but have the Keeper simulate immediately before sending; or skip `AlreadyClaimed` entries instead of reverting.

### F-6 Over-stated `totals` and `root == 0` are accepted and lock the surplus forever
- Severity: Info (this is the §6 "bad root" residual; bounded to one period).
- Location: `src/NutzDistributor.sol:290-297`.
- Sequence: Epoch E funded 1,000 USDG; Signers post `totals[USDG] = 1,000` but the tree's leaves sum to 900 (indexer bug or typo) and nobody voids within 30 min. 100 USDG is committed to E, never claimable, never returned to Carry. With `root = bytes32(0)` the whole 1,000 is locked the same way.
- Suggested fix: none on-chain without a reclaim path (which §6 forbids); make `nutz-verify` MATCH cover `totals == Σ leaves` and `root != 0`, and have the warm signer refuse otherwise.

### F-7 Skip loop gas grows linearly with the gap
- Severity: Info.
- Location: `src/NutzDistributor.sol:284-286`, `_skip` L325-339.
- Sequence: Keeper down 3 weeks (504 Epochs): 504 × 5 cold SLOADs ≈ 5.5 M gas in one `postRoot`; ~2,900 unfunded Epochs (4 months) approach a 32 M block. Recovery exists: post intermediate zero Roots (`root = 0`, `totals = 0`) for any id in `(rootedThrough, current)`, each a 2-of-3 ceremony.
- Suggested fix: none required; document the chunking procedure in the Signer runbook.

### F-8 Sequencer timestamp skew vs the 30-minute Dispute window
- Severity: Info (trust assumption on Robinhood's sequencer, which can already censor).
- Location: `src/NutzDistributor.sol:577-581`.
- Sequence: Root posted at chain time T; the sequencer's clock is allowed up to +1 h ahead of real time; if it advances 30 min in one block, the Root is Final in real seconds and `voidRoot` is impossible. A 24 h lag delays claims but never allows an early claim.
- Suggested fix: none on-chain (L1 block numbers are also sequencer-supplied); note it in the runbook.

### F-9 Config notes for the freeze
- Severity: Info.
- `keeper == signers[2]` (`robinhood.json:6,18`): per §5 step 3 and §3.2; a Keeper-key compromise yields one of the two Root signatures, and the warm signer's MATCH rule is the remaining control. `minUsdgPerEth = 1e9` (1,000 USDG/ETH) is also the Converter's on-chain floor for the ETH→USDG Leg (§2.2 step 4): at a 4,000 USDG/ETH market it tolerates a 75 % shortfall, so the "floor" under a compromised Keeper's `minOut` is weak; the Converter reviewer should weigh it. `pushGasBase`/`pushGasPerLeaf` are placeholders until the fork measurement (file comment). `excludedBase_` is not checked for `address(0)` or duplicates (harmless; the indexer de-duplicates).

## Notes on what was checked and found sound
- Carry algebra: `carry' = funded + carry − totals` (post) and `carry = carry' + totals − funded` (void) are exact because `notifyEpochFunding`/`notifyDrawFunding` reject `id <= rootedThrough` and no later Root can exist at void time; no underflow possible since `carry' + totals = funded + carry`.
- Void then re-fund then re-post of the same id is allowed and consistent (the verifier reads `funded` at post time; `RootPosted.carryIn` reproduces the cap).
- Acorn pool: `acornPoolUsdg` is funded by transfer in the same call, emptied only by `pullAcorn` under `NoDrawContract`/seed/once-per-draw/non-empty guards; `notifyDrawFunding` requires `drawConverted`. A week with zero pool cannot be rooted (`NotConverted`) and is Skipped by the next Root; Draw Carry waits, nothing is lost.
- Balance invariant: every `funded` and `acornUsdg` increment is matched by a `safeTransferFrom` in the same call; every outflow is a leaf amount, a `stuck` amount, a push fee bounded by settled USDG, or the Acorn pool.
- `claimStuck` zeroes before `safeTransfer` and reverts on failure, so the record survives.
- Timelock ids bind the argument (`draw`, `account`); TTL 7 days; re-checks at execute.
