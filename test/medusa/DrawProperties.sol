// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Asserts} from "chimera/Asserts.sol";
import {DrawSetup} from "./DrawSetup.sol";

/// @dev Draw spec §8, the invariants of test/invariant/Draw.invariant.t.sol as Medusa properties: a Seed is set
///      once, by a verified signature, for a committed list, and never moves.
abstract contract DrawProperties is DrawSetup, Asserts {
    /// @notice `seedOf(id)` is zero until a fulfil succeeds for `id`, then equals what that call observed and
    ///         sha256 of the signature it submitted, and never changes afterwards.
    function property_seedSetOnceBySubmittedSignature() public returns (bool) {
        for (uint256 k = 0; k < ids.length; k++) {
            uint256 id = ids[k];
            bytes32 ghost = ghostSeed[id];
            t(draw.seedOf(id) == ghost, "seed differs from what the fulfilling call observed");
            if (ghost != 0) t(ghost == sha256(ghostSignature[id]), "seed is not sha256 of the signature");
        }
        t(!ghostFulfilledChanged, "a fulfilled draw was touched");
        t(!ghostDueRoundReplaced, "a public round was replaced (F08)");
        t(!ghostBadSignatureAccepted, "a tampered or mis-sized signature fulfilled a draw");
        return true;
    }

    /// @notice A draw's round never decreases while unfulfilled and is frozen once fulfilled; `lastRound` is the
    ///         maximum committed round and bounds every draw.
    function property_roundsMonotone() public returns (bool) {
        t(!ghostRoundDecreased, "a re-request lowered the round");
        uint64 last = draw.lastRound();
        eq(last, ghostMaxRound, "lastRound is not the maximum committed round");
        for (uint256 k = 0; k < ids.length; k++) {
            uint256 id = ids[k];
            (,, uint64 round,) = draw.draws(id);
            eq(round, ghostRound[id], "round moved without a request");
            lte(round, last, "a draw's round is above lastRound");
        }
        return true;
    }

    /// @notice A fulfilled draw committed a non-empty Ticket list.
    function property_fulfilledDrawHasTickets() public returns (bool) {
        for (uint256 k = 0; k < ids.length; k++) {
            (bytes32 root, uint256 count,, bytes32 seed) = draw.draws(ids[k]);
            if (seed == 0) continue;
            t(count > 0 && root != 0, "a fulfilled draw has no tickets");
        }
        return true;
    }

    /// @notice Only the Keeper commits a list, and only for a week that has ended.
    function property_onlyKeeperRequestsEndedWeeks() public returns (bool) {
        t(!ghostStrangerRequested, "a stranger's request went through");
        t(!ghostOpenWeekRequested, "a request for the open week went through");
        return true;
    }

    /// @notice No function is payable: the balance stays zero.
    function property_holdsNoEth() public returns (bool) {
        eq(address(draw).balance, 0, "the Draw holds ETH");
        return true;
    }
}
