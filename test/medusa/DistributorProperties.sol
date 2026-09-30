// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Asserts} from "chimera/Asserts.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {DistributorSetup} from "./DistributorSetup.sol";

/// @dev Spec §7 / spec.md §9, the invariants of test/invariant/Distributor.invariant.t.sol as Medusa properties:
///      each runs after every call of a sequence, returns true when it holds and trips an assertion otherwise
///      (`t` under CryticAsserts is `assert(false)`, which Medusa reports as a failing test).
abstract contract DistributorProperties is DistributorSetup, Asserts {
    /// @notice Σ claimed[t] ≤ Σ funded[t]: no token was ever marked claimed beyond what came in.
    function property_claimedNeverExceedsFunded() public returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            lte(ghostClaimed[i], ghostFunded[i], "claimed past funded");
        }
        return true;
    }

    /// @notice The Distributor's balance backs every unclaimed allocation, every stuck amount and the Acorn pool.
    function property_balanceBacksObligations() public returns (bool) {
        for (uint256 i = 0; i < 5; i++) {
            uint256 expected = ghostFunded[i] - ghostClaimed[i] + ghostStuckOutstanding[i];
            if (i == USDG) expected = expected - ghostAcornPulled; // acorn USDG that left is not owed
            eq(tok[i].balanceOf(address(d)), expected, "balance does not back the obligations");
        }
        return true;
    }

    /// @notice Per token and Kind: funded (rooted or skipped) == posted totals + carry; nothing is lost.
    function property_carryConservation() public returns (bool) {
        _checkConservation(EPOCH, fundedEpochs, rootedEpochs);
        _checkConservation(DRAW, fundedDraws, rootedDraws);
        return true;
    }

    function _checkConservation(NutzDistributor.Kind kind, uint256[] storage funded, uint256[] storage rooted)
        internal
    {
        uint256 through = d.rootedThrough(kind);
        uint256[5] memory fundedSoFar;
        uint256[5] memory postedTotals;
        for (uint256 k = 0; k < funded.length; k++) {
            uint256 id = funded[k];
            if (id > through) continue;
            NutzDistributor.Ledger memory L = d.ledger(kind, id);
            for (uint256 i = 0; i < 5; i++) {
                fundedSoFar[i] += L.funded[i];
            }
        }
        for (uint256 k = 0; k < rooted.length; k++) {
            NutzDistributor.Ledger memory L = d.ledger(kind, rooted[k]);
            if (L.rootPostedAt == 0) continue; // voided: totals released
            for (uint256 i = 0; i < 5; i++) {
                postedTotals[i] += L.totals[i];
            }
        }
        uint256[5] memory carry = d.carry(kind);
        for (uint256 i = 0; i < 5; i++) {
            eq(fundedSoFar[i], postedTotals[i] + carry[i], "funded != totals + carry");
        }
    }

    /// @notice Spec §7 invariant 3: tokens leave the Distributor only to the `account` of a valid leaf (or to
    ///         the Keeper as a push fee, or to the Converter through `pullAcorn`), whoever made the call, and
    ///         every allowed amount either arrived or is recorded as stuck for that account. The attack actions
    ///         assert their revert inside the target function; this checks the ledger they left behind, which
    ///         the target functions fill from the balance changes around every paying call.
    function property_tokensLeaveOnlyToLeafAccounts() public returns (bool) {
        for (uint256 r = 0; r < recipients.length; r++) {
            address to = recipients[r];
            t(
                _isLeafAccount(to) || to == keeper || to == converter,
                "tokens reached an address that is not a leaf account, the Keeper or the Converter"
            );
            uint256[5] memory out = ghostOut[to];
            uint256[5] memory allowed = ghostAllowed[to];
            uint256[5] memory stuck = d.stuck(to);
            for (uint256 i = 0; i < 5; i++) {
                eq(out[i] + stuck[i], allowed[i], "paid + stuck != allowed");
            }
        }
        return true;
    }

    /// @notice Spec §6 "bad root": a Root whose leaves sum to more than its totals can never pay out more than
    ///         the totals. Per rooted period and token, claimed never exceeds totals; the target function asserts
    ///         that the claim crossing the line reverts CapExceeded.
    function property_claimsNeverExceedPeriodTotals() public returns (bool) {
        _checkPeriodCaps(EPOCH, rootedEpochs);
        _checkPeriodCaps(DRAW, rootedDraws);
        return true;
    }

    function _checkPeriodCaps(NutzDistributor.Kind kind, uint256[] storage rooted) internal {
        for (uint256 k = 0; k < rooted.length; k++) {
            NutzDistributor.Ledger memory L = d.ledger(kind, rooted[k]);
            for (uint256 i = 0; i < 5; i++) {
                lte(L.claimed[i], L.totals[i], "claimed past the period's totals");
            }
        }
    }

    /// @notice A claimed flag never flips back.
    function property_claimedIsMonotone() public returns (bool) {
        for (uint256 k = 0; k < claimedFlags.length; k++) {
            Flag storage f = claimedFlags[k];
            t(d.claimed(f.kind, f.id, f.account), "a claimed flag flipped back");
        }
        return true;
    }

    /// @notice Every period at or below the mark is rooted, skipped, or was never funded.
    function property_everythingBelowTheMarkIsSettled() public returns (bool) {
        uint256 through = d.rootedThrough(EPOCH);
        for (uint256 k = 0; k < fundedEpochs.length; k++) {
            uint256 id = fundedEpochs[k];
            if (id > through) continue;
            NutzDistributor.Ledger memory L = d.ledger(EPOCH, id);
            bool anyFunding = false;
            for (uint256 i = 0; i < 5; i++) {
                anyFunding = anyFunding || L.funded[i] > 0;
            }
            if (!anyFunding) continue; // a zero-amount funding call leaves nothing to settle
            t(L.rootPostedAt != 0 || L.skipped, "funded period below the mark without Root or Skip");
        }
        return true;
    }

    function _isLeafAccount(address who) internal view returns (bool) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == who) return true;
        }
        return false;
    }
}
