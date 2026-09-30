// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFalseReturnERC20, MockNoReturnERC20} from "../mocks/MockQuirkyERC20.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorClaimTest is DistributorBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    Claim[] internal claims;

    function setUp() public override {
        super.setUp();
        claims.push(Claim(alice, amounts(1e18, 0, 0, 0, 100e18)));
        claims.push(Claim(bob, amounts(0, 2e18, 0, 0, 50e18)));
        claims.push(Claim(carol, amounts(0, 0, 3e18, 4e18, 0)));
    }

    function test_claim_paysAllocationToAccount_andMarksClaimed() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        vm.expectEmit(address(d));
        emit NutzDistributor.Claimed(EPOCH, e, alice, claims[0].amounts);
        vm.prank(makeAddr("anyone")); // anyone may claim for alice; tokens go to alice
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));

        assertEq(tok[0].balanceOf(alice), 1e18);
        assertEq(tok[4].balanceOf(alice), 100e18);
        assertTrue(d.claimed(EPOCH, e, alice));
        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        assertEq(L.claimed[0], 1e18);
        assertEq(L.claimed[4], 100e18);
    }

    function test_claim_beforeFinal_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, totalsOf(claims), 0);
        postRoot(EPOCH, e, rootOf(e, claims), totalsOf(claims));
        vm.warp(block.timestamp + 30 minutes - 1);
        bytes32[] memory proof = proofOf(e, claims, 0);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NotFinal.selector, e));
        d.claim(EPOCH, e, alice, claims[0].amounts, proof);
    }

    function test_claim_twice_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        bytes32[] memory proof = proofOf(e, claims, 0);
        d.claim(EPOCH, e, alice, claims[0].amounts, proof);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyClaimed.selector, e, alice));
        d.claim(EPOCH, e, alice, claims[0].amounts, proof);
    }

    function test_claim_wrongAmountsOrProof_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        bytes32[] memory proof = proofOf(e, claims, 0);
        bytes32[] memory bobsProof = proofOf(e, claims, 1);
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claim(EPOCH, e, alice, amounts(1e18, 0, 0, 0, 100e18 + 1), proof);
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claim(EPOCH, e, alice, claims[0].amounts, bobsProof);
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claim(EPOCH, e, bob, claims[0].amounts, proof);
    }

    function test_claim_leafExceedingTotals_reverts() public {
        // A Root whose leaves add up to more than the totals it committed: the cap, not the proof, stops it.
        uint256 e = DEPLOY_EPOCH;
        uint256[5] memory t = totalsOf(claims);
        t[4] = 120e18; // alice 100 + bob 50 = 150 > 120
        fund(e, t, 0);
        postRoot(EPOCH, e, rootOf(e, claims), t);
        vm.warp(block.timestamp + 30 minutes);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        bytes32[] memory bobsProof = proofOf(e, claims, 1);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.CapExceeded.selector, 4));
        d.claim(EPOCH, e, bob, claims[1].amounts, bobsProof);
    }

    function test_claim_afterVoidAndRepost_usesNewRoot() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, totalsOf(claims), 0);
        postRoot(EPOCH, e, keccak256("bad"), totalsOf(claims));
        voidRoot(EPOCH, e);
        postRoot(EPOCH, e, rootOf(e, claims), totalsOf(claims));
        vm.warp(block.timestamp + 30 minutes);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        assertEq(tok[4].balanceOf(alice), 100e18);
    }

    function test_claim_singleLeafTree() public {
        uint256 e = DEPLOY_EPOCH;
        Claim[] memory one = new Claim[](1);
        one[0] = claims[0];
        fundPostFinalize(e, one);
        d.claim(EPOCH, e, alice, one[0].amounts, proofOf(e, one, 0));
        assertEq(tok[4].balanceOf(alice), 100e18);
    }

    // ---- stuck path ----

    function test_claim_pausedToken_isRecordedStuck_othersPaid() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        tok[0].setPaused(true); // SPY paused by its issuer
        vm.expectEmit(address(d));
        emit NutzDistributor.Stuck(alice, 0, 1e18);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        assertEq(tok[0].balanceOf(alice), 0);
        assertEq(tok[4].balanceOf(alice), 100e18, "USDG still paid");
        assertEq(d.stuck(alice)[0], 1e18);
        assertTrue(d.claimed(EPOCH, e, alice), "claim is consumed even though a leg is stuck");
    }

    function test_claimStuck_paysOnceUnpaused_andOnlyOnce() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        tok[0].setPaused(true);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));

        vm.expectRevert(); // still paused: the retry reverts and keeps the record
        d.claimStuck(alice, 0);
        assertEq(d.stuck(alice)[0], 1e18);

        tok[0].setPaused(false);
        vm.expectEmit(address(d));
        emit NutzDistributor.StuckClaimed(alice, 0, 1e18);
        d.claimStuck(alice, 0);
        assertEq(tok[0].balanceOf(alice), 1e18);
        assertEq(d.stuck(alice)[0], 0);
        vm.expectRevert(NutzDistributor.NothingStuck.selector);
        d.claimStuck(alice, 0);
    }

    function test_claim_blockedAccount_isRecordedStuck() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        tok[4].setBlocked(alice, true);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        assertEq(d.stuck(alice)[4], 100e18);
        assertEq(tok[0].balanceOf(alice), 1e18);
    }

    function test_claim_paidLegs_leaveNothingStuck() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        uint256[5] memory s = d.stuck(alice);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(s[i], 0, "a transfer that succeeded is not stuck");
        }
    }

    function test_claim_zeroLeg_neverCallsTransfer() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        // alice's leaf carries no NVDA (token 1): a zero transfer is skipped, not attempted.
        vm.expectCall(address(tok[1]), abi.encodeCall(tok[1].transfer, (alice, 0)), 0);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
    }

    function test_claim_stuckAccumulatesAcrossClaims() public {
        // Two epochs claimed one at a time while SPY is paused: the record is the sum of both legs.
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        closeEpoch(e + 1);
        fundPostFinalize(e + 1, claims);
        tok[0].setPaused(true);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        d.claim(EPOCH, e + 1, alice, claims[0].amounts, proofOf(e + 1, claims, 0));
        assertEq(d.stuck(alice)[0], 2e18);
    }

    function test_claim_tokenReturningFalse_isRecordedStuck() public {
        (MockFalseReturnERC20 falseToken,) = redeployWithQuirkyTokens();
        Claim[] memory one = new Claim[](1);
        one[0] = Claim(alice, amounts(1e18, 0, 0, 0, 0));
        uint256 e = fundCurrentEpochAndFinalize(one);

        falseToken.setRefusing(true);
        vm.expectEmit(address(d));
        emit NutzDistributor.Stuck(alice, 0, 1e18);
        d.claim(EPOCH, e, alice, one[0].amounts, proofOf(e, one, 0));
        assertEq(falseToken.balanceOf(alice), 0);
        assertEq(d.stuck(alice)[0], 1e18, "a false return is a failed transfer");
    }

    function test_claim_tokenReturningNothing_isPaid() public {
        (, MockNoReturnERC20 silentToken) = redeployWithQuirkyTokens();
        Claim[] memory one = new Claim[](1);
        one[0] = Claim(alice, amounts(0, 2e18, 0, 0, 0));
        uint256 e = fundCurrentEpochAndFinalize(one);

        d.claim(EPOCH, e, alice, one[0].amounts, proofOf(e, one, 0));
        assertEq(silentToken.balanceOf(alice), 2e18, "an empty return is a success");
        assertEq(d.stuck(alice)[1], 0);
    }

    /// @dev The redeployed Distributor's first open Epoch: fund it, close it, post the Root, close the window.
    function fundCurrentEpochAndFinalize(Claim[] memory one) internal returns (uint256 e) {
        e = d.currentEpoch();
        fund(e, totalsOf(one), 0);
        closeEpoch(e);
        postRoot(EPOCH, e, rootOf(e, one), totalsOf(one));
        vm.warp(block.timestamp + 30 minutes);
    }

    /// @dev Replaces `d` with a Distributor whose SPY returns `false` when refusing and whose NVDA returns nothing.
    function redeployWithQuirkyTokens()
        internal
        returns (MockFalseReturnERC20 falseToken, MockNoReturnERC20 silentToken)
    {
        falseToken = new MockFalseReturnERC20();
        silentToken = new MockNoReturnERC20();
        IERC20[5] memory t = tokens();
        t[0] = IERC20(address(falseToken));
        t[1] = IERC20(address(silentToken));
        address[] memory excludedBase = new address[](1);
        excludedBase[0] = dead;
        d = deploy(converter, t, MIN_RATE, MAX_RATE, excludedBase);
        falseToken.mint(converter, 10e18);
        silentToken.mint(converter, 10e18);
        vm.startPrank(converter);
        falseToken.approve(address(d), type(uint256).max);
        silentToken.approve(address(d), type(uint256).max);
        for (uint256 i = 2; i < 5; i++) {
            tok[i].approve(address(d), type(uint256).max);
        }
        vm.stopPrank();
    }

    // ---- claimMany ----

    function test_claimMany_settlesSeveralEpochsForOneAccount() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        closeEpoch(e + 1);
        fundPostFinalize(e + 1, claims);

        uint256[] memory ids = new uint256[](2);
        ids[0] = e;
        ids[1] = e + 1;
        uint256[5][] memory am = new uint256[5][](2);
        am[0] = claims[0].amounts;
        am[1] = claims[0].amounts;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proofOf(e, claims, 0);
        proofs[1] = proofOf(e + 1, claims, 0);
        d.claimMany(EPOCH, ids, alice, am, proofs);
        assertEq(tok[4].balanceOf(alice), 200e18);
        assertTrue(d.claimed(EPOCH, e, alice));
        assertTrue(d.claimed(EPOCH, e + 1, alice));
    }

    function test_claimMany_oneBadLeaf_revertsAll() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        closeEpoch(e + 1);
        fundPostFinalize(e + 1, claims);
        uint256[] memory ids = new uint256[](2);
        ids[0] = e;
        ids[1] = e + 1;
        uint256[5][] memory am = new uint256[5][](2);
        am[0] = claims[0].amounts;
        am[1] = claims[1].amounts; // bob's leaf under alice's name
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proofOf(e, claims, 0);
        proofs[1] = proofOf(e + 1, claims, 1);
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.claimMany(EPOCH, ids, alice, am, proofs);
        assertFalse(d.claimed(EPOCH, e, alice));
    }

    function test_claimMany_lengthMismatch_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        uint256[5][] memory am1 = new uint256[5][](1);
        am1[0] = claims[0].amounts;
        bytes32[][] memory proofs1 = new bytes32[][](1);
        proofs1[0] = proofOf(e, claims, 0);

        vm.expectRevert(NutzDistributor.LengthMismatch.selector);
        d.claimMany(EPOCH, ids, alice, new uint256[5][](2), proofs1);
        vm.expectRevert(NutzDistributor.LengthMismatch.selector);
        d.claimMany(EPOCH, ids, alice, am1, new bytes32[][](2));
        assertFalse(d.claimed(EPOCH, e, alice));
    }

    function test_claimMany_lengthMismatch_reverts_inEitherDirection() public {
        // More ids than amounts or proofs is the mismatch, not an out-of-bounds read.
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        uint256[] memory two = new uint256[](2);
        two[0] = e;
        two[1] = e;
        uint256[5][] memory am1 = new uint256[5][](1);
        am1[0] = claims[0].amounts;
        bytes32[][] memory proofs1 = new bytes32[][](1);
        proofs1[0] = proofOf(e, claims, 0);

        vm.expectRevert(NutzDistributor.LengthMismatch.selector);
        d.claimMany(EPOCH, two, alice, am1, new bytes32[][](2));
        vm.expectRevert(NutzDistributor.LengthMismatch.selector);
        d.claimMany(EPOCH, two, alice, new uint256[5][](2), proofs1);
    }

    function test_claim_ledgerClaimedIsTheSumOfTheLeaves() public {
        // alice then bob on one Epoch: 100 + 50 USDG, a sum that xor or or would not reproduce.
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        d.claim(EPOCH, e, alice, claims[0].amounts, proofOf(e, claims, 0));
        d.claim(EPOCH, e, bob, claims[1].amounts, proofOf(e, claims, 1));
        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        assertEq(L.claimed[4], 150e18);
        assertEq(L.claimed[0], 1e18);
        assertEq(L.claimed[1], 2e18);
    }

    // ---- parity with the JS library (ADR-0001) ----

    function test_fixture_proofsFromOpenZeppelinJs_areAccepted_andMurkyReproducesTheRoot() public {
        string memory json = vm.readFile("test/fixtures/claims.json");
        uint256 id = vm.parseJsonUint(json, ".id");
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        assertEq(id, DEPLOY_EPOCH, "fixture is built for the deploy epoch");

        uint256 n = 6;
        Claim[] memory fx = new Claim[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory k = string.concat(".claims[", vm.toString(i), "]");
            fx[i].account = vm.parseJsonAddress(json, string.concat(k, ".account"));
            uint256[] memory a = vm.parseJsonUintArray(json, string.concat(k, ".amounts"));
            for (uint256 t = 0; t < 5; t++) {
                fx[i].amounts[t] = a[t];
            }
            assertEq(leafOf(id, fx[i].account, fx[i].amounts), vm.parseJsonBytes32(json, string.concat(k, ".leaf")));
        }
        assertEq(rootOf(id, fx), root, "murky root == JS root");

        fund(id, totalsOf(fx), 0);
        postRoot(EPOCH, id, root, totalsOf(fx));
        vm.warp(block.timestamp + 30 minutes);
        for (uint256 i = 0; i < n; i++) {
            string memory k = string.concat(".claims[", vm.toString(i), "]");
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(k, ".proof"));
            d.claim(EPOCH, id, fx[i].account, fx[i].amounts, proof);
            assertEq(tok[4].balanceOf(fx[i].account), fx[i].amounts[4]);
        }
    }
}
