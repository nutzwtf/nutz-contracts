// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorFundingTest is DistributorBase {
    // ---- constructor ----

    function test_constructor_recordsImmutablesAndInitialMarks() public view {
        assertEq(d.CONVERTER(), converter);
        assertEq(d.keeper(), keeper);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(address(d.tokens(i)), address(tok[i]));
        }
        assertEq(d.PUSH_GAS_BASE(), 100_000);
        assertEq(d.PUSH_GAS_PER_LEAF(), 40_000);
        assertEq(d.minUsdgPerEth(), 1_000e6);
        assertEq(d.maxUsdgPerEth(), 10_000e6);
        assertEq(d.currentEpoch(), 500_001, "one hour after deploy");
        assertEq(d.currentDraw(), 2_976);
        assertEq(d.rootedThrough(EPOCH), 499_999);
        assertEq(d.rootedThrough(DRAW), 2_975);
        assertEq(d.excluded().length, 1);
        assertEq(d.excluded()[0], dead);
    }

    function test_constructor_zeroConverter_reverts() public {
        vm.expectRevert(Signers.ZeroAddress.selector);
        this.deployDistributor(address(0), tokens(), MIN_RATE, MAX_RATE, new address[](0));
    }

    function test_constructor_zeroToken_reverts() public {
        for (uint256 i = 0; i < 5; i++) {
            IERC20[5] memory t = tokens();
            t[i] = IERC20(address(0));
            vm.expectRevert(Signers.ZeroAddress.selector);
            this.deployDistributor(converter, t, MIN_RATE, MAX_RATE, new address[](0));
        }
    }

    function test_constructor_invalidRateRange_reverts() public {
        vm.expectRevert(NutzDistributor.InvalidRateRange.selector);
        this.deployDistributor(converter, tokens(), 0, MAX_RATE, new address[](0));
        vm.expectRevert(NutzDistributor.InvalidRateRange.selector);
        this.deployDistributor(converter, tokens(), MAX_RATE + 1, MAX_RATE, new address[](0));
    }

    function test_constructor_pointRateRange_isAccepted() public {
        NutzDistributor p = deploy(converter, tokens(), MAX_RATE, MAX_RATE, new address[](0));
        assertEq(p.minUsdgPerEth(), MAX_RATE);
        assertEq(p.maxUsdgPerEth(), MAX_RATE);
    }

    // ---- notifyEpochFunding ----

    function test_funding_recordsAmountsAndPullsTokens() public {
        uint256 e = d.currentEpoch() - 1;
        uint256[5] memory a = amounts(1e18, 2e18, 3e18, 4e18, 500e18);
        vm.expectEmit(address(d));
        emit NutzDistributor.EpochFunded(e, a, 50e18);
        fund(e, a, 50e18);

        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(L.funded[i], a[i], "funded");
            assertEq(L.totals[i], 0);
            assertEq(L.claimed[i], 0);
        }
        assertEq(L.rootPostedAt, 0);
        assertEq(d.acornPoolUsdg(), 50e18);
        assertEq(tok[0].balanceOf(address(d)), 1e18);
        assertEq(tok[3].balanceOf(address(d)), 4e18);
        assertEq(tok[4].balanceOf(address(d)), 550e18, "USDG = cash + acorn");
    }

    function test_funding_accumulatesAcrossSweeps() public {
        uint256 e = d.currentEpoch() - 1;
        fund(e, amounts(1e18, 0, 0, 0, 100e18), 10e18);
        fund(e, amounts(2e18, 0, 0, 0, 200e18), 20e18);
        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        assertEq(L.funded[0], 3e18);
        assertEq(L.funded[4], 300e18);
        assertEq(d.acornPoolUsdg(), 30e18);
    }

    function test_funding_currentOpenEpoch_isAllowed() public {
        fund(d.currentEpoch(), amounts(0, 0, 0, 0, 1e18), 0);
        assertEq(d.ledger(EPOCH, d.currentEpoch()).funded[4], 1e18);
    }

    function test_funding_futureEpoch_reverts() public {
        uint256 e = d.currentEpoch() + 1;
        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodNotOpen.selector, e));
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
    }

    function test_funding_epochAtOrBelowRootedThrough_reverts() public {
        uint256 e = d.rootedThrough(EPOCH);
        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.PeriodClosed.selector, e));
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
    }

    function test_funding_zeroLeg_neverCallsTransferFrom() public {
        // A token with nothing to fund is not touched: a paused issuer must not be able to block the others.
        uint256 e = d.currentEpoch();
        vm.expectCall(address(tok[1]), abi.encodeCall(tok[1].transferFrom, (converter, address(d), 0)), 0);
        vm.expectCall(address(tok[4]), abi.encodeCall(tok[4].transferFrom, (converter, address(d), 0)), 0);
        fund(e, amounts(1e18, 0, 0, 0, 0), 0);
    }

    function test_funding_byNonConverter_reverts() public {
        uint256 e = d.currentEpoch();
        vm.prank(keeper);
        vm.expectRevert(NutzDistributor.NotConverter.selector);
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
    }

    function test_funding_byAddressBelowTheConverter_reverts() public {
        // The gate is equality, not order: an address numerically below the Converter is still not the Converter.
        uint256 e = d.currentEpoch();
        vm.prank(address(1));
        vm.expectRevert(NutzDistributor.NotConverter.selector);
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
    }

    function test_funding_withoutAllowance_reverts() public {
        uint256 e = d.currentEpoch();
        vm.prank(converter);
        tok[4].approve(address(d), 0);
        vm.prank(converter);
        vm.expectRevert();
        d.notifyEpochFunding(e, amounts(0, 0, 0, 0, 1e18), 0);
    }

    function testFuzz_funding_conservesTokens(uint256[5] memory a, uint256 acorn) public {
        for (uint256 i = 0; i < 5; i++) {
            a[i] = bound(a[i], 0, 1_000e18);
        }
        acorn = bound(acorn, 0, 1_000e18);
        uint256 e = d.currentEpoch();
        fund(e, a, acorn);
        NutzDistributor.Ledger memory L = d.ledger(EPOCH, e);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(tok[i].balanceOf(address(d)), L.funded[i]);
        }
        assertEq(tok[4].balanceOf(address(d)), L.funded[4] + d.acornPoolUsdg());
    }
}
