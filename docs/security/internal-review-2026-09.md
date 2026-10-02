# Internal security review — September 2026

Status: two passes complete; the analyzer pass and the Medusa campaign on the fixed tree are recorded below.
Nothing here is an audit: the contracts have been reviewed by their author and by the agents below, and by
nobody else.

## Scope and commit

- Commits: first pass at tag `review-2026-09-rc1` = `74d724c`; the fixed tree, second pass and analyzer pass at
  tag `review-2026-09-final` = `c6d67cb` (local `main`, 2026-09-29). No `src/` change during a pass; the fixes
  sit between the two tags, one commit per finding.
- In scope: `src/NutzDistributor.sol`, `src/Signers.sol`, `src/NutzConverter.sol`, `src/NutzDraw.sol`, the
  vendored `src/vendor/bls/{BLS2,Precompiles}.sol`, the interfaces under `src/interfaces/`, and the deploy
  parameters in `script/config/robinhood.json` (constructor arguments against the spec only).
- Reference documents: `docs/spec/engineering-spec.md` (v0.6.2, working tree: the uncommitted edit touches only
  the §3.5/§4.2 exclusion prose), `CONTEXT.md`, `docs/adr/0001`–`0004`.
- Out of scope: the keeper, indexer, verifier and dashboard in `nutz-platform`; launch-day config values beyond
  the constructor-argument check; the External audit (post-launch).

## Method

One fresh-context reviewer per contract, in the order and with the emphasis the ticket sets (Distributor claim
path first), each given only the spec, `CONTEXT.md`, the ADRs, the source under review and its interfaces: no
tests, no build history, no earlier notes. Each worked the checklist below item by item and could only raise a
finding with a concrete transaction sequence with amounts. A finding rated Low or above then got a failing
Foundry test under `test/findings/` where the behaviour can be shown on the local EVM (five of eight), and a
second fresh agent with full repository access tried to refute every one of them. The four reports are kept
verbatim under `docs/security/review-2026-09/`.

Third voice: Trail of Bits' `spec-to-code-compliance` checker (`trailofbits/skills` at `82fe822`, 2026-09-28,
read before use; its Workflow fan-out was not run, its per-requirement checker agent was dispatched by hand on
18 requirements from spec §6/§7 and the ADRs). Its 18 analyses are under `docs/security/review-2026-09/compliance/`.
The ticket's other named skill, `audit-prep-assistant`, does not exist in that repository (the closest,
`audit-context-building`, builds a system model and was not needed: the spec is the model).

Checklist worked by every reviewer: spec §6 threats; Solodit SOL-HMT-1..5, SOL-Signature-1..5,
SOL-AM-ReplayAttack-1..2, SOL-LL-4, SOL-McCc-1/3/12, SOL-Defi-AS-12; Merkle leaf domain separation; Arbitrum
semantics (`block.number`, timestamp skew, `prevrandao`); Stock Token pause/blocklist on every transfer path;
EIP-2537 G1ADD without subgroup check; constructor arguments vs the spec; the Slither/Aderyn items carried into
the review (unchecked return `NutzConverter.sol:692`, uninitialised local `BLS2.sol:370`, shadowing
`NutzConverter.sol:68,69,78`).

## Tools and versions

forge 1.8.3 (solc 0.8.37, evm prague); Slither 0.11.6; Aderyn 0.6.8; Semgrep 1.178.0 with the Decurity rules
pinned in `scripts/semgrep.sh`; Medusa 1.5.1; `trailofbits/skills` 82fe822. Evidence already in the tree before
this pass, at the same commit: 100 % branch coverage on non-vendor `src/` (CI gate); the mutation run
(`docs/security/mutation-2026-09.md`); the symbolic suites (`test/symbolic/`); the Medusa campaign notes in
`docs/setup/tools.md`; the BLS vector suites (`test/unit/Bls*.t.sol`).

## Checklist results

