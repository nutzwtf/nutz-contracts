# Mutation testing — September 2026

Run on 2026-09-28/29 against the `src/` of commit `0003f04` with `forge 1.8.3` (`forge test --mutate`, the MVP shipped in Foundry 1.8) against the
non-vendor `src/` contracts: `Signers`, `NutzDraw`, `NutzDistributor`, `NutzConverter`. `src/vendor/bls/` is not
mutated: ticket 03's vector suites (`test/unit/Bls*.t.sol`, RFC 9380, EIP-2537, 500+ quicknet rounds and the
noble-built negatives) are its evidence, and a mutation score over a vendored library would not change what is
done about it. Launch gate item 4 of the security review: every survivor is either killed by a test named below
or recorded here as equivalent with the reason. There is no third category.

## Method

forge generates every mutant of one file (operator swaps, boundary shifts, dropped statements, zeroed
constants), copies the project into a temporary workspace per mutant, compiles it and runs the selected tests;
a mutant that fails at least one test is killed. Survivors do not fail the command, so the JSON report
(`--json`, last line) is what gets read.

The test set is the unit + invariant suites (`test/unit/`, `test/invariant/`, `test/medusa/` under forge's
runner; `test/fork/` excluded, `test/symbolic/` has no `test_` functions). They are run as **two passes per
contract**, not one:

```
FOUNDRY_FUZZ_RUNS=256      forge test --mutate src/<C>.sol --match-path 'test/unit/**'              --mutation-jobs 16 --json
FOUNDRY_INVARIANT_RUNS=32  forge test --mutate src/<C>.sol --no-match-path 'test/{fork,unit}/**'    --mutation-jobs 16 --json
```

A mutant is killed if either pass kills it; the survivors are the intersection of the two survivor lists
(`scripts/mutation-survivors.py`, keyed on line, column, original and mutant text). The split is a workaround:
with both suites in one `--mutate` invocation, forge 1.8.3 ran every mutant for over ten minutes on this
machine (16 workers each executing the invariant campaigns far past the configured run count) where the same
mutant's suite takes 10 s by hand; each pass alone behaves. The reduced run counts (1,000 → 256 fuzz, 256 → 32
invariant) are what make the passes take minutes instead of hours; a kill under fewer runs is a kill under
more. `--mutation-timeout` is not passed: it turns on "adaptive skipping" (mutants left untested once a
neighbour on the same span survives); the runner still skips a few without it (12 of the Distributor's
775 in the unit pass), and the report does not name them, so the close-out below covers them.

For `Signers` and `NutzDraw` both passes ran as written. For `NutzDistributor` the invariant pass was stopped
after 2 h 30 with 140 of 775 mutants left: the tail is the mutants that turn a bounded loop into an endless
one, and every invariant call then burns the whole gas limit. Those are killed by the unit pass anyway, and
a mutant the unit pass killed needs no second verdict, so the invariant suites were run instead on the unit
pass's survivors only, one mutant at a time with `scripts/mutation-rerun.py` (same suites, same 32 runs,
`--fail-fast`), which is the same intersection at a fraction of the cost. The Converter's invariant pass was
run the same way from the start.

