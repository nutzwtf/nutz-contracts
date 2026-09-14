// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";
import {DistributorHandler} from "./DistributorHandler.sol";

/// @dev Spec §7 / spec.md §9: the Distributor can never pay out more than it was funded.
contract DistributorInvariantTest is DistributorBase {
    DistributorHandler internal h;
    MockNutzDraw internal draw;

    function setUp() public override {
        super.setUp();
        draw = new MockNutzDraw();
        installDrawContract(address(draw));
        h = new DistributorHandler(d, tok, draw, converter, keeper, [KEY_A, KEY_B, KEY_C], merkle);
        targetContract(address(h));
    }

    /// @notice Σ claimed[t] ≤ Σ funded[t]: no token was ever marked claimed beyond what came in.
    function invariant_claimedNeverExceedsFunded() public view {
        for (uint256 i = 0; i < 5; i++) {
            assertLe(h.ghostClaimed(i), h.ghostFunded(i));
        }
    }

    /// @notice The Distributor's balance backs every unclaimed allocation, every stuck amount and the Acorn pool.
    function invariant_balanceBacksObligations() public view {
        for (uint256 i = 0; i < 5; i++) {
            uint256 expected = h.ghostFunded(i) - h.ghostClaimed(i) + h.ghostStuckOutstanding(i);
            if (i == 4) expected = expected - h.ghostAcornPulled(); // acorn USDG that left is not owed
            assertEq(tok[i].balanceOf(address(d)), expected);
        }
    }

    /// @notice Per token and Kind: funded (rooted or skipped) == posted totals + carry; nothing is lost.
    function invariant_carryConservation() public view {
        _checkConservation(EPOCH, true);
        _checkConservation(DRAW, false);
    }

    function _checkConservation(NutzDistributor.Kind kind, bool isEpoch) internal view {
        uint256 through = d.rootedThrough(kind);
        uint256[5] memory fundedSoFar;
        uint256[5] memory postedTotals;
        uint256 n = isEpoch ? h.fundedEpochCount() : h.fundedDrawCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = isEpoch ? h.fundedEpochs(k) : h.fundedDraws(k);
            if (id > through) continue;
            NutzDistributor.Ledger memory L = d.ledger(kind, id);
            for (uint256 i = 0; i < 5; i++) {
                fundedSoFar[i] += L.funded[i];
            }
        }
        n = isEpoch ? h.rootedEpochCount() : h.rootedDrawCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = isEpoch ? h.rootedEpochs(k) : h.rootedDraws(k);
            NutzDistributor.Ledger memory L = d.ledger(kind, id);
            if (L.rootPostedAt == 0) continue; // voided: totals released
            for (uint256 i = 0; i < 5; i++) {
                postedTotals[i] += L.totals[i];
            }
        }
        uint256[5] memory carry = d.carry(kind);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(fundedSoFar[i], postedTotals[i] + carry[i]);
        }
    }

    /// @notice A claimed flag never flips back.
    function invariant_claimedIsMonotone() public view {
        uint256 n = h.claimedFlagCount();
        for (uint256 k = 0; k < n; k++) {
            (NutzDistributor.Kind kind, uint256 id, address account) = h.claimedFlags(k);
            assertTrue(d.claimed(kind, id, account));
        }
    }

    /// @notice Every period at or below the mark is rooted, skipped, or was never funded.
    function invariant_everythingBelowTheMarkIsSettled() public view {
        uint256 through = d.rootedThrough(EPOCH);
        uint256 n = h.fundedEpochCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = h.fundedEpochs(k);
            if (id > through) continue;
            NutzDistributor.Ledger memory L = d.ledger(EPOCH, id);
            bool anyFunding = false;
            for (uint256 i = 0; i < 5; i++) {
                anyFunding = anyFunding || L.funded[i] > 0;
            }
            if (!anyFunding) continue; // a zero-amount funding call leaves nothing to settle
            assertTrue(L.rootPostedAt != 0 || L.skipped, "funded period below the mark without Root or Skip");
        }
    }
}
