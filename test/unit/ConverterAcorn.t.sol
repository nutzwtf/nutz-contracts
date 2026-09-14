// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {Signers} from "../../src/Signers.sol";

/// @dev The weekly Acorn conversion end to end: one Sweep fills the Acorn pool, the Acorn Draw closes, the Draw
///      mock reports its seed, and the Keeper converts the pool through the mock router.
///      Router rates: 1 ETH -> 3,000 USDG; SPY $500, NVDA $100, MU $250, SPCX $10 (all 18 decimals).
///      Worked example (spec §7): 1 ETH swept puts 300 USDG in the pool; 75 USDG per stock buys
///      0.15 SPY, 0.75 NVDA, 0.3 MU, 7.5 SPCX.
contract ConverterAcornTest is ConverterBase {
    uint256 internal constant ETH_USDG = 3_000e6;
    uint256[4] internal STOCK_RATES = [uint256(2e27), 1e28, 4e27, 1e29];
    bytes32 internal constant SEED = keccak256("seed");

    MockERC20 internal usdg;
    MockNutzDraw internal draw;
    /// @dev The Acorn Draw the Sweep's Acorn Slice lands in.
    uint256 internal drawId;

    function setUp() public override {
        super.setUp();
        usdg = tok[4];
        usdg.mint(address(router), 100_000_000e6);
        router.setRate(address(usdg), ETH_USDG);
        for (uint256 i = 0; i < 4; i++) {
            tok[i].mint(address(router), 1_000_000e18);
            router.setRate(address(tok[i]), STOCK_RATES[i]);
        }
        draw = new MockNutzDraw();
        installDrawContract(address(draw));
        drawId = d.currentDraw();
    }

    // ---- fixtures ----

    /// @dev Valid single-hop v3 Routes for the four stock Legs.
    function routes() internal view returns (NutzConverter.Route[4] memory r) {
        for (uint256 i = 0; i < 4; i++) {
            r[i] = v3(address(usdg), address(tok[i]));
        }
    }

    /// @dev Advances time so that Acorn Draw `id` has just closed.
    function closeDraw(uint256 id) internal {
        vm.warp((id + 1) * d.WEEK());
    }

    /// @dev Sweeps `ethIn` in the current Epoch so its Acorn Slice lands in the pool, then closes `drawId`
    ///      and reports its seed, leaving the pool ready to convert.
    function accumulateAcorn(uint256 ethIn) internal {
        vm.deal(address(c), ethIn);
        uint256 epoch = d.currentEpoch();
        vm.prank(keeper);
        c.sweep(epoch, sweepRoutes(), block.timestamp);
        closeDraw(drawId);
        draw.setSeed(drawId, SEED);
    }

    function convert(uint256 id, NutzConverter.Route[4] memory r) internal {
        vm.prank(keeper);
        c.convertAcorn(id, r, block.timestamp);
    }

    function convertReverting(uint256 id, NutzConverter.Route[4] memory r, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        c.convertAcorn(id, r, block.timestamp);
    }

    function drawFunded(uint256 id) internal view returns (uint256[5] memory) {
        return d.ledger(NutzDistributor.Kind.Draw, id).funded;
    }

    /// @dev Expects the exact grant and the zeroing approval of `amount` of `token` to the Distributor.
    function expectExactApproval(MockERC20 token, uint256 amount) internal {
        vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(d), amount)));
        vm.expectCall(address(token), abi.encodeCall(IERC20.approve, (address(d), 0)));
    }

    // ---- happy path ----

    function test_convertAcorn_fundsDrawLedgerAndLeavesConverterEmpty() public {
        accumulateAcorn(1 ether);
        assertEq(d.acornPoolUsdg(), 300e6, "the Sweep's Acorn Slice");
        uint256[5] memory expected = [uint256(0.15e18), 0.75e18, 0.3e18, 7.5e18, 0];
        for (uint256 i = 0; i < 4; i++) {
            expectExactApproval(tok[i], expected[i]);
        }
        // Nothing to fund as USDG, so the Distributor gets no USDG approval at all, not even a zeroing one.
        vm.expectCall(address(usdg), abi.encodeCall(IERC20.approve, (address(d), 0)), 0);

        uint256[4] memory held;
        for (uint256 i = 0; i < 4; i++) {
            held[i] = tok[i].balanceOf(address(d));
        }

        vm.expectEmit(address(c));
        emit NutzConverter.AcornConverted(drawId, 300e6, expected);
        convert(drawId, routes());

        uint256[5] memory f = drawFunded(drawId);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(f[i], expected[i], "draw ledger funded");
        }
        for (uint256 i = 0; i < 4; i++) {
            assertEq(tok[i].balanceOf(address(d)) - held[i], expected[i], "distributor received the stock");
        }
        assertEq(usdg.balanceOf(address(d)), 840e6, "only the Epoch's Cash Slice remains");
        assertEq(d.acornPoolUsdg(), 0);
        assertTrue(d.drawConverted(drawId));
        assertConverterEmpty();
    }

    function test_quarteringDust_staysUsdg() public {
        // 0.98 ETH at 3,000.000005 USDG/ETH -> 2,940.000004 USDG; Acorn 300.000001, so 75 USDG per stock and
        // one unit of USDG that no Leg gets.
        router.setRate(address(usdg), 3_000_000_005);
        accumulateAcorn(1 ether);
        assertEq(d.acornPoolUsdg(), 300_000_001);
        expectExactApproval(usdg, 1);
        vm.expectEmit(address(c));
        emit NutzConverter.AcornConverted(drawId, 300_000_001, [uint256(0.15e18), 0.75e18, 0.3e18, 7.5e18, 1]);
        convert(drawId, routes());
        assertEq(drawFunded(drawId)[4], 1, "the dust is funded as USDG");
        assertConverterEmpty();
    }

    // ---- stock Legs: isolated and breakable ----

    function test_stockLegFailing_staysUsdgWithReason() public {
        for (uint256 i = 0; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            accumulateAcorn(1 ether);
            router.setReverts(address(tok[i]), true);
            vm.expectEmit(address(c));
            emit NutzConverter.LegSkipped(
                uint8(2 + i), abi.encodeWithSelector(MockSwapRouter02.VenueReverts.selector, address(tok[i]))
            );
            convert(drawId, routes());
            uint256[5] memory f = drawFunded(drawId);
            assertEq(f[i], 0, "no stock bought");
            assertEq(f[4], 75e6, "its share funded as USDG");
            assertEq(usdg.allowance(address(c), address(router)), 0, "router approval taken back");
            assertConverterEmpty();
            vm.revertToState(snap);
        }
    }

    function test_disabledLeg_staysUsdgWithoutVenueCall() public {
        accumulateAcorn(1 ether);
        disableLeg(1);
        vm.expectCall(address(router), abi.encodeWithSelector(ISwapRouter02.exactInput.selector), 3);
        vm.expectEmit(address(c));
        emit NutzConverter.LegSkipped(3, "disabled");
        convert(drawId, routes());
        uint256[5] memory f = drawFunded(drawId);
        assertEq(f[1], 0);
        assertEq(f[2], 0.3e18, "the next Leg still runs");
        assertEq(f[4], 75e6);
        assertConverterEmpty();
    }

    function test_allStockLegsFailing_fundsUsdgOnly() public {
        accumulateAcorn(1 ether);
        for (uint256 i = 0; i < 4; i++) {
            router.setReverts(address(tok[i]), true);
        }
        expectExactApproval(usdg, 300e6);
        vm.expectEmit(address(c));
        emit NutzConverter.AcornConverted(drawId, 300e6, [uint256(0), 0, 0, 0, 300e6]);
        convert(drawId, routes());
        assertEq(drawFunded(drawId)[4], 300e6);
        assertEq(usdg.balanceOf(address(d)), 840e6 + 300e6, "the pool came back as USDG");
        assertConverterEmpty();
    }

    // ---- the Distributor decides what is convertible; its rejections bubble ----

    function test_secondCallForTheSameDraw_reverts() public {
        accumulateAcorn(1 ether);
        convert(drawId, routes());
        convertReverting(drawId, routes(), abi.encodeWithSelector(NutzDistributor.AlreadyConverted.selector, drawId));
    }

    function test_noSeed_reverts() public {
        accumulateAcorn(1 ether);
        uint256 next = drawId + 1;
        closeDraw(next);
        convertReverting(next, routes(), abi.encodeWithSelector(NutzDistributor.DrawNotFulfilled.selector, next));
        assertEq(d.acornPoolUsdg(), 300e6, "the pool waits");
    }

    function test_emptyPool_reverts() public {
        draw.setSeed(drawId, SEED);
        convertReverting(drawId, routes(), abi.encodePacked(NutzDistributor.NothingToConvert.selector));
    }

    function test_drawNotOpen_reverts() public {
        accumulateAcorn(1 ether);
        uint256 future = d.currentDraw() + 1;
        draw.setSeed(future, SEED);
        convertReverting(future, routes(), abi.encodeWithSelector(NutzDistributor.PeriodNotOpen.selector, future));
    }

    /// @dev A malformed Route is a Keeper bug (spec §5): the whole call reverts, so the pull is undone too.
    function test_badRoute_revertsTheWholeCall() public {
        accumulateAcorn(1 ether);
        NutzConverter.Route[4] memory r = routes();
        r[2].venue = makeAddr("not-a-venue");
        convertReverting(drawId, r, abi.encodeWithSelector(NutzConverter.BadVenue.selector, r[2].venue));
        assertEq(d.acornPoolUsdg(), 300e6, "the pull was undone");
        assertFalse(d.drawConverted(drawId));
    }

    // ---- guards ----

    function test_nonKeeper_reverts() public {
        accumulateAcorn(1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Signers.NotKeeper.selector);
        c.convertAcorn(drawId, routes(), block.timestamp);
    }

    function test_expiredDeadline_reverts() public {
        accumulateAcorn(1 ether);
        vm.prank(keeper);
        vm.expectRevert(NutzConverter.DeadlinePassed.selector);
        c.convertAcorn(drawId, routes(), block.timestamp - 1);
    }

    // ---- fuzz: every unit of the pool is swapped or funded, whether a Leg fails or is disabled ----

    function testFuzz_pool_isExactlySwappedOrFunded(uint256 ethIn, uint256 rate, uint8 failMask, uint8 disableMask)
        public
    {
        ethIn = bound(ethIn, 1e12, 20 ether);
        rate = bound(rate, 1_000e6, 10_000e6); // the Distributor's rate range
        router.setRate(address(usdg), rate);
        accumulateAcorn(ethIn);
        uint256 usdgIn = d.acornPoolUsdg();
        for (uint8 i = 0; i < 4; i++) {
            router.setReverts(address(tok[i]), failMask & (1 << i) != 0);
            if (disableMask & (1 << i) != 0) disableLeg(i);
        }
        uint256 distributorUsdgBefore = usdg.balanceOf(address(d));
        uint256 routerUsdgBefore = usdg.balanceOf(address(router));

        convert(drawId, routes());

        uint256 spent = usdg.balanceOf(address(router)) - routerUsdgBefore;
        uint256 kept = distributorUsdgBefore - usdgIn;
        assertEq(usdg.balanceOf(address(d)) - kept, usdgIn - spent, "funded USDG + swapped USDG == the pool");
        assertEq(drawFunded(drawId)[4], usdgIn - spent);
        for (uint256 i = 0; i < 4; i++) {
            bool skipped = (failMask | disableMask) & (1 << i) != 0;
            assertEq(drawFunded(drawId)[i] == 0, skipped || usdgIn < 4, "a skipped Leg buys nothing");
        }
        assertEq(d.acornPoolUsdg(), 0);
        assertConverterEmpty();
    }
}
