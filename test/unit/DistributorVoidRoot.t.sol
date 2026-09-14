// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorVoidRootTest is DistributorBase {
    bytes32 internal constant BAD = keccak256("bad-root");
    bytes32 internal constant GOOD = keccak256("good-root");

    function test_void_clearsRootKeepsFundingAndAllowsCorrectedRoot() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(1e18, 0, 0, 0, 100e18), 0);
        postRoot(EPOCH, e, BAD, amounts(1e18, 0, 0, 0, 90e18));

        vm.expectEmit(address(d));
        emit NutzDistributor.RootVoided(EPOCH, e);
        voidRoot(EPOCH, e);

        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        assertEq(L.root, bytes32(0));
        assertEq(L.rootPostedAt, 0);
        assertEq(L.totals[4], 0);
        assertEq(L.funded[4], 100e18, "funding stays in the epoch");
        assertEq(d.carry(EPOCH)[4], 0, "carry restored");
        assertEq(d.rootedThrough(EPOCH), e - 1);
        assertFalse(d.isFinal(EPOCH, e));

        // more funding may still arrive for that hour, then the corrected Root is posted
        fund(e, amounts(0, 0, 0, 0, 20e18), 0);
        postRoot(EPOCH, e, GOOD, amounts(1e18, 0, 0, 0, 120e18));
        assertEq(d.ledger(EPOCH, e).root, GOOD);
        assertEq(d.rootedThrough(EPOCH), e);
        assertEq(d.nonce(), 3, "post, void, post");
    }

    function test_void_restoresCarryExactly_withSkippedEpochInBetween() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(0, 0, 0, 0, 100e18), 0);
        postRoot(EPOCH, e, GOOD, amounts(0, 0, 0, 0, 60e18)); // carry 40
        closeEpoch(e + 2);
        fund(e + 1, amounts(0, 0, 0, 0, 5e18), 0); // will be skipped
        fund(e + 2, amounts(0, 0, 0, 0, 10e18), 0);
        postRoot(EPOCH, e + 2, BAD, amounts(0, 0, 0, 0, 55e18)); // carryIn 45, carry 0
        assertEq(d.carry(EPOCH)[4], 0);

        voidRoot(EPOCH, e + 2);
        assertEq(d.carry(EPOCH)[4], 45e18, "carry as it was before the bad Root");
        assertEq(d.rootedThrough(EPOCH), e + 1);
        assertTrue(d.ledger(EPOCH, e + 1).skipped, "skip is not undone");

        uint256[5] memory totals = amounts(0, 0, 0, 0, 55e18);
        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(EPOCH, e + 2, GOOD, totals, amounts(0, 0, 0, 0, 45e18));
        postRoot(EPOCH, e + 2, GOOD, totals);
    }

    function test_void_afterFinal_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        postRoot(EPOCH, e, BAD, zero5());
        vm.warp(block.timestamp + 30 minutes);
        bytes32 sh = voidRootHash(EPOCH, e, d.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.RootIsFinal.selector, e));
        d.voidRoot(EPOCH, e, sign(KEY_A, sh), sign(KEY_C, sh));
    }

    function test_void_nonLatestRoot_reverts() public {
        // Keeper was down: two closed epochs get their Roots minutes apart, both inside their windows.
        uint256 e = DEPLOY_EPOCH;
        closeEpoch(e + 1);
        postRoot(EPOCH, e, BAD, zero5());
        vm.warp(block.timestamp + 5 minutes);
        postRoot(EPOCH, e + 1, GOOD, zero5());
        bytes32 sh = voidRootHash(EPOCH, e, d.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NotLatestRoot.selector, e));
        d.voidRoot(EPOCH, e, sign(KEY_A, sh), sign(KEY_C, sh));
        // voiding the latest first, then the earlier one, works
        voidRoot(EPOCH, e + 1);
        voidRoot(EPOCH, e);
        assertEq(d.rootedThrough(EPOCH), e - 1);
    }

    function test_void_withoutRoot_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        bytes32 sh = voidRootHash(EPOCH, e, 0);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NoRoot.selector, e));
        d.voidRoot(EPOCH, e, sign(KEY_A, sh), sign(KEY_C, sh));
    }

    function test_void_oldPostSignatures_cannotBeReplayed() public {
        uint256 e = DEPLOY_EPOCH;
        bytes32 sh = postRootHash(EPOCH, e, BAD, zero5(), 0);
        bytes memory s1 = sign(KEY_A, sh);
        bytes memory s2 = sign(KEY_B, sh);
        d.postRoot(EPOCH, e, BAD, zero5(), s1, s2);
        voidRoot(EPOCH, e);
        vm.expectRevert(); // nonce is 2 now; the old signatures recover to non-Signers
        d.postRoot(EPOCH, e, BAD, zero5(), s1, s2);
    }
}
