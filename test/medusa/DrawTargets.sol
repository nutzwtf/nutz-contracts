// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {DrawProperties} from "./DrawProperties.sol";

/// @dev test/invariant/DrawHandler.sol under Medusa: requests from the Keeper and from strangers over a few
///      drawIds, time warps and fulfil attempts with the recorded round-1000 signature, tampered bytes and wrong
///      lengths. The forge handler keeps the clock still until the first request so that it commits to round 1000;
///      Medusa moves the clock between calls on its own, so every action resets it to the fixture's timestamp
///      until an id is on record (`_syncClock`), which forge sees as a no-op warp.
abstract contract DrawTargets is DrawProperties {
    // ------------------------------------------------------------- actions

    function warp(uint256 secs) public {
        if (ids.length == 0) return;
        vm.warp(block.timestamp + between(secs, 1, 1 hours));
    }

    function requestAsKeeper(uint256 idSeed, bytes32 root, uint256 count) public {
        _syncClock();
        uint256 id = _pickId(idSeed);
        count = between(count, 0, 1_000_000);
        (,, uint64 before, bytes32 seedBefore) = draw.draws(id);
        bool due = before != 0 && draw.currentRound() >= before;
        vm.prank(keeper);
        try draw.requestDraw(id, root, count) {
            if (due) ghostDueRoundReplaced = true;
            _recordRequest(id, before, seedBefore);
        } catch (bytes memory reason) {
            _expectRequestRefusal(reason, root, count, seedBefore, due);
        }
    }

    function requestAsStranger(uint256 idSeed, bytes32 root, uint256 count) public {
        _syncClock();
        uint256 id = _pickId(idSeed);
        vm.prank(stranger);
        try draw.requestDraw(id, root, count) {
            ghostStrangerRequested = true;
        } catch (bytes memory reason) {
            t(bytes4(reason) == NutzDraw.NotKeeper.selector, "stranger refused for another reason");
        }
    }

    function requestNotOpenWeek(bytes32 root, uint256 count) public {
        _syncClock();
        uint256 id = dist.currentDraw();
        vm.prank(keeper);
        try draw.requestDraw(id, root, count) {
            ghostOpenWeekRequested = true;
        } catch (bytes memory reason) {
            t(bytes4(reason) == NutzDraw.DrawNotOpen.selector, "open week refused for another reason");
        }
    }

    function fulfilVector(uint256 idSeed) public {
        _syncClock();
        _fulfil(_pickId(idSeed), VECTOR_SIG, true);
    }

    function fulfilTampered(uint256 idSeed, uint8 index, uint8 mask) public {
        _syncClock();
        bytes memory tampered = VECTOR_SIG;
        index = uint8(between(index, 0, 47));
        tampered[index] = bytes1(uint8(tampered[index]) ^ uint8(between(mask, 1, 255)));
        _fulfil(_pickId(idSeed), tampered, false);
    }

    function fulfilWrongLength(uint256 idSeed, bool longer) public {
        _syncClock();
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

    /// @dev Sent by this contract rather than a pranked stranger: under Medusa a prank does not make the pranked
    ///      account pay `msg.value`, and a send that fails for the sender's balance would pass this for nothing.
    function sendEth(uint256 amount) public {
        amount = between(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(draw).call{value: amount}("");
        t(!ok, "the Draw accepted ETH");
    }

    // ------------------------------------------------------------- helpers

    /// @dev Until the first request is on record nothing depends on the clock, so it is put back to the fixture's
    ///      timestamp, the one at which a request commits to the recorded round.
    function _syncClock() internal {
        if (ids.length == 0) vm.warp(VECTOR_REQUEST_TS);
    }

    /// @dev One of the four most recently ended weeks: the ids a Keeper would label draws with.
    function _pickId(uint256 seed) internal returns (uint256) {
        return dist.currentDraw() - 1 - between(seed, 0, ID_SPAN - 1);
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

    function _expectRequestRefusal(bytes memory reason, bytes32 root, uint256 count, bytes32 seedBefore, bool due)
        internal
    {
        bytes4 selector = bytes4(reason);
        if (seedBefore != 0) {
            t(selector == NutzDraw.AlreadyFulfilled.selector, "fulfilled draw refused for another reason");
        } else if (due) {
            // Review 2026-09, F08: a list whose round is public can only be fulfilled.
            t(selector == NutzDraw.RoundDue.selector, "due draw refused for another reason");
        } else if (root == 0 || count == 0) {
            t(selector == NutzDraw.NoTickets.selector, "empty list refused for another reason");
        } else {
            t(false, "keeper request refused"); // every other request from the Keeper must go through
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
