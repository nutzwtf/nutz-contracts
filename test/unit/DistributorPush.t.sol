// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorPushTest is DistributorBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // 0.1 gwei gas price, 4,000 USDG per ETH (raw, 6 decimals): one-leaf push costs 140_000 gas = 0.056 USDG.
    uint256 internal constant GAS_PRICE = 1e8;
    uint256 internal constant RATE = 4_000e6;
    uint256 internal constant ONE_LEAF_FEE = 0.056e6;
    uint256 internal constant TWO_LEAF_FEE = 0.072e6; // 180_000 gas

    Claim[] internal claims;

    function setUp() public override {
        super.setUp();
        claims.push(Claim(alice, amounts(1e18, 0, 0, 0, 100e6)));
        claims.push(Claim(bob, amounts(0, 2e18, 0, 0, 1.12e6))); // exactly 20x the one-leaf fee
    }

    function ids1(uint256 e) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = e;
    }

    function push(NutzDistributor.PushEntry[] memory entries) internal {
        vm.prank(keeper);
        d.pushClaims(entries, GAS_PRICE, RATE);
    }

    function test_push_paysStocksInFull_usdgMinusFee_feeToKeeper() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(alice, EPOCH, ids1(e), claims[0].amounts, claims, 0);

        vm.expectEmit(address(d));
        emit NutzDistributor.Pushed(alice, EPOCH, ids1(e), ONE_LEAF_FEE);
        push(entries);

        assertEq(tok[0].balanceOf(alice), 1e18, "stock in full");
        assertEq(tok[4].balanceOf(alice), 100e6 - ONE_LEAF_FEE);
        assertEq(tok[4].balanceOf(keeper), ONE_LEAF_FEE, "fee reimburses the gas payer");
        assertTrue(d.claimed(EPOCH, e, alice));
    }

    function test_push_feeAtExactlyFivePercent_passes_oneRawUnitMore_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(bob, EPOCH, ids1(e), claims[1].amounts, claims, 1);

        // The smallest gas-price bump that adds one raw USDG unit to the fee (1e18 / (140_000 * 4_000e6), rounded
        // up) makes it exceed 5% of bob's 1.12 USDG.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PushFeeTooHigh.selector, bob));
        d.pushClaims(entries, GAS_PRICE + 1_786, RATE);

        push(entries);
        assertEq(tok[4].balanceOf(bob), 1.12e6 - ONE_LEAF_FEE);
    }

    function test_push_multiEpochEntry_chargesBasePlusPerLeaf_onceAgainstTheSum() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        closeEpoch(e + 1);
        fundPostFinalize(e + 1, claims);
        uint256[] memory ids = new uint256[](2);
        ids[0] = e;
        ids[1] = e + 1;
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(bob, EPOCH, ids, claims[1].amounts, claims, 1);
        push(entries); // 2.24 USDG pending, 0.072 fee: under 5% only because the leaves are summed
        assertEq(tok[4].balanceOf(bob), 2.24e6 - TWO_LEAF_FEE);
        assertEq(tok[1].balanceOf(bob), 4e18);
        assertEq(tok[4].balanceOf(keeper), TWO_LEAF_FEE);
    }

    function test_push_oneBadEntry_revertsWholeBatch() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](2);
        entries[0] = entryFor(alice, EPOCH, ids1(e), claims[0].amounts, claims, 0);
        entries[1] = entryFor(bob, EPOCH, ids1(e), claims[0].amounts, claims, 0); // alice's leaf as bob
        vm.prank(keeper);
        vm.expectRevert(NutzDistributor.InvalidProof.selector);
        d.pushClaims(entries, GAS_PRICE, RATE);
        assertFalse(d.claimed(EPOCH, e, alice));
    }

    function test_push_rateOutsideRange_reverts() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(alice, EPOCH, ids1(e), claims[0].amounts, claims, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.RateOutOfRange.selector, 10_000e6 + 1));
        d.pushClaims(entries, GAS_PRICE, 10_000e6 + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.RateOutOfRange.selector, 1_000e6 - 1));
        d.pushClaims(entries, GAS_PRICE, 1_000e6 - 1);
    }

    function test_push_sixDecimalRate_deductsRawUsdgFee() public {
        // 1 gwei gas price, 2,500 USDG per ETH: one-leaf push costs 140_000 gas = 0.35 USDG = 350_000 raw.
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(alice, EPOCH, ids1(e), claims[0].amounts, claims, 0);
        vm.prank(keeper);
        d.pushClaims(entries, 1 gwei, 2_500e6);
        assertEq(tok[4].balanceOf(alice), 100e6 - 350_000, "fee is raw USDG, 6 decimals");
        assertEq(tok[4].balanceOf(keeper), 350_000);
    }

    function test_push_byNonKeeper_reverts() public {
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](0);
        vm.expectRevert(Signers.NotKeeper.selector);
        d.pushClaims(entries, GAS_PRICE, RATE);
    }

    function test_push_usdgPaused_stucksHolderAndKeeperFee_stocksStillPaid() public {
        uint256 e = DEPLOY_EPOCH;
        fundPostFinalize(e, claims);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(alice, EPOCH, ids1(e), claims[0].amounts, claims, 0);
        tok[4].setPaused(true);
        push(entries);
        assertEq(tok[0].balanceOf(alice), 1e18);
        assertEq(d.stuck(alice)[4], 100e6 - ONE_LEAF_FEE);
        assertEq(d.stuck(keeper)[4], ONE_LEAF_FEE);
    }

    function testFuzz_push_feeNeverExceedsFivePercentOfPushedUsdg(uint256 gasPrice, uint256 rate, uint256 usdg) public {
        gasPrice = bound(gasPrice, 1, 1_000 gwei);
        rate = bound(rate, 1_000e6, 10_000e6);
        usdg = bound(usdg, 1, 1_000_000e6);
        uint256 e = DEPLOY_EPOCH;
        Claim[] memory one = new Claim[](1);
        one[0] = Claim(alice, amounts(0, 0, 0, 0, usdg));
        fundPostFinalize(e, one);
        NutzDistributor.PushEntry[] memory entries = new NutzDistributor.PushEntry[](1);
        entries[0] = entryFor(alice, EPOCH, ids1(e), one[0].amounts, one, 0);

        vm.prank(keeper);
        try d.pushClaims(entries, gasPrice, rate) {
            uint256 fee = tok[4].balanceOf(keeper);
            assertLe(fee * 10_000, usdg * 500, "fee within cap");
            assertEq(tok[4].balanceOf(alice) + fee, usdg, "nothing lost");
        } catch (bytes memory err) {
            assertEq(bytes4(err), NutzDistributor.PushFeeTooHigh.selector);
            assertFalse(d.claimed(EPOCH, e, alice), "refused push leaves the leaf claimable");
        }
    }

    // ---- rate range ----

    function test_setRateRange_withTwoSigners_updatesBounds() public {
        bytes32 sh = keccak256(abi.encode(SET_RATE_RANGE_TYPEHASH, uint256(2_000e6), uint256(3_000e6), d.nonce()));
        vm.expectEmit(address(d));
        emit NutzDistributor.RateRangeSet(2_000e6, 3_000e6);
        d.setRateRange(2_000e6, 3_000e6, sign(KEY_A, sh), sign(KEY_C, sh));
        assertEq(d.minUsdgPerEth(), 2_000e6);
        assertEq(d.maxUsdgPerEth(), 3_000e6);
    }

    function test_setRateRange_invalid_reverts() public {
        bytes32 sh = keccak256(abi.encode(SET_RATE_RANGE_TYPEHASH, uint256(3_000e6), uint256(2_000e6), uint256(0)));
        vm.expectRevert(NutzDistributor.InvalidRateRange.selector);
        d.setRateRange(3_000e6, 2_000e6, sign(KEY_A, sh), sign(KEY_C, sh));
        sh = keccak256(abi.encode(SET_RATE_RANGE_TYPEHASH, uint256(0), uint256(2_000e6), uint256(0)));
        vm.expectRevert(NutzDistributor.InvalidRateRange.selector);
        d.setRateRange(0, 2_000e6, sign(KEY_A, sh), sign(KEY_C, sh));
    }
}
