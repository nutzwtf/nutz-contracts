// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {MockDistributor} from "../mocks/MockDistributor.sol";

/// @dev Drives the Draw with requests from the Keeper and from strangers over a few drawIds, time warps and fulfil
///      attempts with the recorded round-1000 signature, tampered bytes and wrong lengths, and records what every
///      successful call observed. fail_on_revert is on, so the actions that are meant to be refused go through
///      try/catch and only their outcome is recorded.
contract DrawHandler is Test {
    uint64 internal constant VECTOR_ROUND = 1000;
    bytes internal constant VECTOR_SIG =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    /// @dev A rejected point burns all the gas forwarded to the pairing precompile; bound what a bad fulfil costs.
    uint256 internal constant FULFIL_GAS_CAP = 400_000;
    uint256 internal constant ID_SPAN = 4;

    NutzDraw internal draw;
    MockDistributor internal dist;
    address internal keeper;
    address internal stranger = makeAddr("stranger");

    // ---- ghosts ----
    uint256[] public ids; // every id that was ever requested
    mapping(uint256 id => bool) internal seen;
    mapping(uint256 id => uint64) public ghostRound; // the round observed after the last successful request
    mapping(uint256 id => bytes32) public ghostSeed; // the seed observed at the fulfilling call, zero before
    mapping(uint256 id => bytes) public ghostSignature; // the signature that call submitted
    uint64 public ghostMaxRound; // the highest round any successful request committed to
    bool public ghostRoundDecreased; // a re-request committed to a lower round
    bool public ghostFulfilledChanged; // a call touched a fulfilled draw
    bool public ghostBadSignatureAccepted; // a tampered or mis-sized signature fulfilled a draw
    bool public ghostStrangerRequested; // a non-Keeper request succeeded
    bool public ghostOpenWeekRequested; // a request for the running week succeeded

    constructor(NutzDraw draw_, MockDistributor dist_, address keeper_) {
        draw = draw_;
        dist = dist_;
        keeper = keeper_;
    }

    // ------------------------------------------------------------- actions

    /// @dev Time stands still until the first request, which therefore commits to round 1000 (the fixture starts
    ///      the clock ten minutes before it) so that every run can play a real fulfilment.
    function warp(uint256 secs) external {
        if (ids.length == 0) return;
        vm.warp(block.timestamp + bound(secs, 1, 1 hours));
    }

    function requestAsKeeper(uint256 idSeed, bytes32 root, uint256 count) external {
        uint256 id = _pickId(idSeed);
        count = bound(count, 0, 1_000_000);
        (,, uint64 before, bytes32 seedBefore) = draw.draws(id);
        vm.prank(keeper);
        try draw.requestDraw(id, root, count) {
            _recordRequest(id, before, seedBefore);
        } catch (bytes memory reason) {
            _expectRequestRefusal(reason, root, count, seedBefore);
        }
    }

    function requestAsStranger(uint256 idSeed, bytes32 root, uint256 count) external {
        uint256 id = _pickId(idSeed);
        vm.prank(stranger);
        try draw.requestDraw(id, root, count) {
            ghostStrangerRequested = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), NutzDraw.NotKeeper.selector, "stranger refused for another reason");
        }
    }

    function requestNotOpenWeek(bytes32 root, uint256 count) external {
        uint256 id = dist.currentDraw();
        vm.prank(keeper);
        try draw.requestDraw(id, root, count) {
            ghostOpenWeekRequested = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), NutzDraw.DrawNotOpen.selector, "open week refused for another reason");
        }
    }

    function fulfilVector(uint256 idSeed) external {
        _fulfil(_pickId(idSeed), VECTOR_SIG, true);
    }

    function fulfilTampered(uint256 idSeed, uint8 index, uint8 mask) external {
        bytes memory tampered = VECTOR_SIG;
        index = uint8(bound(index, 0, 47));
        tampered[index] = bytes1(uint8(tampered[index]) ^ uint8(bound(mask, 1, 255)));
        _fulfil(_pickId(idSeed), tampered, false);
    }

    function fulfilWrongLength(uint256 idSeed, bool longer) external {
        bytes memory wrong = VECTOR_SIG;
        if (longer) {
            wrong = bytes.concat(wrong, hex"00");
        } else {
            assembly {
                mstore(wrong, 47)
            }
        }
        _fulfil(_pickId(idSeed), wrong, false);
    }

    function sendEth(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(stranger, amount);
        vm.prank(stranger);
        (bool ok,) = address(draw).call{value: amount}("");
        assertFalse(ok, "the Draw accepted ETH");
    }

    // ------------------------------------------------------------- helpers

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    /// @dev One of the four most recently ended weeks: the ids a Keeper would label draws with.
    function _pickId(uint256 seed) internal view returns (uint256) {
        return dist.currentDraw() - 1 - bound(seed, 0, ID_SPAN - 1);
    }

    function _recordRequest(uint256 id, uint64 before, bytes32 seedBefore) internal {
        if (seedBefore != 0) ghostFulfilledChanged = true;
        (,, uint64 round,) = draw.draws(id);
        if (round < before) ghostRoundDecreased = true;
        if (round > ghostMaxRound) ghostMaxRound = round;
        ghostRound[id] = round;
        if (!seen[id]) {
            seen[id] = true;
            ids.push(id);
        }
    }

    function _expectRequestRefusal(bytes memory reason, bytes32 root, uint256 count, bytes32 seedBefore) internal pure {
        bytes4 selector = bytes4(reason);
        if (seedBefore != 0) {
            assertEq(selector, NutzDraw.AlreadyFulfilled.selector, "fulfilled draw refused for another reason");
        } else if (root == 0 || count == 0) {
            assertEq(selector, NutzDraw.NoTickets.selector, "empty list refused for another reason");
        } else {
            revert("keeper request refused"); // every other request from the Keeper must go through
        }
    }

    function _fulfil(uint256 id, bytes memory signature, bool genuine) internal {
        (,, uint64 round, bytes32 seedBefore) = draw.draws(id);
        vm.prank(stranger);
        // Capped so a rejected point cannot burn the run's gas; an out-of-gas lands in the catch like a revert.
        (bool ok,) = address(draw).call{gas: FULFIL_GAS_CAP}(abi.encodeCall(draw.fulfill, (id, signature)));
        if (!ok) return;
        if (!genuine) ghostBadSignatureAccepted = true;
        if (seedBefore != 0 || round == 0) ghostFulfilledChanged = true;
        ghostSeed[id] = draw.seedOf(id);
        ghostSignature[id] = signature;
    }
}
