// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {Signers} from "../../src/Signers.sol";
import {MockNutzDraw} from "../mocks/MockNutzDraw.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

contract DistributorDrawTest is DistributorBase {
    MockNutzDraw internal draw;
    address internal winner = makeAddr("winner");
    bytes32 internal constant SEED = keccak256("seed");

    function setUp() public override {
        super.setUp();
        draw = new MockNutzDraw();
    }

    /// @dev Accumulates 300 USDG of Acorn pool over the deploy week, then closes the week.
    function accumulateAcorn() internal {
        fund(DEPLOY_EPOCH, amounts(0, 0, 0, 0, 10e18), 100e18);
        closeEpoch(DEPLOY_EPOCH + 1);
        fund(DEPLOY_EPOCH + 1, amounts(0, 0, 0, 0, 10e18), 200e18);
        closeDraw(DEPLOY_DRAW);
    }

    function pullAcorn(uint256 drawId) internal {
        vm.prank(converter);
        d.pullAcorn(drawId);
    }

    function fundDraw(uint256 drawId, uint256[5] memory a) internal {
        vm.prank(converter);
        d.notifyDrawFunding(drawId, a);
    }

    // ---- draw contract (48h timelock) ----

    function test_drawContract_startsZero_andIsSetThroughTheTimelock() public {
        assertEq(address(d.drawContract()), address(0));
        bytes32 id = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(draw)));
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(draw), uint256(0)));
        d.proposeDrawContract(address(draw), sign(KEY_A, sh), sign(KEY_B, sh));
        assertEq(d.readyAt(id), block.timestamp + 48 hours);

        vm.expectRevert(Signers.NotReady.selector);
        d.executeDrawContract(address(draw));

        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(address(d));
        emit NutzDistributor.DrawContractSet(address(draw));
        d.executeDrawContract(address(draw));
        assertEq(address(d.drawContract()), address(draw));
    }

    function test_proposeDrawContract_zero_reverts() public {
        bytes32 sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, address(0), uint256(0)));
        vm.expectRevert(Signers.ZeroAddress.selector);
        d.proposeDrawContract(address(0), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    // ---- pullAcorn ----

    function test_pullAcorn_sendsPoolToConverter_once() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        draw.setSeed(DEPLOY_DRAW, SEED);
        assertEq(d.acornPoolUsdg(), 300e18);

        vm.expectEmit(address(d));
        emit NutzDistributor.AcornPulled(DEPLOY_DRAW, 300e18);
        pullAcorn(DEPLOY_DRAW);
        assertEq(d.acornPoolUsdg(), 0);
        assertEq(tok[4].balanceOf(converter), 1_000_000e18 - 20e18, "cash stays, acorn returned");
        assertTrue(d.drawConverted(DEPLOY_DRAW));

        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.AlreadyConverted.selector, DEPLOY_DRAW));
        d.pullAcorn(DEPLOY_DRAW);
    }

    function test_pullAcorn_withoutDrawContract_reverts() public {
        accumulateAcorn();
        vm.prank(converter);
        vm.expectRevert(NutzDistributor.NoDrawContract.selector);
        d.pullAcorn(DEPLOY_DRAW);
    }

    function test_pullAcorn_beforeBeaconFulfilment_reverts() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.DrawNotFulfilled.selector, DEPLOY_DRAW));
        d.pullAcorn(DEPLOY_DRAW);
    }

    function test_pullAcorn_emptyPool_reverts() public {
        installDrawContract(address(draw));
        closeDraw(DEPLOY_DRAW);
        draw.setSeed(DEPLOY_DRAW, SEED);
        vm.prank(converter);
        vm.expectRevert(NutzDistributor.NothingToConvert.selector);
        d.pullAcorn(DEPLOY_DRAW);
    }

    function test_pullAcorn_byNonConverter_reverts() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        draw.setSeed(DEPLOY_DRAW, SEED);
        vm.prank(keeper);
        vm.expectRevert(NutzDistributor.NotConverter.selector);
        d.pullAcorn(DEPLOY_DRAW);
    }

    // ---- notifyDrawFunding ----

    function test_notifyDrawFunding_requiresConversion() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        vm.prank(converter);
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NotConverted.selector, DEPLOY_DRAW));
        d.notifyDrawFunding(DEPLOY_DRAW, amounts(1e18, 1e18, 1e18, 1e18, 0));
    }

    function test_notifyDrawFunding_recordsStocksAndReturnedUsdg() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        draw.setSeed(DEPLOY_DRAW, SEED);
        pullAcorn(DEPLOY_DRAW);
        // three legs converted, one (MU) failed and came back as USDG
        uint256[5] memory a = amounts(1e18, 2e18, 0, 3e18, 75e18);
        vm.expectEmit(address(d));
        emit NutzDistributor.DrawFunded(DEPLOY_DRAW, a);
        fundDraw(DEPLOY_DRAW, a);
        NutzDistributor.Ledger memory L = d.ledger(DRAW, DEPLOY_DRAW);
        assertEq(L.funded[0], 1e18);
        assertEq(L.funded[2], 0);
        assertEq(L.funded[4], 75e18);
        assertEq(tok[3].balanceOf(address(d)), 3e18);
    }

    // ---- draw Roots and claims ----

    function test_postRoot_draw_requiresConversionAndSeed() public {
        installDrawContract(address(draw));
        closeDraw(DEPLOY_DRAW);
        bytes32 sh = postRootHash(DRAW, DEPLOY_DRAW, keccak256("r"), zero5(), d.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzDistributor.NotConverted.selector, DEPLOY_DRAW));
        d.postRoot(DRAW, DEPLOY_DRAW, keccak256("r"), zero5(), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_drawLifecycle_pullFundPostClaim_withCarryForSkippedGolden() public {
        installDrawContract(address(draw));
        accumulateAcorn();
        draw.setSeed(DEPLOY_DRAW, SEED);
        pullAcorn(DEPLOY_DRAW);
        fundDraw(DEPLOY_DRAW, amounts(10e18, 10e18, 10e18, 10e18, 0));

        // Golden Acorn under its floor this week: the Root only commits half, the rest stays in drawCarry.
        Claim[] memory prizes = new Claim[](1);
        prizes[0] = Claim(winner, amounts(5e18, 5e18, 5e18, 5e18, 0));
        bytes32 root = rootOf(DEPLOY_DRAW, prizes);
        uint256[5] memory totals = totalsOf(prizes);
        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(DRAW, DEPLOY_DRAW, root, totals, zero5());
        postRoot(DRAW, DEPLOY_DRAW, root, totals);
        assertEq(d.carry(DRAW)[0], 5e18);
        assertEq(d.carry(EPOCH)[0], 0, "epoch carry untouched");

        vm.warp(block.timestamp + 30 minutes);
        d.claim(DRAW, DEPLOY_DRAW, winner, prizes[0].amounts, proofOf(DEPLOY_DRAW, prizes, 0));
        assertEq(tok[0].balanceOf(winner), 5e18);
        assertTrue(d.claimed(DRAW, DEPLOY_DRAW, winner));
        assertFalse(d.claimed(EPOCH, DEPLOY_DRAW, winner), "books are separate");

        // next week's Root may spend the carried Golden budget
        closeDraw(DEPLOY_DRAW + 1);
        draw.setSeed(DEPLOY_DRAW + 1, keccak256("seed-2"));
        fund(d.currentEpoch() - 1, zero5(), 1e18);
        pullAcorn(DEPLOY_DRAW + 1);
        fundDraw(DEPLOY_DRAW + 1, amounts(1e18, 0, 0, 0, 0));
        uint256[5] memory t2 = amounts(6e18, 5e18, 5e18, 5e18, 0);
        vm.expectEmit(address(d));
        emit NutzDistributor.RootPosted(DRAW, DEPLOY_DRAW + 1, keccak256("r2"), t2, amounts(5e18, 5e18, 5e18, 5e18, 0));
        postRoot(DRAW, DEPLOY_DRAW + 1, keccak256("r2"), t2);
    }
}
