// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Asserts} from "chimera/Asserts.sol";
import {ConverterSetup} from "./ConverterSetup.sol";

/// @dev Spec §9, the invariants of test/invariant/Converter.invariant.t.sol as Medusa properties. The forge suite
///      reads four of them off the `Swept`, `AcornConverted`, `LegSkipped` and `Transfer` logs of each call;
///      Medusa records no logs, so those four are restated on state: the ETH in the system adds up, the
///      Distributor's balances moved by exactly what the ledgers say, a disabled Leg's stock never moved, and B
///      is measured from the balances with the Fee pull and the NUTZ sale sized from the mocks' rates. What only
///      the events can say (the exact USDG flows between the Converter and the Venues, a skip's reason) stays
///      with forge (docs/setup/tools.md). Ten properties for forge's eleven: `everyUsdgUnitIsSwappedOrFunded`
///      and `distributorLedgerMatchesEvents` fold into `distributorUsdgMatchesLedgers` here.
abstract contract ConverterProperties is ConverterSetup, Asserts {
    /// @notice After every successful Sweep or Acorn conversion the Converter holds no USDG and no Stock Token,
    ///         and no funding approval stays open. Reward Tokens only ever reach it inside those two calls, so
    ///         this holds after every call.
    function property_neverHoldsRewardTokens() public returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            eq(tok[i].balanceOf(address(c)), 0, "reward token left behind");
            eq(tok[i].allowance(address(c), address(d)), 0, "approval left open");
        }
        return true;
    }

    /// @notice After every successful Sweep: the ETH balance fell by exactly B, B <= MAX_SWEEP_ETH and
    ///         B == min(balance, cap), the balance counting the Fee pull's take and the NUTZ sale's proceeds.
    function property_sweepConvertsExactlyB() public returns (bool) {
        SweepRecord memory r = sweepRecord;
        if (r.count == 0) return true;
        lte(r.ethIn, c.MAX_SWEEP_ETH(), "B above the cap");
        eq(r.balanceAfter, r.balanceBefore - r.ethIn, "balance did not fall by B");
        uint256 expected = r.balanceBefore > c.MAX_SWEEP_ETH() ? c.MAX_SWEEP_ETH() : r.balanceBefore;
        eq(r.ethIn, expected, "B is not min(balance, cap)");
        return true;
    }

    /// @notice opsAmt <= B x 200 / 10000 and, when Ops paid anything, the Keeper's balance after the transfer is
    ///         at most opsCap (the Keeper pays no gas under a prank). `opsAmt` is the Keeper's gain, so unlike the
    ///         forge version this does not also cross-check it against the `Swept` event.
    function property_opsSliceIsBounded() public returns (bool) {
        SweepRecord memory r = sweepRecord;
        if (r.count == 0) return true;
        lte(r.opsAmt, r.ethIn * c.SPLIT_OPS_BPS() / c.BPS(), "Ops above 2%");
        if (r.opsAmt > 0) lte(r.keeperAfter, r.opsCap, "Ops overfilled the Keeper");
        return true;
    }

    /// @notice The Distributor's USDG moved by exactly what the ledgers record: per Sweep it gained the Cash and
    ///         the Acorn USDG, per Acorn conversion it paid the pool out and took the unconverted USDG back. With
    ///         the Converter holding nothing afterwards and the Reward Token supply accounted for below, every
    ///         unit of USDG a call had was either swapped or funded.
    function property_distributorUsdgMatchesLedgers() public returns (bool) {
        SweepRecord memory r = sweepRecord;
        if (r.count > 0) {
            eq(
                r.distributorUsdgAfter,
                r.distributorUsdgBefore + r.fundedDelta[4] + r.acornPoolDelta,
                "Sweep: Distributor USDG is not Cash + Acorn"
            );
        }
        AcornRecord memory a = acornRecord;
        if (a.count > 0) {
            eq(
                a.distributorUsdgAfter + a.usdgIn,
                a.distributorUsdgBefore + a.fundedDelta[4],
                "Acorn: Distributor USDG is not pool out, unconverted back"
            );
            lte(a.fundedDelta[4], a.usdgIn, "Acorn: more USDG funded than pulled");
        }
        return true;
    }

    /// @notice ETH leaves the Converter only to the Keeper (Ops) or a Venue: everything the fixture and the
    ///         actions put into the system still sits with the Converter, the fee sources, the Venues or the
    ///         Keeper. A wei anywhere else, the Converter's own included, breaks the sum.
    function property_ethLeavesOnlyToKeeperOrVenue() public returns (bool) {
        eq(_systemEth(), ghostEthDealt, "ETH left by another door");
        return true;
    }

    /// @notice No function callable by a non-Keeper moves value out of the Converter: every Keeper entry point,
    ///         the Venue callback and the value-guarding Signer actions a stranger tried reverted, and the two
    ///         conservation properties hold across the governance, receive and Venue-side actions the harness
    ///         itself runs without the Keeper (`executeLegEnable` among them, which anyone may call).
    function property_nonKeeperMovesNothing() public returns (bool) {
        eq(ghostStrangerMoves, 0, "a stranger's call went through");
        return true;
    }

    /// @notice Reward Tokens move nowhere but between the Venues, the Converter (which keeps none) and the
    ///         Distributor: those three hold the whole supply.
    function property_rewardTokensGoNowhereButTheDistributor() public returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            uint256 held = tok[i].balanceOf(address(router)) + tok[i].balanceOf(address(pm))
                + tok[i].balanceOf(address(c)) + tok[i].balanceOf(address(d));
            eq(held, tok[i].totalSupply(), "reward token escaped");
        }
        return true;
    }

    /// @notice A disabled Leg never receives a swap: no Stock Token reached the Distributor through a Sweep or an
    ///         Acorn conversion while its Leg was disabled (the Converter keeps none, so the Distributor's balance
    ///         is where a swap would show).
    function property_disabledLegNeverSwaps() public returns (bool) {
        eq(ghostDisabledLegSwaps, 0, "a disabled Leg swapped");
        return true;
    }

    /// @notice legDisabled flips true only through disableLeg and false only through executeLegEnable: the
    ///         contract's flags match the mirror those two actions alone maintain.
    function property_circuitBreakerFlipsOnlyThroughGovernance() public returns (bool) {
        for (uint256 i = 0; i < 4; i++) {
            t(c.legDisabled(i) == ghostDisabled[i], "legDisabled flipped outside governance");
        }
        return true;
    }

    /// @notice The ops cap never exceeds its ceiling.
    function property_opsCapWithinCeiling() public returns (bool) {
        lte(c.opsCap(), c.MAX_OPS_CAP_WEI(), "ops cap above the ceiling");
        return true;
    }
}