| Item | Distributor | Signers | Converter | Draw + BLS |
|---|---|---|---|---|
| §6 bad root | OK | — | — | — |
| §6 keeper key compromise | OK (5 % push-fee cap, Signer-set rate range) | OK | F06 (launch floor), F07 (Acorn path) | F08 |
| §6 router / token behaviour | F01 | — | OK | — |
| §6 issuer pause / blocklist | OK (`stuck` path) | — | Info: the funding hop is not isolated (the breaker is the spec's answer) | — |
| §6 Pons recipient / operator | — | — | OK (no transfer path exists) | — |
| §6 reentrancy / accounting | F03 (wording) | F03 | OK (`unlockCallback`, `receive` considered) | — |
| §6 no admin backdoors | OK | OK | OK | OK |
| SOL-HMT-1..5 (Merkle) | OK | — | — | — |
| SOL-Signature / replay | OK | OK (within, across contracts, across chains; malleability; address(0); same signer) | OK | — |
| SOL-LL-4 precompile returns | — | — | — | Info: success flag checked on all five calls, `returndatasize` never; fixed-size outputs |
| SOL-McCc-1/3/12 | OK | OK | OK | OK |
| SOL-Defi-AS-12 (callback caller) | — | — | OK | — |
| Merkle domain separation | OK (`kind` not in the leaf: Info, id spaces never meet) | — | — | — |
| Arbitrum semantics | OK (Info: +1 h skew vs the 30-min window) | OK | OK | Info: 10-min lead on the sequencer clock |
| Stock Token transfer paths | OK | — | OK (legs isolated; funding hop not, see above) | — |
| EIP-2537 G1ADD subgroup | — | — | — | OK: ADD only ever sees map-to-curve outputs; the signature goes straight to the pairing |
| `robinhood.json` vs spec | F02 (`excludedBase`) | OK (`keeper == signers[2]` per §3.2) | F06 (`minUsdgPerEth`) | — |
| Static-analysis items | — | Converter 68/69/78: struct-member false positive | 692: deliberate (settle's return adds no check) | 370: false positive (zero-initialised memory) |

Spec-compliance checker: R01–R11, R13–R17 `implemented` (high confidence); R12 `partial` (the reentrancy
*property* holds on every path, the "`nonReentrant` on all external state-changing functions" wording does
not: F03); R18 `partial` (claims and swap legs isolated, the funding hop to the Distributor not: the Info above).
Doc drift the checker recorded: a Draw Root with no Draw contract reverts `NotConverted`, not `NoDrawContract`
as §6/§10 say (the check order at `NutzDistributor.sol:275-276`).

## Findings

Severity: High (funds lost or frozen), Medium (bounded loss, or a §7 invariant broken without loss), Low
(deviation from spec without loss), Info (a note). Disposition is Eduar's, one issue per finding under the
security-review tickets (`F01-…` to `F08-…`, `Status: needs-triage`).

| Id | Reviewer | After refutation | Contract | Title | Evidence |
|---|---|---|---|---|---|
| F08 | Medium | **Medium, confirmed** | Draw | The Keeper can re-roll the Seed: a re-request is accepted after the committed round is public; 144 quiet samples a day, nothing in the watcher list or `nutz-verify` sees it | `test/findings/F08_KeeperRerollsTheSeed.t.sol` |
| F02 | Low (Medium if launched as is) | **Low, confirmed** | Distributor / deploy script | `excludedBase` in the deploy config is `[dEaD]`; the entry with weight is the v4 PoolManager (already in the config file, not in the list); fix in `Deploy.s.sol`, which predicts the addresses anyway | `test/findings/F02_ExcludedBaseConfig.t.sol` |
| F05 | Low | **Low, confirmed** (ADR / Keeper policy) | Converter | One wei of NUTZ plus the ADR-0003 empty NUTZ Route reverts every Sweep; a well-formed placeholder Route recovers it, and §5 pages on the first missed hour | `test/findings/F05_DustNutzStallsTheSweep.t.sol` |
| F01 | Low | Info | Distributor | A malformed `transfer` return reverts the claim instead of landing in `stuck`: an ABI-nonconforming token, not an issuer control; a clean revert, nothing lost | `test/findings/F01_TryTransferMalformedReturn.t.sol` |
| F03 | Low | Info (documentation drift) | Distributor, Signers, Converter | Governance entry points carry no `nonReentrant`; none makes an external call, so the guard would be dead code; reword §6 | static |
| F04 | Low | Info | Signers | An expired timelock proposal keeps its slot until `cancel`; `cancel` accepts an expired id, the 48 h is not paid twice, the spec is silent on re-proposal | `test/findings/F04_ExpiredProposalBlocksReproposal.t.sol` |
| F06 | Low | Info (launch-config recommendation) | Converter / config | The launch floor of 1,000 USDG/ETH bounds a compromised Keeper at ~40 % of value; the spec states no number and says "per call"; a runbook choice between liveness and loss | sequence in `review-2026-09/converter.md` F-1 |
| F07 | Low | Info (spec wording) | Converter / spec | `convertAcorn` runs the stock Legs on a quarter of the weekly pool; §2.2 already defines it that way, §2.3's "one perStock ≈ 15 % of one Sweep" is Sweep-scoped | sequence in `review-2026-09/converter.md` F-2 |

The refuters' arguments are in each issue file. Disposition (Eduar, 2026-09-29) and the fixing commit:

| Id | Disposition | Where | Commit |
|---|---|---|---|
| F08 | accepted | `NutzDraw.requestDraw` refuses a re-request once the committed round is due (`RoundDue`); both Draw invariant handlers model it; spec §3.4 drops "a round that can never be fulfilled" | `4be0d7d` |
| F02 | accepted | `Deploy.deploy` appends the predicted Distributor, the predicted Converter and the v4 PoolManager to the config's list, asserts both predictions, refuses a zero or duplicate entry; spec §3.5/§10 list who supplies which entry | `0ba1b81`, `29da940` |
| F05 | accepted as Keeper policy | ADR-0003 and spec §5: the Keeper always sends a well-formed NUTZ Route once NUTZ is bound; a Venue that cannot fill it is skipped; regression test pins both shapes | `cfff540` |
| F06 | accepted as config + runbook | `minUsdgPerEth` 1,000 → 2,000 USDG/ETH (~80 % of spot on the day); §6 and the Signer runbook line on keeping it there with `setRateRange` | `8bda7f5` |
| F03 | wontfix (code); spec reworded | §6: `nonReentrant` on every function that makes an external call | `8bda7f5` |
| F07 | wontfix (code); spec reworded | §2.3 and §6 state the Acorn conversion's exposure as it is | `8bda7f5` |
| F01 | wontfix | an ABI-nonconforming token is not an issuer control; a clean revert, nothing lost | — |
| F04 | wontfix | one instant `cancel` ceremony, no extra delay, no funds | — |
| F09 (second pass) | accepted | the deploy script's `run()` deploys the launch pair only; `runDraw(distributor)` is the Draw's own stage, run once gate item 10 is green; `deploy()` keeps both for the tests; §10 step 2 names the two commands | `f1136df` |

Each accepted finding's failing test became the regression test in the matching unit file; the two wontfix
tests were dropped and stay readable at `5f54648`.

## Second pass

One fresh-context reviewer per changed file, same inputs plus the diff since `review-2026-09-rc1`
(`docs/security/review-2026-09/pass2-draw.md`, `pass2-deploy.md`). Verdict on the F08 fix: correct, no bug
introduced (the boundary is exact and complementary to `fulfill`, a never-requested draw is handled, round
monotonicity survives re-requests, old requests stay fulfillable, a retired beacon leaves the pool untouched).
Verdict on F02/F06: correct as implemented. Nothing rated Medium or above, so the loop closes here. Taken from
the pass: two script hardenings (both predictions asserted; a zero or duplicate config entry refused) and two
doc nits (ADR-0004's re-commit sentence; "Skipped" vs "passed over" for a week never fulfilled), in `29da940`.
One new Low, pre-existing and not in the patch: **F09**, the deploy script created the Draw in the launch
transaction while the scope rule stages it separately (no funds touched: the Draw is unwired until
`executeDrawContract`); accepted and fixed in the script (see the findings table). Three Infos recorded in the Draw report (ADR wording, the 10-minute lead on the
sequencer clock, no in-contract remedy for a wrong list once locked: the week is passed over).

Info-level notes, no issue opened (the reports have the detail): Distributor — `kind` not bound into the leaf;
`gasPriceWei` unbounded beyond the 5 % cap and a stranger's `claim` reverting a Keeper batch; over-stated
`totals` or `root == 0` accepted (the bad-root residual); skip-loop gas over long gaps; sequencer skew vs the
Dispute window; config placeholders. Signers — no signature deadline; a rotation does not cancel pending
proposals; the `NutzConverter.sol:427` comment says the keeper is timelocked (it is instant, as §3.2 says);
the global nonce races the hourly `postRoot`. Converter — the Pons views run outside try/catch; a blocked
Distributor reverts the funding hop until `disableLeg`. Draw — the 10-minute lead is on the sequencer clock;
`returndatasize` unchecked on the precompile calls. Verified sound by the Draw reviewer: quicknet
`GENESIS`/`PERIOD`, the DST, the public-key limbs against the compressed key, the negated G2 generator, the
sqrt exponent (misnamed "(p+1)/2", it is (p+1)/4), RFC 9380 byte-for-byte, the pairing input layout, and the
uniqueness of the Seed (no second encoding verifies).

## Analyzer pass on the fixed tree

At `29da940` (the second pass's last commit), on the 8-core machine, turbo off:

| Check | Result |
|---|---|
| `forge test --no-match-path 'test/fork/**'` | 383 tests, 0 failed (unit, fuzz, invariant, Medusa-under-forge) |
| `forge test --brutalize --no-match-path 'test/fork/**'` | 383 tests, 0 failed |
| Slither 0.11.6 | 0 High, 0 Medium, 18 Low, 12 Informational: unchanged from the pre-review baseline, all triaged in `slither.config.json` or documented |
| Aderyn 0.6.8 | 0 High, 13 Low types: unchanged (PUSH0 false positive on Prague, the rest documented) |
| Semgrep 1.178.0, Decurity rules | 42 rules on 15 files, 0 findings |
| `forge test --symbolic --match-path 'test/symbolic/**'` | 15 checks, 0 failed, 76 s (the filter matters: unfiltered, forge also runs the deploy script's `check*` helpers, which stall on a symbolic call target) |
| Branch coverage gate (`scripts/coverage-gate.sh`, `--no-dynamic-test-linking`) | 100 % on every non-vendor file: Converter 66/66, Distributor 48/48, Draw 12/12, Signers 15/15 |
| Mutation on the changed file (`src/NutzDraw.sol`), ticket 07's method | 186 mutants, 12 invalid, 162 killed in the unit pass (10 min); 12 survivors: the 10 Draw equivalents already recorded in `mutation-2026-09.md`, one new trivial equivalent on the fix line (`d.round != 0` → `> 0`, `uint64`), and one real one, `currentRound() >= d.round` → `==`, which the regression test now kills (it locks an hour after the round as well as at it): 93.1 % → 93.7 % |
| Medusa 1.5.1, gate duration (spec §6 item 5: 8 h per target, one at a time, 2 workers, turbo off, corpus from the ticket-06 campaign reused) | 2026-09-29 14:58 → 2026-09-30 15:01, every target 8 h 00: Draw 69.1 M calls (2,400/s), 679 branches, 13/13 properties passed, 0 failures in 691,465 checks; Distributor 22.3 M calls (707/s), 2,814 branches, 24/24 passed, 0/222,628; Converter 25.0 M calls (884/s), 3,516 branches, 28/28 passed, 0/249,845. No saved failure under `corpus/medusa/*/test_results`, zero reverts on every target function in the revert reports (8, 17 and 18 functions). The branch counts are reached within seconds because the corpus replays, and stay flat for the eight hours; package temperature 55–66 °C throughout |
| Fork suite (`test/fork/**`, Chainstack archive RPC) | 9 tests, 0 failed at the pinned block 62,393,542 and again at block 75,954,295 (2026-09-29, `FORK_BLOCK_4663=75954295`) |

## Not reviewed, and the standing risks

Not reviewed: anything in `nutz-platform` (the keeper, the indexer, `nutz-verify`, the dashboard, the watcher);
the launch-day values in `script/config/robinhood.json` beyond the constructor-argument check (the Pons locker
and buyback vault addresses, the Signer and Keeper keys, the gas constants are still TODO there); the vendored
BLS verifier beyond its vector suites (`src/vendor/bls/` was read by the Draw reviewer for the precompile
handling and the encoding, not audited as a library).

Standing risks the reader should carry: the contracts are not externally audited (the External audit is
post-launch, whitepaper decision #9); the Draw is deployed after launch through the 48-hour timelock once its
own gate items are green (spec §6 item 10), and until then the Acorn pool accumulates in the Distributor; the
Keeper remains a trusted-for-liveness role whose compromise is bounded by the push-fee cap, the Signer-set
rate floor (as tight as the Signers keep it, F06) and the 2-of-3 on every Root; the sequencer's clock is the
contracts' clock (the 30-minute Dispute window and the Draw's 10-minute lead are measured on it); and a Stock
Token issuer's pause or blocklist stops the funding hop until the Signers flip the circuit breaker, by design.

For an External auditor: start from this document, the four first-pass reports and the compliance analyses
under `docs/security/review-2026-09/`, the mutation record (`docs/security/mutation-2026-09.md`), and the
issue-by-issue refutations summarised in the findings table above.
