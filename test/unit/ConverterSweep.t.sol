// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";
import {IPonsV2FeeEscrow} from "../../src/interfaces/pons/IPonsV2FeeEscrow.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {IPonsV2BondingCurve} from "../../src/interfaces/pons/IPonsV2BondingCurve.sol";
import {IPonsV2MemeHook} from "../../src/interfaces/pons/IPonsV2MemeHook.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The hourly Sweep end to end against the mock Venues and Pons contracts.
///      Router rates: 1 ETH -> 3,000 USDG; SPY $500, NVDA $100, MU $250, SPCX $10 (all 18 decimals).
///      Worked example (spec §6) for 1 ETH swept with an empty Keeper wallet and a 0.5 ETH ops cap:
///      Ops 0.02 ETH; 0.98 ETH -> 2,940 USDG; Stash 1,800 (450 per stock), Cash 840, Acorn 300;
///      450 USDG buys 0.9 SPY, 4.5 NVDA, 1.8 MU, 45 SPCX.
contract ConverterSweepTest is ConverterBase {
    uint256 internal constant ETH_USDG = 3_000e6;
    uint256[4] internal STOCK_RATES = [uint256(2e27), 1e28, 4e27, 1e29];

    address internal constant ETH = address(0);

    uint256 internal constant NUTZ_ETH = 1e12; // 1e18 NUTZ -> 1e12 wei

    MockERC20 internal usdg;
    uint256 internal epoch;

    // The bound NUTZ launch, set up by `bindNutz()` for the Fee pull and NUTZ sale tests.
    MockERC20 internal nutzToken;
    MockPonsCurve internal curve;
    IPonsV2LaunchFactory.LaunchedToken internal L;

    function setUp() public override {
        super.setUp();
        usdg = tok[4];
        epoch = d.currentEpoch();

        usdg.mint(address(router), 100_000_000e6);
        router.setRate(address(usdg), ETH_USDG);
        for (uint256 i = 0; i < 4; i++) {
            tok[i].mint(address(router), 1_000_000e18);
            router.setRate(address(tok[i]), STOCK_RATES[i]);
        }
    }

    // ---- fixtures ----

    function sweep(uint256 epochId, NutzConverter.Route[6] memory r) internal {
        vm.prank(keeper);
        c.sweep(epochId, r, block.timestamp);
    }

    /// @dev A Keeper sweep expected to revert with `err`.
    function sweepReverting(uint256 epochId, NutzConverter.Route[6] memory r, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        c.sweep(epochId, r, block.timestamp);
    }

    /// @dev Sweeps and returns the `ethIn` the `Swept` event reported.
    function sweepReadingEthIn(NutzConverter.Route[6] memory r) internal returns (uint256 ethIn) {
        vm.recordLogs();
        sweep(epoch, r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(c) && logs[i].topics[0] == NutzConverter.Swept.selector) {
                (ethIn,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256[5], uint256));
                return ethIn;
            }
        }
        revert("Swept not emitted");
    }

    function funded(uint256 epochId) internal view returns (uint256[5] memory) {
        return d.ledger(NutzDistributor.Kind.Epoch, epochId).funded;
    }

    // ---- happy path ----

    function test_sweep_fundsDistributorAndLeavesConverterEmpty() public {
        vm.deal(address(c), 1 ether);
        uint256[5] memory expected = [uint256(0.9e18), 4.5e18, 1.8e18, 45e18, 840e6];
        for (uint256 i = 0; i < 5; i++) {
            uint256 approved = expected[i] + (i == 4 ? 300e6 : 0);
            vm.expectCall(address(tok[i]), abi.encodeCall(IERC20.approve, (address(d), approved)));
            vm.expectCall(address(tok[i]), abi.encodeCall(IERC20.approve, (address(d), 0)));
        }

        vm.expectEmit(address(c));
        emit NutzConverter.OpsFunded(0.02 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.Swept(epoch, 1 ether, 0.02 ether, expected, 300e6);
        sweep(epoch, sweepRoutes());

        uint256[5] memory f = funded(epoch);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(f[i], expected[i], "funded amount");
            assertEq(tok[i].balanceOf(address(d)), expected[i] + (i == 4 ? 300e6 : 0), "distributor holds it");
        }
        assertEq(d.acornPoolUsdg(), 300e6);
        assertEq(keeper.balance, 0.02 ether);
        assertEq(address(c).balance, 0);
        assertConverterEmpty();
    }

    function test_sweep_aboveCap_leavesExcessForNextHour() public {
        vm.deal(address(c), 25 ether);
        assertEq(sweepReadingEthIn(sweepRoutes()), 20 ether, "capped");
        assertEq(address(c).balance, 5 ether, "excess waits");
        assertEq(keeper.balance, 0.4 ether, "2% of 20 ETH, under the 0.5 ETH cap");
        // 19.6 ETH -> 58,800 USDG: Stash 36,000 (9,000 per stock), Cash 16,800, Acorn 6,000.
        assertEq(funded(epoch)[4], 16_800e6);
        assertEq(d.acornPoolUsdg(), 6_000e6);
        assertEq(tok[0].balanceOf(address(d)), 18e18, "9,000 USDG of SPY at $500");
        assertConverterEmpty();
    }

    function test_sweep_zeroBalance_revertsNothingToSweep() public {
        vm.expectRevert(NutzConverter.NothingToSweep.selector);
        sweep(epoch, sweepRoutes());
    }

    // ---- ops ----

    function test_ops_cappedByKeeperHeadroom() public {
        vm.deal(address(c), 1 ether);
        vm.deal(keeper, 0.49 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.OpsFunded(0.01 ether);
        sweep(epoch, sweepRoutes());
        assertEq(keeper.balance, 0.5 ether, "topped up to the cap, not beyond");
        // 0.99 ETH -> 2,970 USDG: Cash 848.571428, Acorn 2,970 - 1,818.367346 - 848.571428 = 303.061226.
        assertEq(funded(epoch)[4], 848_571430, "cash plus two units of stash dust");
        assertEq(d.acornPoolUsdg(), 303_061226);
    }

    function test_ops_zeroWhenKeeperAtCap_overflowReachesHolders() public {
        vm.deal(address(c), 1 ether);
        vm.deal(keeper, 0.5 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.OpsFunded(0);
        sweep(epoch, sweepRoutes());
        assertEq(keeper.balance, 0.5 ether, "nothing sent");
        // The whole 1 ETH -> 3,000 USDG: Stash 1,836.734693 (459.183673 per stock), Cash 857.142857, Acorn 306.122450.
        assertEq(funded(epoch)[4], 857_142858, "cash plus one unit of stash dust");
        assertEq(d.acornPoolUsdg(), 306_122450);
        assertEq(tok[1].balanceOf(address(d)), 4.59183673e18, "459.183673 USDG of NVDA at $100");
    }

    function test_ops_zeroWhenCapIsZero() public {
        setOpsCap(0);
        vm.deal(address(c), 1 ether);
        sweep(epoch, sweepRoutes());
        assertEq(keeper.balance, 0);
        assertEq(d.acornPoolUsdg(), 306_122450);
    }

    function test_ops_keeperRefusingEth_revertsTheSweep() public {
        vm.deal(address(c), 1 ether);
        vm.etch(keeper, hex"60006000fd"); // a wallet that reverts on any call
        sweepReverting(epoch, sweepRoutes(), abi.encodePacked(NutzConverter.OpsTransferFailed.selector));
    }

    // ---- ETH -> USDG, the Leg that aborts the Sweep ----

    function test_ethToUsdgFailure_revertsEverythingIncludingOps() public {
        vm.deal(address(c), 1 ether);
        router.setReverts(address(usdg), true);
        sweepReverting(
            epoch, sweepRoutes(), abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(usdg))
        );
        assertEq(address(c).balance, 1 ether, "ETH intact");
        assertEq(keeper.balance, 0, "Ops reverted too");
    }

    function test_ethToUsdgBelowDistributorFloor_reverts() public {
        vm.deal(address(c), 1 ether);
        router.setRate(address(usdg), 999e6); // the Distributor's minimum is 1,000 USDG per ETH
        // 0.98 ETH goes to the Leg after Ops: 979.02 USDG out against a floor of 980 USDG.
        sweepReverting(
            epoch, sweepRoutes(), abi.encodeWithSelector(NutzConverter.UsdgBelowFloor.selector, 979_020000, 980_000000)
        );
        assertEq(address(c).balance, 1 ether);
    }

    function test_ethToUsdgAtFloor_passes() public {
        vm.deal(address(c), 1 ether);
        router.setRate(address(usdg), 1_000e6);
        sweep(epoch, sweepRoutes());
        assertEq(d.acornPoolUsdg(), 100e6);
    }

    // ---- guards ----

    function test_nonKeeper_reverts() public {
        vm.deal(address(c), 1 ether);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(Signers.NotKeeper.selector);
        c.sweep(epoch, sweepRoutes(), block.timestamp);
    }

    function test_expiredDeadline_reverts() public {
        vm.deal(address(c), 1 ether);
        vm.prank(keeper);
        vm.expectRevert(NutzConverter.DeadlinePassed.selector);
        c.sweep(epoch, sweepRoutes(), block.timestamp - 1);
    }

    function test_distributorRejectsEpoch_revertsWithBalancesIntact() public {
        vm.deal(address(c), 1 ether);
        sweepReverting(
            epoch + 1, sweepRoutes(), abi.encodeWithSelector(NutzDistributor.PeriodNotOpen.selector, epoch + 1)
        );
        assertEq(address(c).balance, 1 ether);
        assertEq(keeper.balance, 0);
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    // ---- stock Legs: isolated and breakable ----

    function test_stockLegFailing_becomesCashWithReason() public {
        for (uint256 i = 0; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            vm.deal(address(c), 1 ether);
            router.setReverts(address(tok[i]), true);
            vm.expectEmit(address(c));
            emit NutzConverter.LegSkipped(
                uint8(2 + i), abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(tok[i]))
            );
            sweep(epoch, sweepRoutes());
            uint256[5] memory f = funded(epoch);
            assertEq(f[i], 0, "no stock bought");
            assertEq(f[4], 840e6 + 450e6, "its share paid as Cash");
            assertEq(d.acornPoolUsdg(), 300e6, "Acorn unaffected");
            assertConverterEmpty();
            vm.revertToState(snap);
        }
    }

    function test_disabledLeg_becomesCashWithoutVenueCall() public {
        disableLeg(2);
        vm.deal(address(c), 1 ether);
        vm.expectCall(address(router), abi.encodeWithSelector(ISwapRouter02.exactInput.selector), 4);
        vm.expectEmit(address(c));
        emit NutzConverter.LegSkipped(4, "disabled");
        sweep(epoch, sweepRoutes());
        uint256[5] memory f = funded(epoch);
        assertEq(f[2], 0);
        assertEq(f[3], 45e18, "the next Leg still runs");
        assertEq(f[4], 840e6 + 450e6);
    }

    function test_allStockLegsFailing_fundsUsdgOnly() public {
        vm.deal(address(c), 1 ether);
        for (uint256 i = 0; i < 4; i++) {
            router.setReverts(address(tok[i]), true);
        }
        uint256[5] memory expected = [uint256(0), 0, 0, 0, 840e6 + 1_800e6];
        vm.expectEmit(address(c));
        emit NutzConverter.Swept(epoch, 1 ether, 0.02 ether, expected, 300e6);
        sweep(epoch, sweepRoutes());
        assertEq(funded(epoch)[4], 2_640e6);
        assertConverterEmpty();
    }

    // ---- Fee pull ----

    /// @dev Launches and binds NUTZ, leaving the record in `L` for tests that move it through the phases.
    function bindNutz() internal {
        nutzToken = new MockERC20("NUTZ", "NUTZ");
        curve = launch(address(nutzToken));
        L = launchRecord(address(nutzToken), address(curve));
        vm.prank(keeper);
        c.bindNutz(address(nutzToken));
    }

    function setPhase(uint8 phase) internal {
        L.phase = phase;
        factory.setLaunchedToken(address(nutzToken), L);
    }

    /// @dev The NUTZ pool's id as v4 derives it from the launch record and the Pons hook.
    function nutzPoolId() internal view returns (bytes32) {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(ETH),
            currency1: Currency.wrap(address(nutzToken)),
            fee: L.poolFee,
            tickSpacing: L.tickSpacing,
            hooks: IHooks(address(hook))
        });
        return PoolId.unwrap(k.toId());
    }

    function expectNoCurveSweep() internal {
        vm.expectCall(address(curve), abi.encodeWithSelector(IPonsV2BondingCurve.sweepFees.selector), 0);
    }

    function expectNoHookSweep() internal {
        vm.expectCall(address(hook), abi.encodeWithSelector(IPonsV2MemeHook.sweepPoolFees.selector), 0);
    }

    function test_unbound_makesNoPonsCalls() public {
        vm.deal(address(c), 1 ether);
        vm.expectCall(address(factory), abi.encodeWithSelector(IPonsV2LaunchFactory.getLaunchedToken.selector), 0);
        vm.expectCall(address(escrow), abi.encodeWithSelector(IPonsV2FeeEscrow.balanceOf.selector), 0);
        sweep(epoch, sweepRoutes());
    }

    function test_phase0_sweepsCurveWhenFeesPending_andClaims() public {
        bindNutz();
        curve.setBalances(0.1 ether, 0.01 ether);
        vm.deal(address(curve), 0.11 ether);
        vm.deal(address(c), 1 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(true, false, 0.11 ether);
        assertEq(sweepReadingEthIn(sweepRoutes()), 1.11 ether, "claimed ETH joins the Sweep");
        assertEq(address(c).balance, 0);
        assertEq(escrow.balanceOf(address(c)), 0);
    }

    function test_phase0_skipsCurveWhenNothingPending() public {
        bindNutz();
        vm.deal(address(c), 1 ether);
        expectNoCurveSweep();
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, false, 0);
        sweep(epoch, sweepRoutes());
    }

    function test_phase0_curveRevertIsSwallowed() public {
        bindNutz();
        curve.setBalances(0.1 ether, 0);
        curve.setSweepReverts(true);
        vm.deal(address(c), 1 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, false, 0);
        sweep(epoch, sweepRoutes());
        assertEq(address(c).balance, 0, "the Sweep went on with what it had");
    }

    function test_phase2_sweepsHookWhenOnlyEthPending() public {
        bindNutz();
        setPhase(2);
        bytes32 id = nutzPoolId();
        hook.register(id, address(nutzToken), address(c));
        hook.setPending(id, ETH, 0.2 ether, 0.05 ether, 0);
        vm.deal(address(hook), 0.25 ether);
        vm.deal(address(c), 1 ether);
        expectNoCurveSweep();
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, true, 0.25 ether);
        assertEq(sweepReadingEthIn(sweepRoutes()), 1.25 ether, "hook fees join the Sweep");
    }

    /// @dev Phase 2 with 0.2 ETH of fees pending plus one amount the creator is not allowed to sweep past; the
    ///      hook must not be called at all (the gate is on the views, not on a caught revert).
    function assertHookNotSwept(uint256 nutzFees, uint256 nutzTax, uint256 nutzBuyback, uint256 ethBuyback) internal {
        bindNutz();
        setPhase(2);
        bytes32 id = nutzPoolId();
        hook.register(id, address(nutzToken), address(c));
        vm.deal(address(hook), 1 ether);
        hook.setPending(id, ETH, 0.2 ether, 0, ethBuyback);
        hook.setPending(id, address(nutzToken), nutzFees, nutzTax, nutzBuyback);
        vm.deal(address(c), 1 ether);
        expectNoHookSweep();
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, false, 0);
        sweep(epoch, sweepRoutes());
        assertEq(hook.pendingFees(id, ETH), 0.2 ether, "nothing swept");
    }

    function test_phase2_skipsHookWhenNutzFeesPending() public {
        assertHookNotSwept(1, 0, 0, 0);
    }

    function test_phase2_skipsHookWhenNutzTaxPending() public {
        assertHookNotSwept(0, 1, 0, 0);
    }

    function test_phase2_skipsHookWhenNutzBuybackPending() public {
        assertHookNotSwept(0, 0, 1, 0);
    }

    function test_phase2_skipsHookWhenEthBuybackPending() public {
        assertHookNotSwept(0, 0, 0, 1);
    }

    function test_phase2_skipsHookWhenNoEthPending() public {
        bindNutz();
        setPhase(2);
        bytes32 id = nutzPoolId();
        hook.register(id, address(nutzToken), address(c));
        vm.deal(address(c), 1 ether);
        expectNoHookSweep();
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, false, 0);
        sweep(epoch, sweepRoutes());
    }

    function test_phases1and3_pullNothing() public {
        bindNutz();
        bytes32 id = nutzPoolId();
        hook.register(id, address(nutzToken), address(c));
        hook.setPending(id, ETH, 0.2 ether, 0, 0);
        vm.deal(address(hook), 1 ether);
        curve.setBalances(0.1 ether, 0);
        vm.deal(address(curve), 1 ether);
        uint8[2] memory phases = [1, 3];
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            setPhase(phases[i]);
            vm.deal(address(c), 1 ether);
            vm.expectEmit(address(c));
            emit NutzConverter.FeesPulled(false, false, 0);
            sweep(epoch, sweepRoutes());
            assertEq(curve.quoteFeeBalance(), 0.1 ether, "curve untouched");
            assertEq(hook.pendingFees(id, ETH), 0.2 ether, "hook untouched");
            assertEq(escrow.balanceOf(address(c)), 0, "nothing credited");
            vm.revertToState(snap);
        }
    }

    function test_escrowClaim_skippedWhenNothingClaimable() public {
        bindNutz();
        vm.deal(address(c), 1 ether);
        vm.expectCall(address(escrow), abi.encodeWithSelector(IPonsV2FeeEscrow.claim.selector), 0);
        sweep(epoch, sweepRoutes());
    }

    function test_escrowClaimRevert_isSwallowed() public {
        bindNutz();
        escrow.credit{value: 0.3 ether}(address(c));
        vm.mockCallRevert(address(escrow), abi.encodeWithSelector(IPonsV2FeeEscrow.claim.selector), "escrow down");
        vm.deal(address(c), 1 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.FeesPulled(false, false, 0);
        assertEq(sweepReadingEthIn(sweepRoutes()), 1 ether, "the Sweep went on without the claim");
        assertEq(escrow.balanceOf(address(c)), 0.3 ether, "still claimable next hour");
    }

    // ---- NUTZ sale ----

    function nutzRoutes() internal view returns (NutzConverter.Route[6] memory r) {
        r = sweepRoutes();
        r[0] = v3(address(nutzToken), address(weth));
    }

    function seedNutzSale() internal {
        bindNutz();
        nutzToken.mint(address(c), 4_000e18);
        router.setRate(address(weth), NUTZ_ETH);
        vm.deal(address(router), 10 ether);
        vm.prank(address(router));
        weth.deposit{value: 10 ether}();
    }

    function test_nutzSale_addsEthToTheSweep() public {
        seedNutzSale();
        vm.deal(address(c), 1 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.NutzSold(4_000e18, 0.004 ether);
        assertEq(sweepReadingEthIn(nutzRoutes()), 1.004 ether, "sale proceeds join the Sweep");
        assertEq(nutzToken.balanceOf(address(c)), 0);
        assertEq(weth.balanceOf(address(c)), 0);
        assertEq(address(c).balance, 0);
    }

    function test_nutzSaleFailure_keepsNutzForNextHour() public {
        seedNutzSale();
        router.setReverts(address(weth), true);
        vm.deal(address(c), 1 ether);
        vm.expectEmit(address(c));
        emit NutzConverter.LegSkipped(0, abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(weth)));
        assertEq(sweepReadingEthIn(nutzRoutes()), 1 ether, "the Sweep went on without the sale");
        assertEq(nutzToken.balanceOf(address(c)), 4_000e18);
        assertEq(nutzToken.allowance(address(c), address(router)), 0);
    }

    function test_noNutzHeld_skipsTheSale() public {
        bindNutz();
        vm.deal(address(c), 1 ether);
        vm.expectCall(address(router), abi.encodeWithSelector(ISwapRouter02.exactInput.selector), 5);
        sweep(epoch, sweepRoutes());
    }

    // ---- fuzz: every unit of USDG is swapped or funded; Ops never exceeds its share or the cap ----

    function testFuzz_slices_areExact(uint256 ethIn, uint256 keeperBal, uint256 cap, uint256 rate, uint8 failMask)
        public
    {
        ethIn = bound(ethIn, 1, 30 ether);
        keeperBal = bound(keeperBal, 0, 1 ether);
        cap = bound(cap, 0, 5 ether);
        rate = bound(rate, 1_000e6, 10_000e6); // the Distributor's rate range
        router.setRate(address(usdg), rate);
        setOpsCap(cap);
        vm.deal(address(c), ethIn);
        vm.deal(keeper, keeperBal);
        for (uint256 i = 0; i < 4; i++) {
            router.setReverts(address(tok[i]), failMask & (1 << i) != 0);
        }
        uint256 routerUsdgBefore = usdg.balanceOf(address(router));

        sweep(epoch, sweepRoutes());

        uint256 swept = ethIn > 20 ether ? 20 ether : ethIn;
        assertEq(address(c).balance, ethIn - swept, "exactly B left the Converter");
        uint256 opsAmt = keeper.balance - keeperBal;
        assertLe(opsAmt, swept * 200 / 10_000, "Ops at most 2%");
        if (opsAmt > 0) assertLe(keeper.balance, cap, "Ops never overfills the Keeper");
        uint256 usdgOut = (swept - opsAmt) * rate / 1e18; // what the mock router pays
        uint256 spent = usdg.balanceOf(address(router)) + usdgOut - routerUsdgBefore;
        assertEq(usdg.balanceOf(address(d)), usdgOut - spent, "cash + acorn + spent == usdgOut");
        assertEq(funded(epoch)[4] + d.acornPoolUsdg(), usdg.balanceOf(address(d)));
        assertConverterEmpty();
    }
}
