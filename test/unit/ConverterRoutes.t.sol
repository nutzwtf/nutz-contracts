// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {ConverterRoutesHarness} from "../harness/ConverterRoutesHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";

/// @dev Route validation and the two Venue adapters, one Leg at a time through the test wrapper.
///      Mock rates: 1 ETH -> 3,000 USDG; 500 USDG -> 1 SPY; 1,000,000 NUTZ -> 1 ETH.
contract ConverterRoutesTest is ConverterBase {
    uint256 internal constant ETH_USDG = 3_000e6; // USDG (6 dp) per 1e18 wei
    uint256 internal constant USDG_SPY = 2e27; // 1e6 USDG -> 2e15 SPY
    uint256 internal constant NUTZ_ETH = 1e12; // 1e18 NUTZ -> 1e12 wei

    address internal constant ETH = address(0);
    address internal v4Hooks = makeAddr("v4Hooks");
    address internal stranger = makeAddr("stranger");

    ConverterRoutesHarness internal h;
    MockERC20 internal nutzToken;
    MockERC20 internal usdg;
    MockERC20 internal spy;

    function setUp() public override {
        super.setUp();
        h = new ConverterRoutesHarness(params());
        usdg = tok[4];
        spy = tok[0];

        // NUTZ launched on Pons naming the harness as creator fee recipient, then bound.
        nutzToken = new MockERC20("NUTZ", "NUTZ");
        MockPonsCurve curve = new MockPonsCurve(escrow, address(h));
        IPonsV2LaunchFactory.LaunchedToken memory L = launchRecord(address(nutzToken), address(curve));
        L.creatorFeeRecipient = address(h);
        factory.setLaunchedToken(address(nutzToken), L);
        vm.prank(keeper);
        h.bindNutz(address(nutzToken));

        // Router inventory and rates.
        usdg.mint(address(router), 10_000_000e6);
        spy.mint(address(router), 10_000e18);
        vm.deal(address(router), 100 ether);
        vm.prank(address(router));
        weth.deposit{value: 100 ether}();
        router.setRate(address(usdg), ETH_USDG);
        router.setRate(address(spy), USDG_SPY);

        // Pool manager inventory; rates are per key, so each test sets its own.
        usdg.mint(address(pm), 10_000_000e6);
        spy.mint(address(pm), 10_000e18);
        vm.deal(address(pm), 100 ether);
    }

    // ---- fixtures ----

    function v3(bytes memory p, uint256 minOut) internal view returns (NutzConverter.Route memory) {
        return NutzConverter.Route({venue: address(router), minOut: minOut, data: p});
    }

    function v4(PoolKey memory k, uint256 minOut) internal view returns (NutzConverter.Route memory) {
        return NutzConverter.Route({venue: address(pm), minOut: minOut, data: abi.encode(k)});
    }

    /// @dev A single-hop v3 path; the fee tier is part of the path format but opaque to the mock.
    function path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    /// @dev The ETH/USDG v4 pool priced at the fixture rate, with 1 ETH in the harness to sell.
    function ethUsdgPool() internal returns (PoolKey memory k) {
        vm.deal(address(h), 1 ether);
        k = poolKey(ETH, address(usdg), address(0));
        pm.setRate(k, true, ETH_USDG);
    }

    /// @dev A v4 key over the two tokens in sorted order, any fee and tick spacing, no hook unless given.
    function poolKey(address a, address b, address hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 3000, tickSpacing: 60, hooks: IHooks(hooks)
        });
    }

    // ---- v3: validation ----

    function test_v3_singleHop_ethToUsdg_sendsValueNoApproval() public {
        vm.deal(address(h), 1 ether);
        (bool ok, uint256 out, bytes memory reason) =
            h.runLeg(NutzConverter.Leg.EthToUsdg, v3(path(address(weth), 100, address(usdg)), 0), 1 ether);
        assertTrue(ok);
        assertEq(out, 3_000e6);
        assertEq(reason.length, 0);
        assertEq(usdg.balanceOf(address(h)), 3_000e6);
        assertEq(address(h).balance, 0);
        assertEq(address(router).balance, 1 ether, "paid as msg.value");
        assertEq(router.allowanceSeen(address(weth)), 0, "no WETH approval involved");
        assertEq(weth.allowance(address(h), address(router)), 0);
    }

    function test_v3_multiHop_usdgToSpy_accepted() public {
        usdg.mint(address(h), 500e6);
        bytes memory p = abi.encodePacked(address(usdg), uint24(100), address(weth), uint24(3000), address(spy));
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.Spy, v3(p, 0), 500e6);
        assertTrue(ok);
        assertEq(out, 1e18);
        assertEq(spy.balanceOf(address(h)), 1e18);
        assertEq(usdg.balanceOf(address(h)), 0);
    }

    function test_v3_wrongFirstToken_revertsBadPath() public {
        usdg.mint(address(h), 500e6);
        vm.expectRevert(NutzConverter.BadPath.selector);
        h.runLeg(NutzConverter.Leg.Spy, v3(path(address(weth), 500, address(spy)), 0), 500e6);
    }

    function test_v3_wrongLastToken_revertsBadPath() public {
        usdg.mint(address(h), 500e6);
        vm.expectRevert(NutzConverter.BadPath.selector);
        h.runLeg(NutzConverter.Leg.Spy, v3(path(address(usdg), 500, address(tok[1])), 0), 500e6);
    }

    function test_v3_ethLeg_pathMustUseWethNotZero() public {
        vm.deal(address(h), 1 ether);
        vm.expectRevert(NutzConverter.BadPath.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, v3(path(ETH, 100, address(usdg)), 0), 1 ether);
    }

    function test_v3_badLength_revertsBadPath() public {
        usdg.mint(address(h), 500e6);
        bytes memory good = path(address(usdg), 500, address(spy));
        bytes memory tooShort = new bytes(42); // one byte short of a single hop
        bytes memory offByOne = abi.encodePacked(good, uint8(0)); // 44 bytes
        bytes memory halfHop = abi.encodePacked(good, uint24(100)); // 46 bytes: a fee with no token after it
        bytes[3] memory bad = [tooShort, offByOne, halfHop];
        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(NutzConverter.BadPath.selector);
            h.runLeg(NutzConverter.Leg.Spy, v3(bad[i], 0), 500e6);
        }
    }

    // ---- v3: approvals and ETH output ----

    function test_v3_erc20Input_exactApprovalZeroedOnSuccess() public {
        usdg.mint(address(h), 500e6);
        (bool ok,,) = h.runLeg(NutzConverter.Leg.Spy, v3(path(address(usdg), 500, address(spy)), 0), 500e6);
        assertTrue(ok);
        assertEq(router.allowanceSeen(address(usdg)), 500e6, "exact approval at the pull");
        assertEq(usdg.allowance(address(h), address(router)), 0, "zeroed afterwards");
    }

    function test_v3_erc20Input_approvalZeroedOnFailure() public {
        usdg.mint(address(h), 500e6);
        router.setReverts(address(spy), true);
        (bool ok, uint256 out, bytes memory reason) =
            h.runLeg(NutzConverter.Leg.Spy, v3(path(address(usdg), 500, address(spy)), 0), 500e6);
        assertFalse(ok);
        assertEq(out, 0);
        assertEq(reason, abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(spy)));
        assertEq(usdg.allowance(address(h), address(router)), 0, "zeroed after the failure too");
        assertEq(usdg.balanceOf(address(h)), 500e6, "input untouched");
    }

    function test_v3_nutzToEth_unwrapsWethToEth() public {
        nutzToken.mint(address(h), 4_000e18);
        router.setRate(address(weth), NUTZ_ETH); // the router prices by output token; NUTZ in, WETH out
        (bool ok, uint256 out,) =
            h.runLeg(NutzConverter.Leg.NutzToEth, v3(path(address(nutzToken), 10_000, address(weth)), 0), 4_000e18);
        assertTrue(ok);
        assertEq(out, 4e15);
        assertEq(address(h).balance, 4e15, "ETH, not WETH");
        assertEq(weth.balanceOf(address(h)), 0);
        assertEq(nutzToken.balanceOf(address(h)), 0);
        assertEq(nutzToken.allowance(address(h), address(router)), 0);
    }

    function test_v3_minOutNotMet_isCaughtFailure() public {
        vm.deal(address(h), 1 ether);
        (bool ok,, bytes memory reason) =
            h.runLeg(NutzConverter.Leg.EthToUsdg, v3(path(address(weth), 100, address(usdg)), 3_001e6), 1 ether);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("Error(string)", "Too little received"));
        assertEq(address(h).balance, 1 ether, "ETH stays");
    }

    // ---- venue ----

    function test_unknownVenue_revertsBadVenue() public {
        vm.deal(address(h), 1 ether);
        NutzConverter.Route memory r = v3(path(address(weth), 100, address(usdg)), 0);
        r.venue = stranger;
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.BadVenue.selector, stranger));
        h.runLeg(NutzConverter.Leg.EthToUsdg, r, 1 ether);
    }
    // ---- v4: validation ----

    function test_v4_priceLimits_areOneStepInsideTickMath() public view {
        (uint160 down, uint160 up) = h.priceLimits();
        assertEq(down, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(up, TickMath.MAX_SQRT_PRICE - 1);
    }

    function test_v4_swappedCurrencies_revertsBadPoolKey() public {
        vm.deal(address(h), 1 ether);
        PoolKey memory k = poolKey(ETH, address(usdg), address(0));
        (k.currency0, k.currency1) = (k.currency1, k.currency0);
        vm.expectRevert(NutzConverter.BadPoolKey.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 0), 1 ether);
    }

    function test_v4_wrongToken_revertsBadPoolKey() public {
        vm.deal(address(h), 1 ether);
        vm.expectRevert(NutzConverter.BadPoolKey.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, v4(poolKey(ETH, address(spy), address(0)), 0), 1 ether);
    }

    function test_v4_malformedData_revertsBadPoolKey() public {
        vm.deal(address(h), 1 ether);
        NutzConverter.Route memory r = v4(poolKey(ETH, address(usdg), address(0)), 0);
        r.data = abi.encodePacked(r.data, uint256(1)); // 192 bytes
        vm.expectRevert(NutzConverter.BadPoolKey.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, r, 1 ether);
        r.data = new bytes(100);
        vm.expectRevert(NutzConverter.BadPoolKey.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, r, 1 ether);
    }

    function test_v4_keyWithHook_accepted() public {
        vm.deal(address(h), 1 ether);
        PoolKey memory k = poolKey(ETH, address(usdg), v4Hooks);
        pm.setRate(k, true, ETH_USDG);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 0), 1 ether);
        assertTrue(ok);
        assertEq(out, 3_000e6);
    }

    function test_unlockCallback_fromStranger_revertsNotPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(NutzConverter.NotPoolManager.selector);
        h.unlockCallback("");
    }

    // ---- v4: settle and take ----

    function test_v4_ethToUsdg_settlesValueTakesUsdg() public {
        PoolKey memory k = ethUsdgPool();
        (bool ok, uint256 out, bytes memory reason) = h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 0), 1 ether);
        assertTrue(ok);
        assertEq(out, 3_000e6);
        assertEq(reason.length, 0);
        assertEq(usdg.balanceOf(address(h)), 3_000e6);
        assertEq(address(h).balance, 0);
        assertEq(address(pm).balance, 100 ether + 1 ether, "settled as value");
    }

    function test_v4_usdgToSpy_syncsTransfersSettles() public {
        usdg.mint(address(h), 500e6);
        PoolKey memory k = poolKey(address(usdg), address(spy), address(0));
        pm.setRate(k, address(usdg) < address(spy), USDG_SPY);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.Spy, v4(k, 0), 500e6);
        assertTrue(ok);
        assertEq(out, 1e18);
        assertEq(spy.balanceOf(address(h)), 1e18);
        assertEq(usdg.balanceOf(address(h)), 0);
        assertEq(usdg.balanceOf(address(pm)), 10_000_000e6 + 500e6, "paid by transfer");
        assertEq(usdg.allowance(address(h), address(pm)), 0, "no approval involved");
    }

    function test_v4_nutzToEth_takesEth() public {
        nutzToken.mint(address(h), 4_000e18);
        PoolKey memory k = poolKey(ETH, address(nutzToken), address(hook));
        pm.setRate(k, false, NUTZ_ETH);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.NutzToEth, v4(k, 0), 4_000e18);
        assertTrue(ok);
        assertEq(out, 4e15);
        assertEq(address(h).balance, 4e15);
        assertEq(nutzToken.balanceOf(address(h)), 0);
        assertEq(nutzToken.balanceOf(address(pm)), 4_000e18);
    }

    function test_v4_minOutNotMet_isCaughtFailure() public {
        PoolKey memory k = ethUsdgPool();
        (bool ok, uint256 out, bytes memory reason) = h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 3_001e6), 1 ether);
        assertFalse(ok);
        assertEq(out, 0);
        assertEq(reason, abi.encodeWithSelector(NutzConverter.InsufficientOutput.selector, 3_000e6, 3_001e6));
        assertEq(address(h).balance, 1 ether, "ETH stays");
        assertEq(usdg.balanceOf(address(h)), 0);
    }

    function test_v4_poolReverts_isCaughtFailure() public {
        usdg.mint(address(h), 500e6);
        PoolKey memory k = poolKey(address(usdg), address(spy), address(0));
        pm.setRate(k, address(usdg) < address(spy), USDG_SPY);
        pm.setReverts(k, true);
        (bool ok,, bytes memory reason) = h.runLeg(NutzConverter.Leg.Spy, v4(k, 0), 500e6);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(MockPoolManager.PoolReverts.selector));
        assertEq(usdg.balanceOf(address(h)), 500e6, "input untouched");
    }

    function test_v4_partialFill_isCaughtFailure() public {
        PoolKey memory k = ethUsdgPool();
        pm.setMaxFill(k, true, 0.4 ether);
        (bool ok,, bytes memory reason) = h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 0), 1 ether);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(NutzConverter.PartialFill.selector, 0.4 ether, 1 ether));
        assertEq(address(h).balance, 1 ether, "ETH stays");
    }
    // ---- guards ----

    function test_zeroAmountIn_succeedsWithNothingOutAndNoVenueCall() public {
        PoolKey memory k = ethUsdgPool();
        router.setReverts(address(usdg), true); // any router call would fail
        pm.setReverts(k, true); // any pool call would fail
        NutzConverter.Route[2] memory routes = [v3(path(address(weth), 100, address(usdg)), 1), v4(k, 1)];
        for (uint256 i = 0; i < 2; i++) {
            (bool ok, uint256 out, bytes memory reason) = h.runLeg(NutzConverter.Leg.EthToUsdg, routes[i], 0);
            assertTrue(ok);
            assertEq(out, 0);
            assertEq(reason.length, 0);
        }
        assertEq(address(h).balance, 1 ether);
    }

    function test_zeroAmountIn_stillValidatesRoute() public {
        vm.expectRevert(NutzConverter.BadPath.selector);
        h.runLeg(NutzConverter.Leg.EthToUsdg, v3(path(address(usdg), 100, address(weth)), 0), 0);
    }

    function test_nutzToEth_unbound_revertsNutzNotBound() public {
        ConverterRoutesHarness unbound = new ConverterRoutesHarness(params());
        vm.expectRevert(NutzConverter.NutzNotBound.selector);
        unbound.runLeg(NutzConverter.Leg.NutzToEth, v3(path(address(weth), 100, address(weth)), 0), 1);
    }

    function test_constructor_rejectsRouterWithOtherWeth() public {
        MockWETH other = new MockWETH();
        MockSwapRouter02 otherRouter = new MockSwapRouter02(address(other));
        NutzConverter.Params memory p = params();
        p.v3Router = address(otherRouter);
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.WethMismatch.selector, address(other)));
        new NutzConverter(p);
    }

    // ---- strict ----

    function test_strict_success_returnsAmountOut() public {
        vm.deal(address(h), 1 ether);
        uint256 out =
            h.runLegStrict(NutzConverter.Leg.EthToUsdg, v3(path(address(weth), 100, address(usdg)), 0), 1 ether);
        assertEq(out, 3_000e6);
        assertEq(usdg.balanceOf(address(h)), 3_000e6);
    }

    function test_strict_v3Failure_bubblesVenueRevert() public {
        vm.deal(address(h), 1 ether);
        router.setReverts(address(usdg), true);
        vm.expectRevert(abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(usdg)));
        h.runLegStrict(NutzConverter.Leg.EthToUsdg, v3(path(address(weth), 100, address(usdg)), 0), 1 ether);
    }

    function test_strict_v4MinOut_bubblesCallbackRevert() public {
        PoolKey memory k = ethUsdgPool();
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.InsufficientOutput.selector, 3_000e6, 3_001e6));
        h.runLegStrict(NutzConverter.Leg.EthToUsdg, v4(k, 3_001e6), 1 ether);
    }

    function test_strict_badRoute_revertsBeforeVenue() public {
        vm.deal(address(h), 1 ether);
        vm.expectRevert(NutzConverter.BadPath.selector);
        h.runLegStrict(NutzConverter.Leg.EthToUsdg, v3(path(address(usdg), 100, address(weth)), 0), 1 ether);
    }

    // ---- fuzz: the whole input goes in, the Venue's whole output comes out ----

    function testFuzz_v3_ethToUsdg(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 20 ether);
        vm.deal(address(h), amountIn);
        (bool ok, uint256 out,) =
            h.runLeg(NutzConverter.Leg.EthToUsdg, v3(path(address(weth), 100, address(usdg)), 0), amountIn);
        assertTrue(ok);
        assertEq(out, amountIn * ETH_USDG / 1e18);
        assertEq(usdg.balanceOf(address(h)), out);
        assertEq(address(h).balance, 0);
        assertEq(address(router).balance, amountIn);
    }

    function testFuzz_v3_usdgToSpy(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1_000_000e6);
        usdg.mint(address(h), amountIn);
        (bool ok, uint256 out,) =
            h.runLeg(NutzConverter.Leg.Spy, v3(path(address(usdg), 500, address(spy)), 0), amountIn);
        assertTrue(ok);
        assertEq(out, amountIn * USDG_SPY / 1e18);
        assertEq(spy.balanceOf(address(h)), out);
        assertEq(usdg.balanceOf(address(h)), 0);
        assertEq(usdg.allowance(address(h), address(router)), 0);
    }

    function testFuzz_v4_ethToUsdg(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 20 ether);
        vm.deal(address(h), amountIn);
        PoolKey memory k = poolKey(ETH, address(usdg), address(0));
        pm.setRate(k, true, ETH_USDG);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.EthToUsdg, v4(k, 0), amountIn);
        assertTrue(ok);
        assertEq(out, amountIn * ETH_USDG / 1e18);
        assertEq(usdg.balanceOf(address(h)), out);
        assertEq(address(h).balance, 0);
        assertEq(address(pm).balance, 100 ether + amountIn);
    }

    function testFuzz_v4_usdgToSpy(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1_000_000e6);
        usdg.mint(address(h), amountIn);
        PoolKey memory k = poolKey(address(usdg), address(spy), address(0));
        pm.setRate(k, address(usdg) < address(spy), USDG_SPY);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.Spy, v4(k, 0), amountIn);
        assertTrue(ok);
        assertEq(out, amountIn * USDG_SPY / 1e18);
        assertEq(spy.balanceOf(address(h)), out);
        assertEq(usdg.balanceOf(address(h)), 0);
    }

    /// @dev Any minOut above what the Venue pays is a caught failure on both Venues; at or below it succeeds.
    function testFuzz_minOut_boundary(uint256 minOut, bool useV4) public {
        PoolKey memory k = ethUsdgPool();
        NutzConverter.Route memory r = useV4 ? v4(k, minOut) : v3(path(address(weth), 100, address(usdg)), minOut);
        (bool ok, uint256 out,) = h.runLeg(NutzConverter.Leg.EthToUsdg, r, 1 ether);
        assertEq(ok, minOut <= 3_000e6);
        assertEq(out, ok ? 3_000e6 : 0);
        assertEq(address(h).balance, ok ? 0 : 1 ether);
    }
}
