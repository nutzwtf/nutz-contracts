// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {ConverterHandler} from "./ConverterHandler.sol";

/// @dev Spec §9: the Converter never keeps Reward Tokens, converts exactly what it says it does, and lets value
///      out only to the Keeper (Ops), a Venue (a swap) or the Distributor (funding).
contract ConverterInvariantTest is ConverterBase {
    ConverterHandler internal h;
    MockNutzDraw internal draw;

    function setUp() public override {
        super.setUp();
        draw = new MockNutzDraw();
        installDrawContract(address(draw));
        h = new ConverterHandler(
            ConverterHandler.Fixture({
                c: c,
                d: d,
                tok: tok,
                weth: weth,
                router: router,
                pm: pm,
                escrow: escrow,
                factory: factory,
                hook: hook,
                draw: draw,
                keeper: keeper,
                keys: [KEY_A, KEY_B, KEY_C]
            })
        );
        targetContract(address(h));
    }

    /// @notice After every successful Sweep or Acorn conversion the Converter holds no USDG and no Stock Token,
    ///         and no funding approval stays open. Reward Tokens only ever reach it inside those two calls, so
    ///         this holds after every call.
    function invariant_neverHoldsRewardTokens() public view {
        assertConverterEmpty();
    }

    /// @notice After every successful Sweep: the ETH balance fell by exactly B, and B <= MAX_SWEEP_ETH.
    function invariant_sweepConvertsExactlyB() public view {
        ConverterHandler.SweepRecord memory r = h.lastSweep();
        if (r.count == 0) return;
        assertLe(r.ethIn, c.MAX_SWEEP_ETH(), "B above the cap");
        assertEq(r.balanceAfter, r.balanceBefore - r.ethIn, "balance did not fall by B");
        uint256 expected = r.balanceBefore > c.MAX_SWEEP_ETH() ? c.MAX_SWEEP_ETH() : r.balanceBefore;
        assertEq(r.ethIn, expected, "B is not min(balance, cap)");
    }

    /// @notice opsAmt <= B x 200 / 10000 and, when Ops paid anything, the Keeper's balance after the transfer
    ///         is at most opsCap (the Keeper pays no gas under a prank).
    function invariant_opsSliceIsBounded() public view {
        ConverterHandler.SweepRecord memory r = h.lastSweep();
        if (r.count == 0) return;
        assertLe(r.opsAmt, r.ethIn * c.SPLIT_OPS_BPS() / c.BPS(), "Ops above 2%");
        assertEq(r.keeperAfter - r.keeperBefore, r.opsAmt, "the Keeper received something other than opsAmt");
        if (r.opsAmt > 0) assertLe(r.keeperAfter, r.opsCap, "Ops overfilled the Keeper");
    }

    /// @notice Per Sweep: cashUsdg + acornUsdg + Σ USDG spent on successful stock Legs == usdgOut. Every unit of
    ///         USDG is either swapped or funded. Per Acorn conversion the same holds of the pool pulled.
    function invariant_everyUsdgUnitIsSwappedOrFunded() public view {
        ConverterHandler.SweepRecord memory r = h.lastSweep();
        if (r.count > 0) {
            assertEq(r.usdg.toVenues + r.usdg.toDistributor, r.usdg.fromVenues, "USDG neither swapped nor funded");
            assertEq(r.usdg.toDistributor, r.amounts[4] + r.acornUsdg, "funded USDG is not Cash + Acorn");
        }
        ConverterHandler.AcornRecord memory a = h.lastAcorn();
        if (a.count > 0) {
            assertEq(a.usdg.fromDistributor, a.usdgIn, "the pull is not usdgIn");
            assertEq(a.usdg.toVenues + a.usdg.toDistributor, a.usdgIn, "pool USDG neither swapped nor funded");
            assertEq(a.usdg.toDistributor, a.amounts[4], "funded USDG is not amounts[4]");
        }
    }

    /// @notice The Distributor's funded[epoch] grew by exactly the amounts in Swept and acornPoolUsdg by exactly
    ///         acornUsdg; funded[draw] by exactly the amounts in AcornConverted. A change, not the whole ledger:
    ///         several Sweeps may fund one Epoch, which is what §9 means by "after the call". Over the whole run
    ///         the ledgers add up to the events and the pool to what the Sweeps added minus what the conversions
    ///         pulled.
    function invariant_distributorLedgerMatchesEvents() public view {
        ConverterHandler.SweepRecord memory r = h.lastSweep();
        if (r.count > 0) {
            for (uint256 i = 0; i < 5; i++) {
                assertEq(r.fundedDelta[i], r.amounts[i], "Epoch ledger does not match Swept");
            }
            assertEq(r.acornPoolDelta, r.acornUsdg, "acorn pool does not match Swept");
        }
        ConverterHandler.AcornRecord memory a = h.lastAcorn();
        if (a.count > 0) {
            for (uint256 i = 0; i < 5; i++) {
                assertEq(a.fundedDelta[i], a.amounts[i], "Draw ledger does not match AcornConverted");
            }
        }

        uint256[5] memory epochTotal = _ledgerTotal(NutzDistributor.Kind.Epoch);
        uint256[5] memory drawTotal = _ledgerTotal(NutzDistributor.Kind.Draw);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(epochTotal[i], h.ghostSweptAmount(i), "Epoch ledgers do not add up to the Swept events");
            assertEq(drawTotal[i], h.ghostAcornAmount(i), "Draw ledgers do not add up to AcornConverted");
        }
        assertEq(d.acornPoolUsdg(), h.ghostAcornAdded() - h.ghostAcornPulled(), "acorn pool off");
    }

    function _ledgerTotal(NutzDistributor.Kind kind) internal view returns (uint256[5] memory total) {
        bool isEpoch = kind == NutzDistributor.Kind.Epoch;
        uint256 n = isEpoch ? h.fundedEpochCount() : h.fundedDrawCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = isEpoch ? h.fundedEpochs(k) : h.fundedDraws(k);
            uint256[5] memory f = d.ledger(kind, id).funded;
            for (uint256 i = 0; i < 5; i++) {
                total[i] += f[i];
            }
        }
    }

    /// @notice ETH leaves the Converter only to the Keeper (Ops) or a Venue: what arrived minus what every
    ///         Sweep converted is what it holds, and each Sweep's B went to the Keeper and the Venues alone.
    function invariant_ethLeavesOnlyToKeeperOrVenue() public view {
        assertEq(address(c).balance, h.ghostEthArrived() - h.ghostEthSwept(), "ETH left by another door");
        ConverterHandler.SweepRecord memory r = h.lastSweep();
        if (r.count == 0) return;
        assertEq(r.ethToVenues, r.ethIn - r.opsAmt, "the Venues got something other than B - opsAmt");
    }

    /// @notice No function callable by a non-Keeper moves value out of the Converter: every Keeper entry point,
    ///         the Venue callback and the value-guarding Signer actions a stranger tried reverted, and the two
    ///         conservation invariants above hold across the governance, receive and Venue-side actions the
    ///         handler itself runs without the Keeper (`executeLegEnable` among them, which anyone may call).
    function invariant_nonKeeperMovesNothing() public view {
        assertEq(h.ghostStrangerMoves(), 0, "a stranger's call went through");
    }

    /// @notice Reward Tokens move nowhere but between the Venues, the Converter (which keeps none) and the
    ///         Distributor: those three hold the whole supply.
    function invariant_rewardTokensGoNowhereButTheDistributor() public view {
        for (uint256 i = 0; i < 5; i++) {
            uint256 held = tok[i].balanceOf(address(router)) + tok[i].balanceOf(address(pm))
                + tok[i].balanceOf(address(c)) + tok[i].balanceOf(address(d));
            assertEq(held, tok[i].totalSupply(), "reward token escaped");
        }
    }

    /// @notice A disabled Leg never receives a swap: every Sweep and Acorn conversion skipped each disabled Leg
    ///         as "disabled" (and no enabled one), and no Stock Token moved while its Leg was disabled.
    function invariant_disabledLegNeverSwaps() public view {
        assertEq(h.ghostDisabledSkipsWrong(), 0, "a Leg's disabled skip disagreed with the Circuit breaker");
        assertEq(h.ghostDisabledLegSwaps(), 0, "a disabled Leg swapped");
    }

    /// @notice legDisabled flips true only through disableLeg and false only through executeLegEnable: the
    ///         contract's flags match the mirror those two actions alone maintain.
    function invariant_circuitBreakerFlipsOnlyThroughGovernance() public view {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(c.legDisabled(i), h.ghostDisabled(i), "legDisabled flipped outside governance");
        }
    }

    /// @notice The ops cap never exceeds its ceiling.
    function invariant_opsCapWithinCeiling() public view {
        assertLe(c.opsCap(), c.MAX_OPS_CAP_WEI());
    }
}
