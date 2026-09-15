// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {stdError} from "forge-std/Test.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {DrawBase} from "../harness/DrawBase.sol";
import {NutzDrawWrongKey, NutzDrawWrongVector} from "../harness/DrawSelfTestHarness.sol";

/// @dev Draw spec §4 (constructor, rounds), §5 (request) and §7 (views).
contract DrawRequestTest is DrawBase {
    // ---- constructor ----

    function test_constructor_wiresDistributor_andPassesSelfTest() public view {
        assertEq(address(draw.DISTRIBUTOR()), address(dist));
        assertEq(draw.lastRound(), 0);
    }

    function test_constructor_zeroDistributor_reverts() public {
        vm.expectRevert(NutzDraw.ZeroAddress.selector);
        new NutzDraw(address(0));
    }

    function test_constructor_wrongKey_failsSelfTest() public {
        vm.expectRevert(NutzDraw.VerifierSelfTestFailed.selector);
        new NutzDrawWrongKey(address(dist));
    }

    function test_constructor_wrongVector_failsSelfTest() public {
        vm.expectRevert(NutzDraw.VerifierSelfTestFailed.selector);
        new NutzDrawWrongVector(address(dist));
    }

    // ---- rounds ----

    /// @dev drand: round 1 covers [genesis, genesis + period); every later round starts `period` later.
    function test_roundAt_genesisBoundaries() public view {
        assertEq(draw.roundAt(GENESIS), 1);
        assertEq(draw.roundAt(GENESIS + 2), 1);
        assertEq(draw.roundAt(GENESIS + 3), 2);
        assertEq(draw.roundAt(VECTOR_DUE_TS - 1), 999);
        assertEq(draw.roundAt(VECTOR_DUE_TS), 1000);
    }

    function test_roundAt_beforeGenesis_reverts() public {
        vm.expectRevert(stdError.arithmeticError);
        draw.roundAt(GENESIS - 1);
    }

    function test_currentRound_followsTheClock() public {
        assertEq(draw.currentRound(), VECTOR_REQUEST_ROUND);
        vm.warp(VECTOR_DUE_TS);
        assertEq(draw.currentRound(), 1000);
    }

    // ---- requestDraw ----

    function test_requestDraw_stranger_reverts() public {
        uint256 id = openDrawId();
        vm.prank(stranger);
        vm.expectRevert(NutzDraw.NotKeeper.selector);
        draw.requestDraw(id, ROOT, COUNT);
    }

    function test_requestDraw_followsKeeperRotationOnDistributor() public {
        uint256 id = openDrawId();
        dist.setKeeper(stranger);
        vm.prank(keeper);
        vm.expectRevert(NutzDraw.NotKeeper.selector);
        draw.requestDraw(id, ROOT, COUNT);

        vm.prank(stranger);
        draw.requestDraw(id, ROOT, COUNT);
        assertEq(committedRound(id), VECTOR_ROUND);
    }

    function test_requestDraw_currentWeek_reverts() public {
        uint256 id = dist.currentDraw();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.DrawNotOpen.selector, id));
        draw.requestDraw(id, ROOT, COUNT);
    }

    function testFuzz_requestDraw_weekNotEnded_reverts(uint256 id) public {
        id = bound(id, dist.currentDraw(), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(NutzDraw.DrawNotOpen.selector, id));
        draw.requestDraw(id, ROOT, COUNT);
    }

    function test_requestDraw_zeroRoot_reverts() public {
        uint256 id = openDrawId();
        vm.prank(keeper);
        vm.expectRevert(NutzDraw.NoTickets.selector);
        draw.requestDraw(id, bytes32(0), COUNT);
    }

    function test_requestDraw_zeroCount_reverts() public {
        uint256 id = openDrawId();
        vm.prank(keeper);
        vm.expectRevert(NutzDraw.NoTickets.selector);
        draw.requestDraw(id, ROOT, 0);
    }

    function test_requestDraw_commitsListAndFutureRound() public {
        uint256 id = openDrawId();
        vm.expectEmit(address(draw));
        emit NutzDraw.DrawRequested(id, ROOT, COUNT, VECTOR_ROUND);
        request(id);

        (bytes32 root, uint256 count, uint64 round, bytes32 seed) = draw.draws(id);
        assertEq(root, ROOT);
        assertEq(count, COUNT);
        assertEq(round, VECTOR_ROUND, "roundAt(now + 10 minutes)");
        assertEq(seed, bytes32(0));
        assertEq(draw.seedOf(id), bytes32(0));
        assertEq(draw.lastRound(), VECTOR_ROUND);
        assertGt(round, draw.currentRound(), "the committed round lies ahead");
    }

    function test_requestDraw_twoInOneRound_getDistinctRounds() public {
        uint256 id = openDrawId();
        request(id);
        request(id - 1);
        assertEq(committedRound(id), VECTOR_ROUND);
        assertEq(committedRound(id - 1), VECTOR_ROUND + 1, "lastRound + 1 wins inside one 3-second round");
        assertEq(draw.lastRound(), VECTOR_ROUND + 1);
    }

    function testFuzz_requestDraw_roundsStrictlyIncrease(uint256 gap) public {
        uint256 id = openDrawId();
        request(id);
        uint64 first = committedRound(id);
        vm.warp(block.timestamp + bound(gap, 0, 1 days));
        request(id - 1);
        uint64 second = committedRound(id - 1);
        assertGt(second, first);
        assertGe(second, draw.roundAt(block.timestamp + LEAD));
        assertEq(draw.lastRound(), second);
    }

    function test_requestDraw_again_replacesListAndRound() public {
        uint256 id = openDrawId();
        request(id);
        vm.warp(block.timestamp + 7);

        bytes32 newRoot = keccak256("corrected tickets");
        vm.expectEmit(address(draw));
        emit NutzDraw.DrawRequested(id, newRoot, COUNT + 1, VECTOR_ROUND + 2);
        request(id, newRoot, COUNT + 1);

        (bytes32 root, uint256 count, uint64 round, bytes32 seed) = draw.draws(id);
        assertEq(root, newRoot);
        assertEq(count, COUNT + 1);
        assertEq(round, VECTOR_ROUND + 2, "7 seconds later the target round has moved on by two");
        assertEq(seed, bytes32(0));
        assertEq(draw.lastRound(), VECTOR_ROUND + 2);
    }

    // ---- no value ----

    function test_contract_acceptsNoEth() public {
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        (bool plain,) = address(draw).call{value: 1}("");
        assertFalse(plain, "no receive or fallback");
        (bool viaFulfil,) = address(draw).call{value: 1}(abi.encodeCall(draw.fulfill, (openDrawId(), VECTOR_SIG)));
        assertFalse(viaFulfil, "fulfill is not payable");
        vm.stopPrank();
        assertEq(address(draw).balance, 0);
    }
}
