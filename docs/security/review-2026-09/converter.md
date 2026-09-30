# Review: NutzConverter

- Contract: `src/NutzConverter.sol` (inherits `src/Signers.sol`, read only as the base it depends on)
- Interfaces: `src/interfaces/{ISwapRouter02,IWETH9,INutzDistributor,IKeeper}.sol`, `src/interfaces/pons/*.sol`; v4 semantics from `lib/v4-core/src/{PoolManager.sol, libraries/Hooks.sol, libraries/Pool.sol, libraries/TickMath.sol, types/BalanceDelta.sol, types/Currency.sol}`
- Spec: `docs/spec/engineering-spec.md` v0.6.2 (working tree), `CONTEXT.md`, ADR-0003; config `script/config/robinhood.json`
- Commit tag: `review-2026-09-rc1` = 74d724c

## Checklist

| # | Item | Verdict |
|---|---|---|
| 1a | §6 bad root | N/A: the Converter posts nothing; it only funds. |
| 1b | §6 keeper key compromise | FINDING F-1, F-2. Mechanism as specified (floor on Leg 2, `minOut` elsewhere, `MAX_SWEEP_ETH` per call), but the bound at the launch config is ~84% of every Sweep, repeatable per call, and the whole Acorn pool once a week. |
| 1c | §6 router/token behavior | OK: every Leg but ETH→USDG is in try/catch (`_runV3` L613, `_runV4` L644); approvals exact and zeroed on both outcomes (L612/619, `_approveFunding`); Leg 2 re-raises the Venue's data (`_runLegStrict`). |
| 1d | §6 issuer blocklist / pause | OK for the swap Legs (a paused token fails the Venue transfer, caught, share to Cash). Note F-5 (Info): a block on the *Distributor* fails in the un-isolated `notifyEpochFunding` and reverts every Sweep until `disableLeg`; USDG has no breaker. |
| 1e | §6 Pons redirects recipient | OK: no function reaches `transferCreatorFeeRecipient` or `setBuybackEnabled`; `bindNutz` only reads the factory. |
| 1f | §6 Pons operator stalls | OK: `_sweepHook` is gated on `_hookHasOnlyEthPending` and try/catch; `_claimEscrow` never depends on it. |
| 1g | §6 reentrancy / accounting | OK: `sweep`, `convertAcorn` `nonReentrant`; `receive` empty; `unlockCallback` gated on `msg.sender == V4_POOL_MANAGER` and only reachable inside the Converter's own `unlock`; a hook cannot re-enter `unlock` (`AlreadyUnlocked`) nor the Keeper-only entry points. SafeERC20 throughout. |
| 1h | §6 sybil | N/A. |
| 1i | §6 no admin backdoors | OK: no owner, withdraw, pause, upgrade; the only setters are 2-of-3 (`setOpsCap`, `disableLeg`, `proposeLegEnable`, `setKeeper`, rotation), matching §2.2. |
| 2a | SOL-HMT-1..5 | N/A: no Merkle logic. |
| 2b | SOL-Signature-1..5, ReplayAttack-1..2 | OK: OZ `EIP712` domain binds `chainId` + `verifyingContract`, name `"NutzConverter"` differs from the Distributor's; every struct carries the global `nonce`; `SameSigner` rejects a duplicate; OZ `ECDSA.recover` reverts on malleable `s`, bad `v` and `address(0)`. Info: signatures carry no deadline; only a nonce move invalidates a signed-but-unsent action. |
| 2c | SOL-LL-4 | N/A: no precompile staticcalls. |
| 2d | SOL-McCc-1,3,12 | OK: `block.timestamp` only in `deadline` (Keeper's, minutes) and the 48h/7d timelock; no `block.number`/`prevrandao`; PUSH0 is live on ArbOS ≥ 11. |
| 2e | SOL-Defi-AS-12 | OK: `unlockCallback` L657 checks the caller; the data it decodes is what `_runV4` L644 encoded, passed through the manager unchanged. |
| 3 | Merkle leaf domain separation | N/A. |
| 4 | Arbitrum semantics | OK: a +1h sequencer clock makes a timelocked enable executable ≤ 1h early and can make a wall-clock `deadline` read as passed (Keeper should derive `deadline` from the latest block timestamp); no funds effect. |
| 5 | Stock Token pause/blocklist on every path | OK with F-5 note: Venue→Converter transfer (isolated), `forceApprove` and Distributor pull (same tx as a successful swap, so not pausable in between; a blocked *Distributor* reverts the Sweep until `disableLeg`). |
| 6 | EIP-2537 G1ADD | N/A. |
| 7 | Constructor args in `robinhood.json` | OK for the Converter's arguments: five tokens, WETH, `v3Router`, `v4PoolManager`, the three Pons addresses and `opsCapWei = 0.5 ether` equal §2.1; `WETH == router.WETH9()` is asserted on deploy. Notes: `keeper == signers[2]` (spec §3.2 design, the KMS key is also a Signer); tokens are keyed by name so the script's mapping to `tokens(0..4)` cannot be checked from the JSON alone; `minUsdgPerEth = 1e9` (1,000 USDG/ETH) is the value behind F-1; `excludedBase` is the Distributor's and still a TODO. |
| 8 | Static-analysis items | L692 `settle()` return unused: OK, the manager reverts `CurrencyNotSettled` at the end of `unlock` if the credited amount is short, and the Converter transferred exactly `amountIn` one call earlier. `BLS2.sol:370`: N/A. Shadowing L68/69/78: OK, `Params` struct members named like `signers`, `keeper`, `opsCap`; always accessed as `p.x`. |
| 9 | Anything else | F-3 (dust-NUTZ Sweep DoS), F-4 (Fee-pull views outside try/catch, permanent contract), F-6 (expired enable proposal). `SPLIT_ACORN_BPS` is declared but unused (`_slice` takes Acorn as the remainder, per §2.2 step 5). |

Verified in detail, no finding: `_slice`/`_quarter` reproduce §2.2 step 5 exactly (stash and cash over 9800, acorn the remainder, `perStock = stash×2500/10000`, dust to Cash; `stash + cash ≤ usdgOut` so no underflow); `_fundOps` reproduces step 3; the floor `ethIn × minUsdgPerEth / 1e18` uses the post-Ops amount (step 4); `MAX_SWEEP_ETH` is applied after the NUTZ sale so v4 native output counts (step 3); USDG conservation holds in both paths (`usdgOut = Σ bought perStock + cash' + acorn`, `usdgIn = Σ bought perStock + usdgLeft`); `V4_PRICE_LIMIT_*` equal `TickMath.MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE − 1`, and `Pool.swap` accepts exactly those bounds; v3 path check binds first/last token with WETH standing for ETH and rejects malformed lengths; `zeroForOne = tokenIn < tokenOut` matches v4's address ordering on any chain.

v4 hostile-hook analysis: with `beforeSwapReturnDelta` the caller's specified delta is `−(amountIn − h) − h = −amountIn` whatever the hook takes (Hooks.sol L269-277, L311), so `filled != amountIn` fires only on liquidity exhaustion; a hook charging more than the output on the unspecified side makes `outDelta` negative and `SafeCast.toUint256` reverts; a hook that `settleFor`s the Converter in any currency leaves a non-zero delta and `unlock` reverts `CurrencyNotSettled`; a hook that `take`s is charged to its own address. `sync(cin)` after the swap clears any currency a hook left synced, so a native `settle` cannot hit `NonzeroNativeValue`. Every one of these ends in a caught revert and a skipped Leg; nothing leaves the Converter.

## Findings

### F-1 The compromised-Keeper bound is ~84% of every Sweep at the launch config, and per call, not per hour
- Severity: Low (no code defect; configuration and spec wording. Loss requires the Keeper key.)
- Location: `src/NutzConverter.sol` L327-333 (`ethIn` cap, `_ethToUsdg`), L448-452 (floor), L481-490 (stock Legs); `script/config/robinhood.json` `minUsdgPerEth = "1000000000"`.
- Spec line: §6 "the ETH→USDG Leg (98% of every Sweep) floored on-chain by the Distributor's Signer-set `minUsdgPerEth`"; §2.3 "`MAX_SWEEP_ETH` … is the blast-radius cap"; §2.2 step 3 "Anything above waits for the next Sweep".
- Transaction sequence (ETH at 2,476 USDG, the spec's §9 Q8 rate; Keeper wallet at `opsCap` so Ops = 0; Converter holds 60 ETH after a Keeper outage):
  1. Attacker (Keeper key) deploys a v3 pool WETH/USDG and a v3 pool FAKE/SPY etc. it fully owns, or simply uses `minOut = 0` on the real pools and sandwiches itself (no public mempool on 4663, but the sequencer sees the Keeper's own bundle; the owned-pool path needs no MEV).
  2. `sweep(e, routes, deadline)` with `routes[1] = {V3_ROUTER, minOut: 0, path: WETH‖fee‖USDG}` naming its own pool. `_ethToUsdg` swaps 20 ETH; the pool returns exactly 20,000 USDG (floor = 20e18 × 1e9 / 1e18 = 20,000; `usdgOut < floor` would revert). Attacker keeps 20 ETH worth 49,520 USDG: +29,520.
  3. `_slice(20,000)`: stash 12,244.89, cash 5,714.28, acorn 2,040.83; `perStock` 3,061.22 ×4. `routes[2..5]` with `minOut = 0` through owned pools: attacker takes 12,244.88 USDG and delivers dust stock. Distributor receives dust stock + 7,755.11 USDG.
  4. Repeat steps 2-3 twice more in the same minute: `MAX_SWEEP_ETH` is per call and `notifyEpochFunding` accepts several fundings of one Epoch (§3.3). 60 ETH → attacker ≈ 125,300 USDG of 148,560 (84%).
- Impact: bounded loss of ≈ 84% of whatever ETH has accrued when the key is compromised, until the Signers `setKeeper`. §6's "floored on-chain" mitigates 16% at the configured range. `MAX_SWEEP_ETH` bounds nothing over time.
- Suggested fix: configure `minUsdgPerEth` near spot (e.g. 0.9 × spot, with a Signer runbook step to move it on ETH moves; `setRateRange` is instant 2-of-3), state the resulting bound in §6, and make §2.3/§6 say "per call". Optional contract change: none required.

### F-2 `convertAcorn` exposes the whole Acorn pool to zero-`minOut` Routes; §2.3's "one perStock ≈ 15% of one Sweep" does not hold there
- Severity: Low (bounded to the weekly pool; Keeper key required).
- Location: `src/NutzConverter.sol` L522-544, `_buyStock` L481.
- Spec line: §2.3 "A stock Leg has no on-chain floor beyond its `minOut`; its exposure is one `perStock` (≈ 15% of one Sweep)"; §6 "the stock Legs are bounded by one `perStock` each".
- Transaction sequence: Acorn pool = 20,000 USDG after a week; the Draw seed is reported. Keeper key calls `convertAcorn(d, routes, deadline)` with four Routes `{V3_ROUTER, minOut: 0, USDG‖fee‖<stock>}` through pools the attacker owns. `pullAcorn` moves 20,000 USDG to the Converter; `_quarter` gives 5,000 per Leg; each Leg sends 5,000 USDG to the attacker's pool for dust stock. `notifyDrawFunding(d, [dust×4, 0])`. Loss: 20,000 USDG, once per Draw (the Distributor enforces once and a seed).
- Impact: the stock Legs' exposure is 100% of the Acorn pool, not 15% of a Sweep.
- Suggested fix: correct §2.3/§6; if a bound is wanted, a Signer-set floor per stock (raw USDG per stock unit, like `minUsdgPerEth`) checked in `_buyStock`, or accept and document.

### F-3 Anyone can stall the hourly Sweep with 1 wei of NUTZ if the Keeper follows ADR-0003 and passes an empty NUTZ Route
- Severity: Low (no loss; Sweeps revert until the Keeper changes its Route policy).
- Location: `src/NutzConverter.sol` L322-325, L415-423 (`_sellNutz`), L564-572 (`_runLeg` → `BadVenue`).
- Spec line: §2.1 "A bad Route reverts the whole call (a Keeper bug, not a market condition)"; ADR-0003 "The Keeper passes an empty Route for the NUTZ Leg except in the rare hour after a Pons rescue".
- Transaction sequence: NUTZ is bound. Stranger calls `NUTZ.transfer(converter, 1)`. Keeper calls `sweep(e, routes, dl)` with `routes[0] = {venue: 0, minOut: 0, data: ""}` (ADR policy). `_sellNutz` reads `nutzIn = 1`, `_runLeg` reverts `BadVenue(0)`; the whole Sweep reverts. Every hourly Sweep reverts the same way (the 1 wei stays) until the Keeper supplies a valid NUTZ Route, after which the Leg sells 1 wei (v3: output 0, `minOut` 0 → `NutzSold(1, 0)`; or a caught revert → `LegSkipped`). Cost to the stranger: one transfer.
- Impact: Sweeps delayed; ETH waits in the escrow/Converter. With the Converter permanent, this foot-gun exists for the token's life.
- Suggested fix: in `_sellNutz`, treat `route.venue == address(0)` as "no Route": `emit LegSkipped(0, "no route"); return;` (keep `BadVenue` for a non-zero, unknown venue). Alternatively the Keeper always sends a valid NUTZ Route; then ADR-0003's consequence should say so.

### F-4 The Fee pull's Pons views run outside try/catch; a reverting escrow `balanceOf` freezes the permanent Converter's ETH
- Severity: Info (conditional on a change in a third-party contract; no evidence the escrow is upgradeable).
- Location: `src/NutzConverter.sol` L354 (`getLaunchedToken`), L365 (curve views), L397-399 (hook views), L404 (`PONS_ESCROW.balanceOf`).
- Spec line: §2.2 step 2 gates each Pons call on the views; §2 "It cannot be replaced".
- Transaction sequence: NUTZ bound; Converter holds 5 ETH. `PONS_ESCROW.balanceOf` starts reverting (implementation change or self-destruct). Every `sweep` reverts inside `_claimEscrow` before `ethIn` is read; `bindNutz` cannot unbind (`nutz` can never return to zero) and the escrow address is immutable, so 5 ETH plus all future rescue-path ETH is frozen. A reverting factory, curve or hook view is recoverable by binding another ETH-quoted launch the Keeper creates for 0.0005 ETH; the escrow view is not.
- Impact: none today; a permanent-liveness dependency on four external views.
- Suggested fix: wrap the four view reads in `try`/`catch` (treat a failed read as "nothing pending"), so a broken Pons view degrades to "no Fee pull" instead of "no Sweep".

### F-5 A blocklisted Distributor (or paused USDG) reverts every Sweep, not just one Leg
- Severity: Info (no loss; §6 names the case and the breaker).
- Location: `src/NutzConverter.sol` L493-498 (`_fundEpoch`, not isolated), L448 (Leg 2 strict).
- Spec line: §6 "incl. the Distributor address being blocked"; §2.5 "USDG … treat it with the same isolation as the stocks".
- Transaction sequence: issuer blocklists the Distributor for SPY. `sweep`: SPY Leg succeeds (Converter receives 3,061 SPY-units), `notifyEpochFunding` → `transferFrom(converter, distributor)` reverts → whole Sweep reverts; repeats hourly until 2-of-3 `disableLeg(0)` (instant). For USDG there is no breaker: a USDG pause halts Sweeps until lifted; ETH accumulates, nothing is lost.
- Suggested fix: none required; put "Sweep reverting on the Distributor pull → `disableLeg`" in the Signer runbook.

### F-6 An expired `EnableLeg(stock)` proposal blocks a new one until `cancel`
- Severity: Info (`Signers.sol`, outside the assignment; affects the breaker's re-enable path).
- Location: `src/Signers.sol` L98-117 (`_schedule` rejects `readyAt != 0`; `_consume` reverts `Expired` without deleting); `src/NutzConverter.sol` L285.
- Transaction sequence: `proposeLegEnable(0)` at T; nobody executes by T + 48h + 7d. `proposeLegEnable(0)` again → `AlreadyScheduled`; `executeLegEnable(0)` → `Expired`. Signers must `cancel(id)` (2-of-3, one more nonce) first.
- Suggested fix: `_schedule` may overwrite an expired entry, or document the `cancel` step.

## Counts
Checklist: 20 OK, 8 N/A, 2 FINDING rows (1b, 9). Findings: F-1 Low, F-2 Low, F-3 Low, F-4 Info, F-5 Info, F-6 Info. No High or Medium.