Every survivor recorded as equivalent below was re-run by hand under the **default profile** (1,000 fuzz
runs, 256 invariant runs, unit + invariant suites) with the mutant applied, and all 145 survived that too.
For each survivor's span, the sibling mutants forge generates for the same operator (the other comparison
operators, the other arithmetic operators; `scripts/mutation-siblings.py`) were run against the unit suites,
so that a mutant the runner "skipped" because its neighbour survived is accounted for. Signers: 38 siblings,
37 die, 1 does not compile (`s0 >= address(0)` makes the constructor always revert and solc then refuses the
never-assigned immutables, error 1284; forge's runner counts such a mutant as invalid). Draw: 45, 44 die, 1
does not compile (the same, on `distributor`). Converter: 217, 214 die, the 3 that survive are the three
threshold rewrites listed as equivalent below. Distributor: see its section.

Kill rate = killed / (generated − invalid); "invalid" mutants do not compile (forge counts them, they say
nothing about the tests).

Two things the run found about forge 1.8.3 itself, both under its dynamic test linking (on by default):

- **`vm.expectRevert` followed by a plain `new` of a linked contract checks only the first case.** The linker
  turns the `new` into a `vm.deployCode` call; the expected revert runs up through the test, and forge counts
  the test as passed because the test's own revert matched. `test_constructor_rejectsEveryZeroAddress`
  (Converter, 13 cases), `test_constructor_zeroToken_reverts` (5) and `test_constructor_invalidRateRange_reverts`
  (2) were checking one case each; the mutants that drop a later zero check survived and said so. The
  construction now goes through an external call on the test contract (`deployConverter`, `deployDistributor`
  in the two bases), which gives the cheatcode a frame to catch; the tests' gas went from ~36k to ~660k.
- **After a source edit, a test harness that inherits the edited contract can keep its old bytecode.** Seen
  while re-running mutants by hand: with `out/` holding artifacts built from one content of
  `NutzConverter.sol` and the file then rewritten, `forge test` recompiled the source and not
  `ConverterRoutesHarness is NutzConverter`, and the harness ran the previous mutant. `scripts/mutation-rerun.py`
  therefore builds with `--force` before every run; forge's own `--mutate` runner starts each mutant from a
  consistent copy of the project and is not affected (the Signers pass, whose tests all go through
  `SignersHarness`, killed 118 of 142).

## Results

| Contract | Generated | Invalid | Skipped | Tested | Killed before | Rate before | Survivors → tests | → equivalent | Rate after |
|---|---|---|---|---|---|---|---|---|---|
| `Signers` | 160 | 18 | 0 | 142 | 118 | 83.1% | 14 | 10 | 93.0% |
| `NutzDraw` | 173 | 12 | 0 | 161 | 150 | 93.2% | 1 | 10 | 93.8% |
| `NutzDistributor` | 775 | 26 | 12 | 737 | 646 | 87.7% | 21 | 70 | 90.5% |
| `NutzConverter` | 790 | 67 | 0 | 723 | 618 | 85.5% | 50 | 55 | 92.4% |

Tested = generated − invalid − skipped; "killed before" is the unit pass plus what the invariant suites add on
its survivors. A skipped mutant is one the runner left untested because another on its span had already
survived, so the 12 skipped sit on the spans of the Distributor's 91 survivors; the sibling check (below) ran
every other operator of every one of those spans by hand, the 70 equivalents' and the 21 killed ones' alike.

"Rate after" counts the equivalent mutants as survivors: it is the honest number, and it cannot reach 100%
while `<=` on an unsigned value against zero is a mutation operator.

### Signers

Killed by new tests in `test/unit/Signers.t.sol`:

| Location | Mutant | Test |
|---|---|---|
| L32 `PROPOSAL_TTL = 7 days` | `= 0` | `test_executeRotation_atTheLastSecondOfTheWindow_succeeds` |
| L46 `s0 == address(0)`, `s2 == address(0)` | `<` (drops the check) | `test_constructor_rejectsZeroSigner_inEverySlot` |
| L47 `s0 == s1` | `<`, `<=` | `test_constructor_rejectsEveryDuplicatePair`, `test_constructor_acceptsDistinctSigners_inAnyOrder` |
| L47 `s1 == s2` | `>`, `>=` | same two |
| L77 `signers[0] == from` | `<`, `<=` | `test_executeRotation_replacesExactlyTheSlotOfFrom` |
| L77 `signers[1] == from` | `>`, `>=` | same |
| L114 `block.timestamp > ready + PROPOSAL_TTL` | `>=` | `test_executeRotation_atTheLastSecondOfTheWindow_succeeds` |
| L114 `ready + PROPOSAL_TTL` | `ready \| PROPOSAL_TTL` | same (`ready` is 1,172,800 there: 1,172,800 + 604,800 = 1,777,600, 1,172,800 \| 604,800 = 1,703,872) |
| L132 `who == signers[1]` | `<=` | `test_proposeRotation_rejectsNonSignerFrom_belowEverySignerAddress` |

Equivalent:

| Location | Mutant | Why no test can tell |
|---|---|---|
| L46 `s0/s1/s2/keeper_ == address(0)` (4) | `<= address(0)` | an address is unsigned: `<= 0` is `== 0` |
| L59 `newKeeper == address(0)` | `<= address(0)` | same |
| L85 `readyAt[id] == 0`, L109 `ready == 0` | `<= 0` | same, on `uint256` |
| L92 `to == address(0)` | `<= address(0)` | same |
| L99 `readyAt[id] != 0` | `> 0` | same |
| L128 `nonce++` | `++nonce` | the expression's value is unused |

### NutzDraw

Killed by a new test in `test/unit/DrawRequest.t.sol`:

| Location | Mutant | Test |
|---|---|---|
| L117 `lastRound + 1` | `lastRound \| 1` | `test_requestDraw_threeInOneRound_eachTakesTheNextRound` (the two existing requests-in-one-round tests only ever stepped from an even `lastRound`, where `\| 1` and `+ 1` agree) |

Equivalent:

| Location | Mutant | Why no test can tell |
|---|---|---|
| L93 `distributor == address(0)` | `<= address(0)` | unsigned against zero |
| L112, L137 `d.seed != 0` | `d.seed > 0` | `bytes32` compares as unsigned |
| L113 `ticketsRoot == 0`, `ticketCount == 0` | `<= 0` | same |
| L118 `if (next > round) round = next` | `>=` | when `next == round` the assignment writes the value already there |
| L136 `round == 0` | `<= 0` | `uint64` against zero |
| L172 `flags & FLAG_COMPRESSED` | `flags / FLAG_COMPRESSED` | `flags` is a `uint8` and `FLAG_COMPRESSED` is `0x80`: the quotient is non-zero exactly when the top bit is set |
| L172 `flags & FLAG_COMPRESSED != 0` | `> 0` | unsigned against zero |
| L172 `flags & FLAG_INFINITY == 0` | `<= 0` | same |

### NutzDistributor

The invariant suites killed 9 of the unit pass's 100 survivors (the `>= 0` guards that turn a skipped zero
transfer into an attempted one, which a paused mock refuses; the `claimed`, `stuck` and `_tryTransfer` mutants
the handlers' ledger checks catch). Of the 91 left, 21 are killed by new tests and 70 are equivalent.

Killed by new tests (`test/unit/Distributor*.t.sol`; the two token mocks are `test/mocks/MockQuirkyERC20.sol`):

| Location | Mutant | Test |
|---|---|---|
| L157 `msg.sender != CONVERTER` | `>` | `test_funding_byAddressBelowTheConverter_reverts` |
| L226 `drawId <= drawBook.rootedThrough` (pullAcorn) | `==` | `test_pullAcorn_drawBelowRootedThrough_periodClosed` |
| L239 same, in `notifyDrawFunding` | `==` | `test_notifyDrawFunding_drawBelowRootedThrough_periodClosed` |
| L242 `L.funded[i] += amounts[i]` | `^=`, `\|=` | `test_notifyDrawFunding_accumulates` |
| L273 `id >= _currentPeriod(kind)` | `==` | `test_postRoot_futureEpoch_reverts` |
| L361 `ids.length != amounts.length`, `!= proofs.length` | `<` | `test_claimMany_lengthMismatch_reverts_inEitherDirection` |
| L396 the same two in `pushClaims` | `<` | `test_push_lengthMismatch_reverts_inEitherDirection` |
| L407 `totalFee += fee` | `^=`, `\|=` | `test_push_twoEntries_feesAddUpForTheKeeper` |
| L424 `min > max` | `>=` | `test_setRateRange_pointRange_isAccepted` |
| L472 `amount == 0` (payout skip) | `<` (never skips) | `test_claim_zeroLeg_neverCallsTransfer` |
| L487 `ret.length == 0` | `!=`, `<`, `>`, `>=` | `test_claim_tokenReturningFalse_isRecordedStuck`, `test_claim_tokenReturningNothing_isPaid` |
| L487 `ret.length == 0 \|\| abi.decode(ret, (bool))` | `!=` (xor) | same two |
| L528 `excludedList[i] == account` | `>=` | `test_exclusion_addressBelowEveryEntry_isAppended` |
| L588 `kind == Kind.Epoch` (`_currentPeriod`) | `>=` (always the Epoch clock) | `test_postRoot_draw_openWeek_reverts` |

Five more tests pin what the invariant suites already caught, so the unit pass alone would catch it next
time: `test_claim_paidLegs_leaveNothingStuck` (`\|\|` → `&&`/`==` in `_tryTransfer`),
`test_claim_stuckAccumulatesAcrossClaims` (`stuckOf += amount`), `test_claim_ledgerClaimedIsTheSumOfTheLeaves`
(`L.claimed[i] + amounts[i]`), `test_funding_zeroLeg_neverCallsTransferFrom` and
`test_notifyDrawFunding_zeroLeg_neverCallsTransferFrom` (`amounts[i] > 0` → `>= 0`, which a paused token turns
into a revert). Siblings: the 234 of the 70 equivalent spans all die under the unit suites but `totalFee != 0`
(above); of the 105 of the 21 killed spans, 99 die and the 6 that survive are equivalents already listed
(`!= 0` at L215, L218, L246; `<= 0` at L472, L487, L588).

Equivalent (70):

| Location | Mutant | Why no test can tell |
|---|---|---|
| L175, L209, L214, L241, L245, L284, L290, L315, L328, L367, L400, L456, L470 `i < N` (loop bound), L189 `i < excludedBase_.length`, L365, L398 `k < ids.length`, L394, L411 `n < entries.length`, L527 `i < n` (19) | `!=` | the counter starts below the bound and steps by one: it leaves the loop at exactly the bound either way |
| the same 19 loops' `i++` | `++i` | the expression's value is unused |
| L174 `converter_`, L177 `tokens_[i]`, L252 `draw`, L494, L501 `draw`, L525 `account` `== address(0)` (6) | `<= address(0)` | an address is unsigned: `<= 0` is `== 0` |
| L179 `minRate_ == 0`, L229 `usdg == 0`, L309 `rootPostedAt == 0`, L424 `min == 0`, L435, L472 `amount == 0`, L487 `ret.length == 0`, L554 `i == 0` (8) | `<= 0` | same, on `uint256` |
| L215, L246 `amounts[i] > 0`, L218 `usdg > 0`, L330 `f > 0` (4) | `!= 0` | same |
| L580 `postedAt != 0` | `> 0` | same |
| L253 `draw.seedOf(drawId) == bytes32(0)` | `<=` | `bytes32` compares as unsigned |
| L555 `i == 1`, L556 `i == 2`, L557 `i == 3` | `<=` | `tokens(i)` has already returned for every smaller `i` |
| L179 `minRate_ == 0 \|\| minRate_ > maxRate_`, L424 `min == 0 \|\| min > max` | `!=` (xor) | xor and or differ only when both sides hold, and `0 > max` never does |
| L389 `usdgPerEth < min \|\| usdgPerEth > max` | `!=` (xor) | both sides hold only if `min > max`, which the constructor and `setRateRange` refuse |
| L274 `kind == Kind.Draw` | `>=` | `Draw` is the enum's last value |
| L584, L588 `kind == Kind.Epoch` | `<=` | `Epoch` is its first |
| L311 `id != B.rootedThrough` (voidRoot) | `<` | a Root exists only at or below the mark (`postRoot` sets it, `voidRoot` deletes the Root when lowering it), so `id > rootedThrough` has already failed `NoRoot` |
| L414 `totalFee > 0` | `>=` | `_payout` skips a zero amount, so the extra call moves nothing and emits nothing; the sibling `!= 0` is `> 0` on `uint256` |
| L580 `postedAt != 0 && block.timestamp >= postedAt + CLAIM_DELAY` | `==` | differs only when both sides are false, i.e. no Root and `block.timestamp < 30 minutes`; the constructor needs `block.timestamp >= 1 hour` (`currentEpoch() - 1`) and time does not run backwards |

### NutzConverter

The unit pass left 107 survivors; the invariant suites (the two that deploy a Converter, `ConverterInvariantTest`
and `ConverterMedusaInvariantTest`) kill 2 of them, the `-` for `+` in both fee-pull gates, which underflow
when the tax exceeds the fee. Of the 105 left, 50 are killed by new tests and 55 are equivalent.

Killed by new tests (`test/unit/Converter*.t.sol`; `MockPoolManager` gained an `overfill` knob). The table
lists 52: the two `-` gate mutants the invariant suites already caught are pinned by the same new tests.

| Location | Mutant | Test |
|---|---|---|
| L89 `SPLIT_ACORN_BPS = 1000` | `= 0` | `test_splitConstants_addUp` (the constant is documentation: `_slice` takes Acorn as the remainder) |
| L212–L214 the seven-way `\|\|` zero-address chain | `&&` at five of its six joints (the first joint's mutant died in the unit pass: the Distributor is the test's first case); `<` on six of the operands (drops that check) | `test_constructor_rejectsEveryZeroAddress`, once it checked every case (see the linking note above) |
| L216 `i < 5` (token loop) | `==`, `>`, `>=` (never runs) | same |
| L219 `address(p.tokens[i]) == address(0)` | `<` | same |
| L226 `routerWeth != p.weth` | `<` | `test_constructor_rejectsRouterWithWethOnEitherSideOfOurs` |
| L253 `launch.creatorFeeRecipient != address(this)` | `>` | `test_bind_recipientBelowTheConverter_reverts` |
| L321, L528 `block.timestamp > deadline` | `!=` (a future deadline reverts) | `test_sweep_deadlineInTheFuture_isAccepted`, `test_convertAcorn_deadlineInTheFuture_isAccepted` |
| L365 curve `quoteFeeBalance() + creatorTaxBalance()` | `&`, `*`, `-`, `^` | `test_phase0_sweepsCurve_withFeesAloneOrEqualTax` |
| L397 hook `pendingFees + pendingCreatorTax` | `&`, `*`, `-`, `^` | `test_phase2_sweepsHook_withFeesAloneOrEqualTax` |
| L438 `opsAmt > 0` | `>=` (calls the keeper with 0) | `test_ops_zeroCap_neverCallsTheKeeperWallet` |
| L505 `i < STOCK_LEGS` (approval loop) | `<=` (approves USDG for Cash alone before the real approval) | `test_sweep_usdgIsApprovedOnce_forCashAndAcornTogether` |
| L506 `amounts[i] > 0` | `>=` (approves 0 for a skipped Leg) | `test_sweep_skippedLeg_isNotApproved` |
| L531 `T4.balanceOf(this) - usdgBefore` | `+`, `<<`, `>>`, `^`, `\|` | `test_convertAcorn_convertsThePoolOnly_notUsdgHeldBeforehand` |
| L569 `route.venue == address(V3_ROUTER)` | `<=` | `test_unknownVenue_belowTheRouter_revertsBadVenue` |
| L595 v3 path length: `\|\|` → `&&`; `+` → `/`, `>>`, `^`; `%` → `>>`; `!= 0` → `< 0`; `-` → `&`, `>>` | | `test_v3_badLength_withTheRightEnds_revertsBadPath` (44 bytes with both end tokens in place, 18 bytes, empty) and `test_v3_threeHops_accepted` (89 bytes, which `path.length & 20` refuses) |
| L600 `first != …`, `last != …` | `<` | `test_v3_wrongEndToken_aboveTheExpected_revertsBadPath` |
| L635 `currency0 != c0` (`<`, `>`), `currency1 != c1` (`<`) | | `test_v4_wrongCurrency_onEitherSideOfTheRightOne_revertsBadPoolKey` |
| L657 `msg.sender != address(V4_POOL_MANAGER)` | `<` | `test_unlockCallback_fromEitherSideOfTheManager_revertsNotPoolManager` |
| L675 `filled != order.amountIn` | `<` (an over-charging hook passes) | `test_v4_overfill_isCaughtFailure` |

Equivalent (55):

| Location | Mutant | Why no test can tell |
|---|---|---|
| L212–L214 the seven constructor addresses, L219 `tokens[i]`, L249 `token`, L611 `tokenIn`, L620 `tokenOut`, L702 `nutz`, L711 `token` `== address(0)` (13) | `<= address(0)` | an address is unsigned: `<= 0` is `== 0` |
| L254 `launch.pairToken != address(0)`, L322 `nutz != address(0)` | `> address(0)` | same |
| L331 `ethIn == 0`, L419 `nutzIn == 0`, L603, L638 `amountIn == 0` | `<= 0` | same, on `uint256` |
| L397 `… == 0`, L398 ×2, L399 ×2 hook pending amounts | `<= 0` | same |
| L355 `launch.phase == PHASE_NOT_GRADUATED` | `<=` | `PHASE_NOT_GRADUATED` is 0 on a `uint8` |
| L365 `… > 0`, L404 `balanceOf(this) > 0`, L438 `opsAmt > 0`, L506 `amounts[i] > 0`, L508 `usdg > 0` | `!= 0` | same |
| L365, L397 `fee + tax` (the gate) | `\|` | non-zero exactly when either is, which is all the gate asks |
| L216, L337, L505, L535 loop `i < N` | `!=` | the counter starts at 0 and steps by one |
| the same four loops' `i++` | `++i` | the expression's value is unused |
| L328 `ethIn > MAX_SWEEP_ETH` | `>=` | at equality the cap writes the value already there |
| L435 `opsCap > keeperBalance` | `>=` | at equality both give zero headroom |
| L437 `opsAmt > headroom` | `>=` | at equality the cap writes the value already there |
| L474 `usdg - STOCK_LEGS * perStock` | `^` | `perStock` is `usdg / 4`, so `4 * perStock` is `usdg` with its two low bits cleared, and xor and minus both leave exactly those bits |
| L595 `V3_ADDRESS_BYTES + V3_HOP_BYTES` (43) | `%` (20), `&` (20), `\|` (23) | a lower threshold only lets lengths 20–42 through to the `% 23` check, which refuses all but 20; a 20-byte path has one address at both ends, and the Leg's two tokens differ, so the token check refuses that |
| L595 `… % V3_HOP_BYTES != 0` | `> 0` | unsigned against zero |
| L633 `tokenIn < tokenOut` | `<=` | a Leg's two tokens are never equal |
| L701 `leg == Leg.NutzToEth` | `<=` | it is the enum's first value |
| L705 `leg == Leg.EthToUsdg` | `<=` | `NutzToEth` has already returned |
| L720 `i == 0` | `<=` | unsigned against zero |
| L721–L723 `i == 1/2/3` | `<=` | `tokens(i)` has already returned for every smaller `i` |

## Runtime

Machine: i9-9900K (8 cores / 16 threads, turbo off after the Medusa campaign), `--mutation-jobs 16`. Per mutant
the fixed cost (workspace copy and compile) is ~11 CPU-seconds; the unit pass adds ~16 and the invariant pass
~24 at the reduced run counts.

| Contract | Mutants | Unit pass | Invariant pass |
|---|---|---|---|
| `Signers` | 160 | 9 min | 7.5 min |
| `NutzDraw` | 173 | 8 min | 8.5 min |
| `NutzDistributor` | 775 | 34 min | stopped at 2 h 30 with 140 left; 100 survivors by hand in ~10 min |
| `NutzConverter` | 790 | 43 min | 107 survivors by hand in ~12 min |

By hand (`scripts/mutation-rerun.py`, four copies of the repo in parallel, a forced build per mutant): ~25 s
of build plus the tests per mutant, so ~40 s for a unit-suite run and ~3.5 min for the default profile's full
suite. The 145 equivalents under the default profile took 56 minutes; the 639 sibling mutants about 1 h 40.

## Addendum, 2026-09-29: after the review's F08 fix

`src/NutzDraw.sol` was mutated again at `29da940` (the unit pass only; the Draw invariant suites had not
changed their verdicts on this file's spans): 186 mutants, 12 invalid, 162 killed. Survivors: the ten
equivalents above (line numbers shifted by the fix), `d.round != 0` → `d.round > 0` on the new check (`uint64`
against zero, equivalent), and `currentRound() >= d.round` → `==`, real: the regression test locked a request
only at the round's first second. It now locks an hour later too, and that mutant dies. Rate after: 93.7 %.
