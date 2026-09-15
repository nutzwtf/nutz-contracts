// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DrawBase} from "../harness/DrawBase.sol";
import {DrawHandler} from "./DrawHandler.sol";

/// @dev Draw spec §8: a Seed is set once, by a verified signature, for a committed list, and never moves.
contract DrawInvariantTest is DrawBase {
    DrawHandler internal h;

    function setUp() public override {
        super.setUp();
        h = new DrawHandler(draw, dist, keeper);
        targetContract(address(h));
    }

    /// @notice `seedOf(id)` is zero until a fulfil succeeds for `id`, then equals what that call observed and
    ///         sha256 of the signature it submitted, and never changes afterwards.
    function invariant_seedSetOnceBySubmittedSignature() public view {
        uint256 n = h.idCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = h.ids(k);
            bytes32 ghost = h.ghostSeed(id);
            assertEq(draw.seedOf(id), ghost);
            if (ghost != 0) assertEq(ghost, sha256(h.ghostSignature(id)));
        }
        assertFalse(h.ghostFulfilledChanged(), "a fulfilled draw was touched");
        assertFalse(h.ghostBadSignatureAccepted(), "a tampered or mis-sized signature fulfilled a draw");
    }

    /// @notice A draw's round never decreases while unfulfilled and is frozen once fulfilled; `lastRound` is the
    ///         maximum committed round and bounds every draw.
    function invariant_roundsMonotone() public view {
        assertFalse(h.ghostRoundDecreased(), "a re-request lowered the round");
        uint64 last = draw.lastRound();
        assertEq(last, h.ghostMaxRound());
        uint256 n = h.idCount();
        for (uint256 k = 0; k < n; k++) {
            uint256 id = h.ids(k);
            uint64 round = committedRound(id);
            assertEq(round, h.ghostRound(id), "round moved without a request");
            assertLe(round, last);
        }
    }

    /// @notice A fulfilled draw committed a non-empty Ticket list.
    function invariant_fulfilledDrawHasTickets() public view {
        uint256 n = h.idCount();
        for (uint256 k = 0; k < n; k++) {
            (bytes32 root, uint256 count,, bytes32 seed) = draw.draws(h.ids(k));
            if (seed == 0) continue;
            assertTrue(count > 0 && root != 0);
        }
    }

    /// @notice Only the Keeper commits a list, and only for a week that has ended.
    function invariant_onlyKeeperRequestsEndedWeeks() public view {
        assertFalse(h.ghostStrangerRequested());
        assertFalse(h.ghostOpenWeekRequested());
    }

    /// @notice No function is payable: the balance stays zero.
    function invariant_holdsNoEth() public view {
        assertEq(address(draw).balance, 0);
    }
}
