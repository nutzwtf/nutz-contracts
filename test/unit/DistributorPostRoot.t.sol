// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorPostRootTest is DistributorBase {
    bytes32 internal constant ROOT1 = keccak256("root-1");
    bytes32 internal constant ROOT2 = keccak256("root-2");

    function test_postRoot_recordsRootTotalsAndRollsDustIntoCarry() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(10e18, 20e18, 30e18, 40e18, 500e18), 0);
        uint256[5] memory totals = amounts(10e18, 20e18, 30e18, 40e18 - 7, 500e18 - 3);

        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(EPOCH, e, ROOT1, totals, zero5());
        postRoot(EPOCH, e, ROOT1, totals);

        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        assertEq(L.root, ROOT1);
        assertEq(L.rootPostedAt, block.timestamp);
        assertEq(L.totals[3], 40e18 - 7);
        assertEq(d.rootedThrough(EPOCH), e);
        uint256[5] memory carry = d.carry(EPOCH);
        assertEq(carry[3], 7, "stock dust");
        assertEq(carry[4], 3, "usdg dust");
        assertEq(carry[0], 0);
        assertEq(d.nonce(), 1, "one privileged action consumed");
    }

    function test_postRoot_totalsAboveFundedPlusCarry_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(0, 0, 0, 0, 100e18), 0);
        uint256[5] memory totals = amounts(0, 0, 0, 0, 100e18 + 1);
        bytes32 sh = postRootHash(EPOCH, e, ROOT1, totals, 0);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, 4));
        d.postRoot(EPOCH, e, ROOT1, totals, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_postRoot_nextEpochMaySpendCarryInFull() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(0, 0, 0, 0, 100e18), 0);
        postRoot(EPOCH, e, ROOT1, amounts(0, 0, 0, 0, 60e18)); // leaves 40 in carry

        closeEpoch(e + 1);
        fund(e + 1, amounts(0, 0, 0, 0, 10e18), 0);
        uint256[5] memory totals = amounts(0, 0, 0, 0, 50e18); // 10 funded + 40 carry
        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(EPOCH, e + 1, ROOT2, totals, amounts(0, 0, 0, 0, 40e18));
        postRoot(EPOCH, e + 1, ROOT2, totals);
        assertEq(d.carry(EPOCH)[4], 0);
    }

    function test_postRoot_pastFundedEpochs_areSkippedIntoCarry() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(1e18, 0, 0, 0, 100e18), 0);
        closeEpoch(e + 1);
        fund(e + 1, amounts(2e18, 0, 0, 0, 0), 0);
        closeEpoch(e + 3); // e+2 has no funding at all
        fund(e + 3, amounts(0, 0, 0, 0, 5e18), 0);

        uint256[5] memory totals = amounts(3e18, 0, 0, 0, 105e18);
        vm.expectEmit(address(d));
        emit NutzDistributor.Skipped(EPOCH, e);
        vm.expectEmit(address(d));
        emit NutzDistributor.Skipped(EPOCH, e + 1);
        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(EPOCH, e + 3, ROOT1, totals, amounts(3e18, 0, 0, 0, 100e18));
        postRoot(EPOCH, e + 3, ROOT1, totals);

        assertTrue(d.ledger(EPOCH, e).skipped);
        assertTrue(d.ledger(EPOCH, e + 1).skipped);
        assertFalse(d.ledger(EPOCH, e + 2).skipped, "unfunded epochs are not marked");
        assertFalse(d.ledger(EPOCH, e + 3).skipped);
        assertEq(d.rootedThrough(EPOCH), e + 3);
        assertEq(d.carry(EPOCH)[0], 0);
        assertEq(d.carry(EPOCH)[4], 0);
    }

    function test_postRoot_skippedEpoch_cannotBeFundedOrRootedLater() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(0, 0, 0, 0, 1e18), 0);
        closeEpoch(e + 1);
        postRoot(EPOCH, e + 1, ROOT1, zero5());
        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodClosed.selector, e));
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
        bytes32 sh = postRootHash(EPOCH, e, ROOT2, zero5(), d.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodClosed.selector, e));
        d.postRoot(EPOCH, e, ROOT2, zero5(), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_postRoot_openEpoch_reverts() public {
        uint256 e = d.currentEpoch();
        bytes32 sh = postRootHash(EPOCH, e, ROOT1, zero5(), 0);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodNotClosed.selector, e));
        d.postRoot(EPOCH, e, ROOT1, zero5(), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_postRoot_twiceForSameEpoch_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        postRoot(EPOCH, e, ROOT1, zero5());
        bytes32 sh = postRootHash(EPOCH, e, ROOT2, zero5(), 1);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodClosed.selector, e));
        d.postRoot(EPOCH, e, ROOT2, zero5(), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_postRoot_withUnfundedEpoch_isAllowed() public {
        postRoot(EPOCH, DEPLOY_EPOCH, ROOT1, zero5());
        assertEq(d.ledger(EPOCH, DEPLOY_EPOCH).root, ROOT1);
    }

    function test_postRoot_signaturesForOtherTotals_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(0, 0, 0, 0, 100e18), 0);
        bytes32 sh = postRootHash(EPOCH, e, ROOT1, amounts(0, 0, 0, 0, 1e18), 0);
        vm.expectRevert(); // recovered addresses are not Signers
        d.postRoot(EPOCH, e, ROOT1, amounts(0, 0, 0, 0, 100e18), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_postRoot_requiresTwoSigners() public {
        bytes32 sh = postRootHash(EPOCH, DEPLOY_EPOCH, ROOT1, zero5(), 0);
        vm.expectRevert(Signers.SameSigner.selector);
        d.postRoot(EPOCH, DEPLOY_EPOCH, ROOT1, zero5(), sign(KEY_A, sh), sign(KEY_A, sh));
    }

    function test_isFinal_flipsExactlyAtClaimDelay() public {
        uint256 e = DEPLOY_EPOCH;
        assertFalse(d.isFinal(EPOCH, e), "no root");
        postRoot(EPOCH, e, ROOT1, zero5());
        assertFalse(d.isFinal(EPOCH, e), "just posted");
        vm.warp(block.timestamp + 30 minutes - 1);
        assertFalse(d.isFinal(EPOCH, e), "one second early");
        vm.warp(block.timestamp + 1);
        assertTrue(d.isFinal(EPOCH, e), "window closed");
    }

    /// @dev Over a random sequence of funded/rooted/skipped epochs, every wei funded is either
    ///      allocated in some Root's totals or sitting in Carry.
    function testFuzz_carryConservation(uint256[8] memory fundedUsdg, uint256[8] memory spendBps, uint8 skipMask)
        public
    {
        uint256 e = DEPLOY_EPOCH;
        uint256 sumFunded;
        uint256 sumTotals;
        for (uint256 k = 0; k < 8; k++) {
            uint256 id = e + k;
            closeEpoch(id);
            uint256 f = bound(fundedUsdg[k], 0, 1_000e18);
            if (f > 0) fund(id, amounts(0, 0, 0, 0, f), 0);
            sumFunded += f;
            if ((skipMask >> k) & 1 == 1) continue; // keeper never roots this hour
            uint256 available = d.ledger(EPOCH, id).funded[4] + d.carry(EPOCH)[4];
            // skipped epochs in between have not been rolled yet; postRoot rolls them, so add them here
            for (uint256 j = d.rootedThrough(EPOCH) + 1; j < id; j++) {
                available += d.ledger(EPOCH, j).funded[4];
            }
            uint256 t = available * bound(spendBps[k], 0, 10_000) / 10_000;
            postRoot(EPOCH, id, keccak256(abi.encode(id)), amounts(0, 0, 0, 0, t));
            sumTotals += t;
        }
        uint256 pendingSkipped;
        for (uint256 j = d.rootedThrough(EPOCH) + 1; j < e + 8; j++) {
            pendingSkipped += d.ledger(EPOCH, j).funded[4];
        }
        assertEq(sumFunded, sumTotals + d.carry(EPOCH)[4] + pendingSkipped);
    }
}
