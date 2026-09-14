// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockPonsEscrow} from "../mocks/pons/MockPonsEscrow.sol";
import {MockPonsFactory} from "../mocks/pons/MockPonsFactory.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";
import {MockPonsHook} from "../mocks/pons/MockPonsHook.sol";

/// @dev Rejects every ETH transfer, to exercise the escrow's failed-payment path.
contract Rejector {
    MockPonsEscrow private immutable ESCROW;

    constructor(MockPonsEscrow escrow) {
        ESCROW = escrow;
    }

    function claim() external returns (uint256) {
        return ESCROW.claim();
    }
}

/// @dev A minimal v4 locker: one swap per unlock, driven by a plan so the test can skip the settle or the take
///      and watch the manager enforce netted deltas, or send a bad price limit or an exact-output order.
contract Locker is IUnlockCallback {
    error NotManager();

    struct Plan {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // negative = exact input, as on the real manager
        uint160 sqrtPriceLimitX96;
        bool settleInput;
        bool takeOutput;
    }

    MockPoolManager private immutable PM;

    constructor(MockPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function run(Plan memory plan) external returns (BalanceDelta) {
        return abi.decode(PM.unlock(abi.encode(plan)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert NotManager();
        Plan memory p = abi.decode(data, (Plan));
        BalanceDelta d = PM.swap(
            p.key,
            IPoolManager.SwapParams({
                zeroForOne: p.zeroForOne, amountSpecified: p.amountSpecified, sqrtPriceLimitX96: p.sqrtPriceLimitX96
            }),
            ""
        );
        (Currency cin, Currency cout) =
            p.zeroForOne ? (p.key.currency0, p.key.currency1) : (p.key.currency1, p.key.currency0);
        uint256 amountIn = uint256(-p.amountSpecified);
        uint256 out = uint256(uint128(p.zeroForOne ? d.amount1() : d.amount0()));
        if (p.settleInput) {
            if (cin.isAddressZero()) {
                PM.settle{value: amountIn}();
            } else {
                PM.sync(cin);
                IERC20(Currency.unwrap(cin)).transfer(address(PM), amountIn);
                PM.settle();
            }
        }
        if (p.takeOutput) PM.take(cout, address(this), out);
        return abi.encode(d);
    }
}

/// @dev Smoke tests for the Converter's mocks, so later tickets can trust them.
contract ConverterMocksTest is Test {
    address internal constant ETH = address(0);
    bytes32 internal constant POOL = keccak256("pool");

    address internal alice = makeAddr("alice"); // the creator fee recipient of the launch
    address internal bob = makeAddr("bob");
    address internal nutz = makeAddr("nutz");
    address internal v4Hooks = makeAddr("v4Hooks");

    // router fixture
    MockWETH internal weth;
    MockERC20 internal usdg;
    MockERC20 internal spy;
    MockSwapRouter02 internal router;

    // pool manager fixture
    MockPoolManager internal pm;
    Locker internal locker;
    MockERC20 internal nutzToken;
    PoolKey internal key;

    // ---- MockPonsEscrow ----

    function test_escrow_creditAccumulates_claimPaysEthAndZeroes() public {
        MockPonsEscrow escrow = new MockPonsEscrow();
        escrow.credit{value: 1 ether}(alice);
        escrow.credit{value: 2 ether}(alice);
        assertEq(escrow.balanceOf(alice), 3 ether);

        vm.prank(alice);
        uint256 paid = escrow.claim();
        assertEq(paid, 3 ether);
        assertEq(alice.balance, 3 ether);
        assertEq(escrow.balanceOf(alice), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_escrow_claimAtZero_revertsNoBalance() public {
        MockPonsEscrow escrow = new MockPonsEscrow();
        vm.prank(alice);
        vm.expectRevert(MockPonsEscrow.NoBalance.selector);
        escrow.claim();
    }

    function test_escrow_claimToRejectingReceiver_revertsTransferFailed() public {
        MockPonsEscrow escrow = new MockPonsEscrow();
        Rejector r = new Rejector(escrow);
        escrow.credit{value: 1 ether}(address(r));
        vm.expectRevert(MockPonsEscrow.TransferFailed.selector);
        r.claim();
    }

    // ---- MockPonsFactory ----

    function launch(address curve, address recipient, uint8 phase)
        internal
        view
        returns (IPonsV2LaunchFactory.LaunchedToken memory)
    {
        return IPonsV2LaunchFactory.LaunchedToken({
            token: nutz,
            curve: curve,
            deployer: alice,
            creatorFeeRecipient: recipient,
            pairToken: address(0),
            graduationThreshold: 1 ether,
            poolFee: 10_000,
            tickSpacing: 200,
            creatorTaxBps: 100,
            buybackEnabled: false,
            phase: phase,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            exists: true
        });
    }

    function test_factory_unknownToken_hasExistsFalse() public {
        MockPonsFactory f = new MockPonsFactory();
        IPonsV2LaunchFactory.LaunchedToken memory L = f.getLaunchedToken(nutz);
        assertFalse(L.exists);
        assertEq(L.curve, address(0));
    }

    function test_factory_setLaunchedToken_roundTrips() public {
        MockPonsFactory f = new MockPonsFactory();
        f.setLaunchedToken(nutz, launch(address(0xC0), alice, 2));
        IPonsV2LaunchFactory.LaunchedToken memory L = f.getLaunchedToken(nutz);
        assertTrue(L.exists);
        assertEq(L.token, nutz);
        assertEq(L.curve, address(0xC0));
        assertEq(L.creatorFeeRecipient, alice);
        assertEq(L.pairToken, address(0));
        assertEq(L.poolFee, 10_000);
        assertEq(L.tickSpacing, 200);
        assertEq(L.phase, 2);
    }

    // ---- MockPonsCurve ----

    function curveFixture() internal returns (MockPonsEscrow escrow, MockPonsCurve curve) {
        escrow = new MockPonsEscrow();
        curve = new MockPonsCurve(escrow, alice);
        vm.deal(address(curve), 10 ether);
    }

    function test_curve_sweepFees_creditsEscrowWithFeePlusTaxAndZeroes() public {
        (MockPonsEscrow escrow, MockPonsCurve curve) = curveFixture();
        curve.setBalances(0.3 ether, 0.1 ether);
        assertEq(curve.quoteFeeBalance(), 0.3 ether);
        assertEq(curve.creatorTaxBalance(), 0.1 ether);

        vm.prank(alice);
        curve.sweepFees(0);
        assertEq(escrow.balanceOf(alice), 0.4 ether);
        assertEq(address(escrow).balance, 0.4 ether);
        assertEq(curve.quoteFeeBalance(), 0);
        assertEq(curve.creatorTaxBalance(), 0);
    }

    function test_curve_sweepFees_protocolShareComesOffFeesNotTax() public {
        (MockPonsEscrow escrow, MockPonsCurve curve) = curveFixture();
        curve.setProtocolFeeShareBps(1_000); // 10%
        curve.setBalances(1 ether, 0.1 ether);
        vm.prank(alice);
        curve.sweepFees(0);
        assertEq(escrow.balanceOf(alice), 0.9 ether + 0.1 ether);
        assertEq(address(curve).balance, 10 ether - 1 ether, "protocol share stays behind");
    }

    function test_curve_sweepFees_byNonCreator_reverts() public {
        (, MockPonsCurve curve) = curveFixture();
        curve.setBalances(1 ether, 0);
        vm.prank(bob);
        vm.expectRevert(MockPonsCurve.NotFeeSweepOperator.selector);
        curve.sweepFees(0);
    }

    function test_curve_sweepFees_revertsWhenSwitched() public {
        (, MockPonsCurve curve) = curveFixture();
        curve.setBalances(1 ether, 0);
        curve.setSweepReverts(true);
        vm.prank(alice);
        vm.expectRevert(MockPonsCurve.SweepReverts.selector);
        curve.sweepFees(0);
        assertEq(curve.quoteFeeBalance(), 1 ether, "nothing moved");
    }

    // ---- MockPonsHook ----

    function hookFixture() internal returns (MockPonsEscrow escrow, MockPonsHook h) {
        escrow = new MockPonsEscrow();
        h = new MockPonsHook(escrow);
        vm.deal(address(h), 10 ether);
        h.register(POOL, nutz, alice);
    }

    function test_hook_pendingMappingsAreSettableByCurrency() public {
        (, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 1, 2, 3);
        h.setPending(POOL, nutz, 4, 5, 6);
        assertEq(h.pendingFees(POOL, ETH), 1);
        assertEq(h.pendingCreatorTax(POOL, ETH), 2);
        assertEq(h.pendingBuyback(POOL, ETH), 3);
        assertEq(h.pendingFees(POOL, nutz), 4);
        assertEq(h.pendingCreatorTax(POOL, nutz), 5);
        assertEq(h.pendingBuyback(POOL, nutz), 6);
    }

    function test_hook_sweepPoolFees_creditsEthFeesPlusTaxAndZeroes() public {
        (MockPonsEscrow escrow, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 0.3 ether, 0.1 ether, 0);
        vm.prank(alice);
        h.sweepPoolFees(POOL, 0, 0);
        assertEq(escrow.balanceOf(alice), 0.4 ether);
        assertEq(address(escrow).balance, 0.4 ether);
        assertEq(h.pendingFees(POOL, ETH), 0);
        assertEq(h.pendingCreatorTax(POOL, ETH), 0);
    }

    function test_hook_sweepPoolFees_protocolShareComesOffFeesNotTax() public {
        (MockPonsEscrow escrow, MockPonsHook h) = hookFixture();
        h.setProtocolFeeShareBps(1_000);
        h.setPending(POOL, ETH, 1 ether, 0.1 ether, 0);
        vm.prank(alice);
        h.sweepPoolFees(POOL, 0, 0);
        assertEq(escrow.balanceOf(alice), 0.9 ether + 0.1 ether);
    }

    function test_hook_sweepPoolFees_byNonCreator_reverts() public {
        (, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 1 ether, 0, 0);
        vm.prank(bob);
        vm.expectRevert(MockPonsHook.NotFeeSweepOperator.selector);
        h.sweepPoolFees(POOL, 0, 0);
    }

    function test_hook_sweepPoolFees_revertsWhenMemecoinFeesPending() public {
        (, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 1 ether, 0, 0);
        h.setPending(POOL, nutz, 1, 0, 0);
        vm.prank(alice);
        vm.expectRevert(MockPonsHook.InternalSwapRequiresOperator.selector);
        h.sweepPoolFees(POOL, 0, 0);
    }

    function test_hook_sweepPoolFees_revertsWhenMemecoinTaxPending() public {
        (, MockPonsHook h) = hookFixture();
        h.setPending(POOL, nutz, 0, 1, 0);
        vm.prank(alice);
        vm.expectRevert(MockPonsHook.InternalSwapRequiresOperator.selector);
        h.sweepPoolFees(POOL, 0, 0);
    }

    function test_hook_sweepPoolFees_revertsWhenEthBuybackPending() public {
        (, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 1 ether, 0, 1);
        vm.prank(alice);
        vm.expectRevert(MockPonsHook.InternalSwapRequiresOperator.selector);
        h.sweepPoolFees(POOL, 0, 0);
    }

    function test_hook_sweepPoolFees_memecoinBuybackAlone_doesNotGate() public {
        // The real gate reads memecoin fees and tax and the quote buyback, not the memecoin buyback earmark
        // (which cannot be non-zero on its own: it is a slice of pendingFees).
        (MockPonsEscrow escrow, MockPonsHook h) = hookFixture();
        h.setPending(POOL, ETH, 1 ether, 0, 0);
        h.setPending(POOL, nutz, 0, 0, 1);
        vm.prank(alice);
        h.sweepPoolFees(POOL, 0, 0);
        assertEq(escrow.balanceOf(alice), 1 ether);
    }

    function test_hook_sweepPoolFees_unknownPool_reverts() public {
        (, MockPonsHook h) = hookFixture();
        vm.prank(alice);
        vm.expectRevert(MockPonsHook.UnknownPool.selector);
        h.sweepPoolFees(keccak256("other"), 0, 0);
    }

    function test_hook_sweepPoolFees_nothingPending_isNoop() public {
        (MockPonsEscrow escrow, MockPonsHook h) = hookFixture();
        vm.prank(alice);
        h.sweepPoolFees(POOL, 0, 0);
        assertEq(escrow.balanceOf(alice), 0);
    }

    // ---- MockWETH ----

    function test_weth_depositAndWithdrawRoundTrip() public {
        MockWETH w = new MockWETH();
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        w.deposit{value: 2 ether}();
        assertEq(w.balanceOf(alice), 2 ether);
        assertEq(address(w).balance, 2 ether);

        vm.prank(alice);
        w.withdraw(0.5 ether);
        assertEq(w.balanceOf(alice), 1.5 ether);
        assertEq(alice.balance, 0.5 ether);
    }

    function test_weth_plainEthTransferDeposits() public {
        MockWETH w = new MockWETH();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(w).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(w.balanceOf(alice), 1 ether);
    }

    // ---- MockSwapRouter02 ----

    function routerFixture() internal {
        weth = new MockWETH();
        usdg = new MockERC20("USDG", "USDG");
        spy = new MockERC20("SPY", "SPY");
        router = new MockSwapRouter02(address(weth));
        usdg.mint(address(router), 1_000_000e6);
        spy.mint(address(router), 1_000e18);
        vm.deal(address(router), 100 ether);
        vm.prank(address(router));
        weth.deposit{value: 100 ether}();
    }

    function path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function exactIn(bytes memory p, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (ISwapRouter02.ExactInputParams memory)
    {
        return ISwapRouter02.ExactInputParams({path: p, recipient: alice, amountIn: amountIn, amountOutMinimum: minOut});
    }

    function test_router_weth9_isConstructorArg() public {
        routerFixture();
        assertEq(router.WETH9(), address(weth));
    }

    function test_router_erc20Input_swapsAtFixedRateAndRecordsAllowance() public {
        routerFixture();
        router.setRate(address(spy), 2e27); // 1e6 USDG -> 2e15 SPY (SPY at $500): rate = 2e15 * 1e18 / 1e6
        usdg.mint(alice, 100e6);
        vm.startPrank(alice);
        usdg.approve(address(router), 100e6);
        uint256 out = router.exactInput(exactIn(path(address(usdg), 500, address(spy)), 100e6, 0));
        vm.stopPrank();

        assertEq(out, 0.2e18);
        assertEq(spy.balanceOf(alice), 0.2e18);
        assertEq(usdg.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(address(router)), 1_000_000e6 + 100e6);
        assertEq(router.allowanceSeen(address(usdg)), 100e6);
    }

    function test_router_nativeInput_whenPathStartsWithWeth() public {
        routerFixture();
        router.setRate(address(usdg), 3_000e6); // 1 ETH -> 3000 USDG
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        uint256 out = router.exactInput{value: 2 ether}(exactIn(path(address(weth), 100, address(usdg)), 2 ether, 0));
        assertEq(out, 6_000e6);
        assertEq(usdg.balanceOf(alice), 6_000e6);
        assertEq(alice.balance, 0);
        assertEq(address(router).balance, 2 ether);
    }

    function test_router_nativeInput_valueMustEqualAmountIn() public {
        routerFixture();
        router.setRate(address(usdg), 3_000e6);
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(MockSwapRouter02.WrongValue.selector);
        router.exactInput{value: 1 ether}(exactIn(path(address(weth), 100, address(usdg)), 2 ether, 0));
    }

    function test_router_wethOutput_deliversWethNotEth() public {
        routerFixture();
        router.setRate(address(weth), 2.5e26); // 4000 USDG (4000e6) -> 1 ETH (1e18)
        usdg.mint(alice, 4_000e6);
        vm.startPrank(alice);
        usdg.approve(address(router), 4_000e6);
        uint256 out = router.exactInput(exactIn(path(address(usdg), 100, address(weth)), 4_000e6, 0));
        vm.stopPrank();
        assertEq(out, 1 ether);
        assertEq(weth.balanceOf(alice), 1 ether, "WETH, not unwrapped");
        assertEq(alice.balance, 0);
    }

    function test_router_multiHopPath_usesFirstAndLastToken() public {
        routerFixture();
        router.setRate(address(spy), 2e27);
        usdg.mint(alice, 100e6);
        bytes memory p = abi.encodePacked(address(usdg), uint24(100), address(weth), uint24(3000), address(spy));
        vm.startPrank(alice);
        usdg.approve(address(router), 100e6);
        uint256 out = router.exactInput(exactIn(p, 100e6, 0));
        vm.stopPrank();
        assertEq(out, 0.2e18);
        assertEq(spy.balanceOf(alice), 0.2e18);
    }

    function test_router_belowMinimum_reverts() public {
        routerFixture();
        router.setRate(address(usdg), 3_000e6);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Too little received"));
        router.exactInput{value: 1 ether}(exactIn(path(address(weth), 100, address(usdg)), 1 ether, 3_001e6));
    }

    function test_router_perTokenRevertSwitch() public {
        routerFixture();
        router.setRate(address(usdg), 3_000e6);
        router.setReverts(address(usdg), true);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(usdg)));
        router.exactInput{value: 1 ether}(exactIn(path(address(weth), 100, address(usdg)), 1 ether, 0));
    }

    function test_router_unpricedOutput_reverts() public {
        routerFixture();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSwapRouter02.NoRate.selector, address(usdg)));
        router.exactInput{value: 1 ether}(exactIn(path(address(weth), 100, address(usdg)), 1 ether, 0));
    }

    // ---- MockPoolManager ----

    function poolFixture() internal {
        pm = new MockPoolManager();
        locker = new Locker(pm);
        nutzToken = new MockERC20("NUTZ", "NUTZ");
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(nutzToken)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(v4Hooks)
        });
        nutzToken.mint(address(pm), 1_000_000e18);
        vm.deal(address(pm), 100 ether);
    }

    /// @dev An exact-input plan with the extreme price bound on the swap's side, as the Converter will send.
    function plan(bool zeroForOne, uint256 amountIn) internal view returns (Locker.Plan memory) {
        return Locker.Plan({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            settleInput: true,
            takeOutput: true
        });
    }

    function test_pool_ethForToken_atFixedRate_settlesAndTakes() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18); // 1 ETH -> 1,000,000 NUTZ
        vm.deal(address(locker), 1 ether);

        BalanceDelta d = locker.run(plan(true, 1 ether));

        assertEq(d.amount0(), -1 ether);
        assertEq(d.amount1(), 1_000_000e18);
        assertEq(nutzToken.balanceOf(address(locker)), 1_000_000e18);
        assertEq(address(locker).balance, 0);
        assertEq(address(pm).balance, 101 ether);
        assertEq(nutzToken.balanceOf(address(pm)), 0);
    }

    function test_pool_tokenForEth_atFixedRate_settlesAndTakes() public {
        poolFixture();
        pm.setRate(key, false, 1e12); // 1e18 NUTZ -> 1e12 wei, so 1,000,000 NUTZ -> 1 ETH
        nutzToken.mint(address(locker), 1_000_000e18);

        BalanceDelta d = locker.run(plan(false, 1_000_000e18));

        assertEq(d.amount0(), 1 ether);
        assertEq(d.amount1(), -1_000_000e18);
        assertEq(address(locker).balance, 1 ether);
        assertEq(nutzToken.balanceOf(address(locker)), 0);
        assertEq(nutzToken.balanceOf(address(pm)), 2_000_000e18);
        assertEq(address(pm).balance, 99 ether);
    }

    function test_pool_unsettledInput_revertsCurrencyNotSettled() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        vm.deal(address(locker), 1 ether);
        Locker.Plan memory p = plan(true, 1 ether);
        p.settleInput = false;
        vm.expectRevert(MockPoolManager.CurrencyNotSettled.selector);
        locker.run(p);
    }

    function test_pool_untakenOutput_revertsCurrencyNotSettled() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        vm.deal(address(locker), 1 ether);
        Locker.Plan memory p = plan(true, 1 ether);
        p.takeOutput = false;
        vm.expectRevert(MockPoolManager.CurrencyNotSettled.selector);
        locker.run(p);
    }

    function test_pool_swapOutsideUnlock_revertsManagerLocked() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        vm.expectRevert(MockPoolManager.ManagerLocked.selector);
        pm.swap(key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), "");
    }

    function test_pool_perKeyRevertSwitch() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        pm.setReverts(key, true);
        vm.deal(address(locker), 1 ether);
        vm.expectRevert(MockPoolManager.PoolReverts.selector);
        locker.run(plan(true, 1 ether));
    }

    function test_pool_unpricedKey_revertsPoolNotInitialized() public {
        poolFixture();
        vm.deal(address(locker), 1 ether);
        vm.expectRevert(MockPoolManager.PoolNotInitialized.selector);
        locker.run(plan(true, 1 ether));
    }

    function test_pool_zeroPriceLimit_revertsOutOfBounds() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        pm.setRate(key, false, 1e12);
        vm.deal(address(locker), 1 ether);
        nutzToken.mint(address(locker), 1e18);
        for (uint256 i = 0; i < 2; i++) {
            Locker.Plan memory p = plan(i == 0, i == 0 ? 1 ether : 1e18);
            p.sqrtPriceLimitX96 = 0;
            vm.expectRevert(abi.encodeWithSelector(MockPoolManager.PriceLimitOutOfBounds.selector, uint160(0)));
            locker.run(p);
        }
    }

    function test_pool_priceLimitBeyondExtreme_revertsOutOfBounds() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        vm.deal(address(locker), 1 ether);
        Locker.Plan memory p = plan(true, 1 ether);
        p.sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE; // must be strictly above the minimum when selling currency0
        vm.expectRevert(abi.encodeWithSelector(MockPoolManager.PriceLimitOutOfBounds.selector, TickMath.MIN_SQRT_PRICE));
        locker.run(p);
    }

    function test_pool_exactOutput_unsupported() public {
        poolFixture();
        pm.setRate(key, true, 1_000_000e18);
        Locker.Plan memory p = plan(true, 1 ether);
        p.amountSpecified = 1;
        vm.expectRevert(MockPoolManager.ExactOutputUnsupported.selector);
        locker.run(p);
    }
}
