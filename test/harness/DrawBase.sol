// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {MockDistributor} from "../mocks/MockDistributor.sol";

/// @dev Shared fixture: a mock Distributor, a deployed Draw, and the clock set so that the first request commits to
///      drand quicknet round 1000, the recorded vector (draw spec §13), which lets the tests play a real fulfilment
///      on the local prague EVM.
abstract contract DrawBase is Test {
    uint256 internal constant GENESIS = 1_692_803_367;
    uint256 internal constant PERIOD = 3;
    uint256 internal constant LEAD = 10 minutes;

    uint64 internal constant VECTOR_ROUND = 1000;
    bytes internal constant VECTOR_SIG =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    bytes32 internal constant RANDOMNESS = 0xfe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd;

    /// @dev Round 1000 starts at GENESIS + 999 * 3 (drand: round r covers [genesis + (r - 1) * period, +period)).
    uint256 internal constant VECTOR_DUE_TS = GENESIS + (VECTOR_ROUND - 1) * PERIOD;
    /// @dev A request here targets round 1000: roundAt(now + LEAD) == 1000 and no earlier round is committed.
    uint256 internal constant VECTOR_REQUEST_TS = VECTOR_DUE_TS - LEAD;
    /// @dev The round the clock is in at VECTOR_REQUEST_TS: (2397 / 3) + 1.
    uint64 internal constant VECTOR_REQUEST_ROUND = 800;

    /// @dev One verify costs about 135k gas; a point the pairing precompile rejects burns everything forwarded.
    uint256 internal constant FULFIL_GAS_CAP = 400_000;

    bytes32 internal constant ROOT = keccak256("tickets");
    uint256 internal constant COUNT = 42;

    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    MockDistributor internal dist;
    NutzDraw internal draw;

    function setUp() public virtual {
        vm.warp(VECTOR_REQUEST_TS);
        dist = new MockDistributor(keeper);
        draw = new NutzDraw(address(dist));
    }

    /// @dev The id the Keeper labels the Sunday draw with: the Unix week that ended last Thursday.
    function openDrawId() internal view returns (uint256) {
        return dist.currentDraw() - 1;
    }

    function request(uint256 drawId) internal {
        request(drawId, ROOT, COUNT);
    }

    function request(uint256 drawId, bytes32 root, uint256 count) internal {
        vm.prank(keeper);
        draw.requestDraw(drawId, root, count);
    }

    function fulfil(uint256 drawId, bytes memory signature) internal {
        vm.prank(stranger);
        draw.fulfill(drawId, signature);
    }

    function committedRound(uint256 drawId) internal view returns (uint64 round) {
        (,, round,) = draw.draws(drawId);
    }
}
